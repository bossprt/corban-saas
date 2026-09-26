-- Contract changes, part C2 of the payout bridge (owner decisions 26/09/2026, ADR-0039).
--
-- 1. A contract can be edited after it left the draft: table/vigência, seller, amounts and term. Paid contracts too, but
--    only by the owner or a manager and with a reason. Every edit is recorded (before -> after) and the commission is
--    recalculated at once; an edit the calculation cannot follow is refused as a whole. The ChatGPT-era guards froze
--    every commercial field after the draft; they now accept these fields through update_contract only.
-- 2. The owner or a manager may change what the SELLER gets, per commission type (à vista, diferido...): a % of the
--    contract base or a fixed R$, with a reason. Rows are never changed: a new row replaces the previous one, and a row
--    without value brings the rule back. What is payable never exceeds what the company receives for that type.
-- 3. Notes on the contract (author and date, never deleted) and one history (contract_events) with edits, notes,
--    recalculations and payout changes. Payout changes and their amounts are visible to finance only.
-- 4. Nothing changes any more once the seller RECEIVED the commission of the contract (a paid statement or payout that
--    holds it): no edit, no payout change, no recalculation. Until part C3 posts the seller credit, no contract is in
--    that state; the rule is enforced here in the database already.

create table public.contract_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  proposal_id uuid not null,
  kind text not null check (kind in ('edit', 'note', 'recalculated', 'payout_override', 'payout_override_cleared')),
  detail jsonb not null default '{}'::jsonb,
  reason text check (reason is null or length(reason) between 1 and 2000),
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (organization_id, proposal_id) references public.proposals_v2(organization_id, id) on delete restrict
);
create index contract_events_proposal_idx on public.contract_events (organization_id, proposal_id, created_at);
create index contract_events_actor_idx on public.contract_events (actor_user_id);

create or replace function private.guard_contract_append_only()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if tg_op <> 'INSERT' then raise exception 'contract_history_is_append_only'; end if;
  if current_setting('corban.contract_rpc', true) is distinct from 'on' then raise exception 'contract_history_requires_governed_rpc'; end if;
  return new;
end
$$;
revoke all on function private.guard_contract_append_only() from public, anon, authenticated;
create trigger contract_events_00_guard before insert or update or delete on public.contract_events
  for each row execute function private.guard_contract_append_only();

alter table public.contract_events enable row level security;
revoke all on public.contract_events from public, anon, authenticated;
grant select on public.contract_events to authenticated;
-- Whoever sees the contract sees its notes, edits and recalculations; payout changes only with finance access.
create policy contract_events_select on public.contract_events for select to authenticated
  using (exists (select 1 from public.proposals_v2 p where p.id = proposal_id and p.organization_id = contract_events.organization_id
                 and public.is_active_organization_member(p.organization_id) and private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by))
         and (kind in ('edit', 'note', 'recalculated') or public.has_permission(organization_id, 'financeiro.view')));

create table public.contract_payout_overrides (
  id uuid primary key default gen_random_uuid(),
  seq bigint generated always as identity,
  organization_id uuid not null,
  proposal_id uuid not null,
  component_key text not null check (length(component_key) between 1 and 40),
  value_kind text check (value_kind in ('percentage', 'fixed_brl')),
  value numeric check (value >= 0 and (value_kind <> 'percentage' or value <= 100)),
  reason text not null check (length(btrim(reason)) between 3 and 500),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check ((value_kind is null) = (value is null)),
  foreign key (organization_id, proposal_id) references public.proposals_v2(organization_id, id) on delete restrict
);
create index contract_payout_overrides_proposal_idx on public.contract_payout_overrides (organization_id, proposal_id, component_key, seq);
create index contract_payout_overrides_created_by_idx on public.contract_payout_overrides (created_by);
create trigger contract_payout_overrides_00_guard before insert or update or delete on public.contract_payout_overrides
  for each row execute function private.guard_contract_append_only();
alter table public.contract_payout_overrides enable row level security;
revoke all on public.contract_payout_overrides from public, anon, authenticated;
grant select on public.contract_payout_overrides to authenticated;
create policy contract_payout_overrides_select on public.contract_payout_overrides for select to authenticated
  using (public.has_permission(organization_id, 'financeiro.view'));

-- The seller received the commission of this contract: a commission entry of theirs sits in a paid (or settled)
-- statement or payout.
create or replace function private.contract_payout_received(p_proposal uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
    select 1 from public.payout_entries e
    join public.payouts p on p.id = coalesce(e.statement_id, e.payout_id)
    where e.proposal_id = p_proposal and e.kind = 'commission' and e.beneficiary_role = 'originator' and p.status in ('paid', 'settled'))
$$;
revoke all on function private.contract_payout_received(uuid) from public, anon, authenticated;

-- Per commission type of the active calculation: what the company receives, what the rule pays the seller, the base of
-- the type (gross or net amount), the payout change in force (if any) and what is payable to the seller.
create or replace function private.contract_payable(p_proposal uuid)
returns table (component_key text, received numeric, rule_amount numeric, base_amount numeric, value_kind text, value numeric, payable numeric, overridden boolean)
language sql
stable
security definer
set search_path to ''
as $$
  with c as (select * from public.proposal_commission_calcs where proposal_id = p_proposal and status = 'active'),
  lines as (
    select l.component_key, sum(l.amount * l.multiplier) filter (where l.line_kind = 'received') as received,
           coalesce(sum(l.amount * l.multiplier) filter (where l.line_kind = 'originator'), 0) as rule_amount
    from public.proposal_commission_lines l join c on c.id = l.calc_id
    group by l.component_key),
  base as (
    select t.tech_key, case when upper(coalesce(k.calculation_base, '')) like 'L%' then c.net_amount else c.gross_amount end as base_amount
    from c join public.commercial_condition_components k on k.condition_id = c.condition_id
    join public.commission_component_types t on t.id = k.component_type_id),
  ov as (
    select distinct on (o.component_key) o.component_key, o.value_kind, o.value
    from public.contract_payout_overrides o where o.proposal_id = p_proposal
    order by o.component_key, o.seq desc)
  select lines.component_key, lines.received, lines.rule_amount, base.base_amount, ov.value_kind, ov.value,
         case when ov.value_kind is null then lines.rule_amount
              when ov.value_kind = 'fixed_brl' then round(ov.value, 2)
              else round(coalesce(base.base_amount, 0) * ov.value / 100, 2) end as payable,
         ov.value_kind is not null as overridden
  from lines left join base on base.tech_key = lines.component_key left join ov on ov.component_key = lines.component_key
$$;
revoke all on function private.contract_payable(uuid) from public, anon, authenticated;

-- Finance view of one contract (the commission card).
create or replace function public.contract_payout(p_proposal uuid)
returns table (component_key text, received numeric, rule_amount numeric, base_amount numeric, value_kind text, value numeric, payable numeric, overridden boolean, locked boolean)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare p public.proposals_v2%rowtype;
begin
  select * into p from public.proposals_v2 where id = p_proposal;
  if p.id is null or auth.uid() is null or not public.has_permission(p.organization_id, 'financeiro.view')
     or not private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by) then raise exception 'not_authorized'; end if;
  return query select x.*, private.contract_payout_received(p.id) from private.contract_payable(p.id) x order by x.component_key;
end
$$;
revoke all on function public.contract_payout(uuid) from public, anon;
grant execute on function public.contract_payout(uuid) to authenticated;

-- Finance view of every contract of the company (the Contratos screen): totals per contract.
create or replace function public.contract_payout_totals(p_org uuid)
returns table (proposal_id uuid, received numeric, rule_amount numeric, payable numeric, overridden boolean)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.view') then raise exception 'not_authorized'; end if;
  return query
    select c.proposal_id, sum(x.received), sum(x.rule_amount), sum(x.payable), bool_or(x.overridden)
    from public.proposal_commission_calcs c
    cross join lateral private.contract_payable(c.proposal_id) x
    where c.organization_id = p_org and c.status = 'active'
    group by c.proposal_id;
end
$$;
revoke all on function public.contract_payout_totals(uuid) from public, anon;
grant execute on function public.contract_payout_totals(uuid) to authenticated;

-- Change (or bring back to the rule, with p_kind null) what the seller gets for one commission type.
create or replace function public.set_payout_override(p_proposal uuid, p_component text, p_kind text, p_value text, p_reason text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  p public.proposals_v2%rowtype;
  x record;
  v_value numeric;
  v_payable numeric;
begin
  select * into p from public.proposals_v2 where id = p_proposal for update;
  if p.id is null or auth.uid() is null or not public.has_active_organization_role(p.organization_id, array['admin', 'manager'])
     or not private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by) then raise exception 'not_authorized'; end if;
  if private.contract_payout_received(p.id) then raise exception 'contract_payout_received'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 or length(p_reason) > 500 then raise exception 'reason_required'; end if;
  select * into x from private.contract_payable(p.id) c where c.component_key = p_component;
  if x.component_key is null then raise exception 'commission_not_calculated'; end if;

  if p_kind is null then
    if not x.overridden then return; end if;
    v_payable := x.rule_amount;
  else
    if p_kind not in ('percentage', 'fixed_brl') or coalesce(p_value, '') !~ '^[0-9]{1,9}(\.[0-9]{1,8})?$' then raise exception 'invalid_override'; end if;
    v_value := trim_scale(p_value::numeric);
    if p_kind = 'percentage' and v_value > 100 then raise exception 'invalid_override'; end if;
    v_payable := case when p_kind = 'fixed_brl' then round(v_value, 2) else round(coalesce(x.base_amount, 0) * v_value / 100, 2) end;
    if v_payable > x.received then raise exception 'override_exceeds_received'; end if;
  end if;

  perform set_config('corban.contract_rpc', 'on', true);
  insert into public.contract_payout_overrides (organization_id, proposal_id, component_key, value_kind, value, reason, created_by)
  values (p.organization_id, p.id, p_component, p_kind, v_value, btrim(p_reason), auth.uid());
  insert into public.contract_events (organization_id, proposal_id, kind, detail, reason, actor_user_id)
  values (p.organization_id, p.id, case when p_kind is null then 'payout_override_cleared' else 'payout_override' end,
          jsonb_build_object('component', p_component, 'rule_amount', x.rule_amount, 'previous', x.payable, 'payable', v_payable,
                             'value_kind', p_kind, 'value', v_value), btrim(p_reason), auth.uid());
  perform set_config('corban.contract_rpc', 'off', true);
end
$$;
revoke all on function public.set_payout_override(uuid, text, text, text, text) from public, anon;
grant execute on function public.set_payout_override(uuid, text, text, text, text) to authenticated;

create or replace function public.add_contract_note(p_proposal uuid, p_text text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare p public.proposals_v2%rowtype;
begin
  select * into p from public.proposals_v2 where id = p_proposal;
  if p.id is null or auth.uid() is null or not public.is_active_organization_member(p.organization_id)
     or not private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by) then raise exception 'not_authorized'; end if;
  if length(btrim(coalesce(p_text, ''))) < 1 or length(p_text) > 2000 then raise exception 'invalid_note'; end if;
  perform set_config('corban.contract_rpc', 'on', true);
  insert into public.contract_events (organization_id, proposal_id, kind, reason, actor_user_id) values (p.organization_id, p.id, 'note', btrim(p_text), auth.uid());
  perform set_config('corban.contract_rpc', 'off', true);
end
$$;
revoke all on function public.add_contract_note(uuid, text) from public, anon;
grant execute on function public.add_contract_note(uuid, text) to authenticated;

-- The guards accept the editable fields through update_contract (flag corban.contract_edit_rpc) only.
create or replace function public.guard_proposal_write()
 returns trigger
 language plpgsql
 set search_path to ''
as $function$
declare v_edit boolean := coalesce(current_setting('corban.contract_edit_rpc', true) = 'on', false);  -- never null: a null here would open the guard
begin
  if current_user in ('authenticated','anon','service_role')
     and current_setting('corban.proposal_rpc', true) is distinct from 'on'
     and current_setting('corban.paid_evidence_rpc', true) is distinct from 'on'
     and current_setting('corban.proposal_seller_rpc', true) is distinct from 'on'
     and not v_edit then
    raise exception 'proposal_write_requires_governed_rpc';
  end if;

  if tg_op = 'UPDATE' and new.seller_id is distinct from old.seller_id and not v_edit then
    if current_setting('corban.proposal_seller_rpc', true) is distinct from 'on' then raise exception 'proposal_seller_change_requires_governed_rpc'; end if;
    if old.status <> 'draft' then raise exception 'proposal_seller_is_frozen'; end if;
  end if;

  if tg_op = 'UPDATE' and (
     new.id is distinct from old.id
     or new.organization_id is distinct from old.organization_id
     or new.customer_id is distinct from old.customer_id
     or new.simulation_id is distinct from old.simulation_id
     or (new.product_table_version_id is distinct from old.product_table_version_id and not v_edit)
     or new.created_by is distinct from old.created_by
     or new.created_at is distinct from old.created_at) then
    raise exception 'proposal_identity_is_immutable';
  end if;
  return new;
end
$function$;

create or replace function public.guard_proposal_commercial_snapshot()
 returns trigger
 language plpgsql
 set search_path to ''
as $function$
declare v_edit boolean := coalesce(current_setting('corban.contract_edit_rpc', true) = 'on', false);  -- never null: a null here would open the guard
begin
  if tg_op='INSERT'
     or (tg_op='UPDATE' and (old.status='draft' or v_edit)
         and new.product_table_version_id is distinct from old.product_table_version_id) then
    if not exists(
      select 1 from public.product_table_versions v
      where v.organization_id=new.organization_id
        and v.id=new.product_table_version_id
        and v.status='published'
    ) then
      raise exception 'proposal_requires_published_product_table_version';
    end if;
  end if;

  if tg_op='UPDATE' and old.status<>'draft' then
    if new.status='draft' then raise exception 'proposal_cannot_return_to_draft'; end if;
    if new.organization_id is distinct from old.organization_id
       or new.customer_id is distinct from old.customer_id
       or new.simulation_id is distinct from old.simulation_id
       or (not v_edit and (
              new.product_table_version_id is distinct from old.product_table_version_id
           or new.seller_id is distinct from old.seller_id
           or new.requested_amount is distinct from old.requested_amount
           or new.released_amount is distinct from old.released_amount
           or new.installment_amount is distinct from old.installment_amount
           or new.term is distinct from old.term
           or new.commercial_snapshot is distinct from old.commercial_snapshot))
       or new.rate is distinct from old.rate
       or new.coefficient is distinct from old.coefficient
       or new.customer_snapshot is distinct from old.customer_snapshot
       or new.attribution_snapshot is distinct from old.attribution_snapshot
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'proposal_commercial_snapshot_is_immutable_after_draft';
    end if;
  end if;
  return new;
end
$function$;

-- Edit a contract. p_data keys (all optional): table_version_id, seller_id, requested_amount, released_amount,
-- installment_amount (decimal text, '' = empty), term. A paid contract needs the owner or a manager and a reason.
create or replace function public.update_contract(p_proposal uuid, p_data jsonb, p_reason text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  p public.proposals_v2%rowtype;
  n public.proposals_v2%rowtype;
  v_changes jsonb := '{}'::jsonb;
  v_bank text; v_table text;
  x record;
  function_money constant text := '^[0-9]{1,9}(\.[0-9]{1,2})?$';
begin
  select * into p from public.proposals_v2 where id = p_proposal for update;
  if p.id is null or auth.uid() is null or not public.is_active_organization_member(p.organization_id)
     or not private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by)
     or not (public.has_permission(p.organization_id, 'propostas.edit') or public.has_permission(p.organization_id, 'financeiro.edit')) then
    raise exception 'not_authorized';
  end if;
  if p.status in ('rejected', 'cancelled') then raise exception 'contract_closed'; end if;
  if p.status = 'paid' and not public.has_active_organization_role(p.organization_id, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  if p.status = 'paid' and length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'reason_required'; end if;
  if p_reason is not null and length(p_reason) > 2000 then raise exception 'reason_required'; end if;
  if private.contract_payout_received(p.id) then raise exception 'contract_payout_received'; end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' then raise exception 'invalid_contract_data'; end if;

  n := p;
  begin
    if p_data ? 'table_version_id' then n.product_table_version_id := (p_data->>'table_version_id')::uuid; end if;
    if p_data ? 'seller_id' then n.seller_id := nullif(p_data->>'seller_id', '')::uuid; end if;
    if p_data ? 'term' then n.term := nullif(p_data->>'term', '')::integer; end if;
  exception when others then raise exception 'invalid_contract_data'; end;
  if p_data ? 'requested_amount' then
    if coalesce(p_data->>'requested_amount', '') not in ('') and p_data->>'requested_amount' !~ function_money then raise exception 'invalid_amount'; end if;
    n.requested_amount := nullif(p_data->>'requested_amount', '')::numeric;
  end if;
  if p_data ? 'released_amount' then
    if coalesce(p_data->>'released_amount', '') not in ('') and p_data->>'released_amount' !~ function_money then raise exception 'invalid_amount'; end if;
    n.released_amount := nullif(p_data->>'released_amount', '')::numeric;
  end if;
  if p_data ? 'installment_amount' then
    if coalesce(p_data->>'installment_amount', '') not in ('') and p_data->>'installment_amount' !~ function_money then raise exception 'invalid_amount'; end if;
    n.installment_amount := nullif(p_data->>'installment_amount', '')::numeric;
  end if;
  if n.requested_amount is null and n.released_amount is null then raise exception 'invalid_amount'; end if;
  if n.term is not null and (n.term < 1 or n.term > 420) then raise exception 'invalid_term'; end if;
  if n.seller_id is not null and not exists (select 1 from public.commercial_sellers s where s.organization_id = p.organization_id and s.id = n.seller_id and s.is_active) then
    raise exception 'seller_not_found';
  end if;

  if n.product_table_version_id is distinct from p.product_table_version_id then
    select b.name, t.name into v_bank, v_table
    from public.product_table_versions v join public.product_tables t on t.id = v.product_table_id
    join public.organization_product_routes r on r.id = t.route_id join public.organization_banks b on b.id = r.org_bank_id
    where v.id = n.product_table_version_id and v.organization_id = p.organization_id and v.status = 'published';
    if v_table is null then raise exception 'proposal_requires_published_product_table_version'; end if;
    n.commercial_snapshot := coalesce(p.commercial_snapshot, '{}'::jsonb)
      || jsonb_build_object('bank', v_bank, 'table', v_table, 'table_version_id', n.product_table_version_id);
    v_changes := v_changes || jsonb_build_object('table_version_id', jsonb_build_object('from', p.product_table_version_id, 'to', n.product_table_version_id,
                   'from_label', coalesce(p.commercial_snapshot->>'table', ''), 'to_label', v_table));
  end if;
  if n.seller_id is distinct from p.seller_id then
    v_changes := v_changes || jsonb_build_object('seller_id', jsonb_build_object('from', p.seller_id, 'to', n.seller_id,
                   'from_label', (select name from public.commercial_sellers where id = p.seller_id), 'to_label', (select name from public.commercial_sellers where id = n.seller_id)));
  end if;
  if n.requested_amount is distinct from p.requested_amount then v_changes := v_changes || jsonb_build_object('requested_amount', jsonb_build_object('from', p.requested_amount, 'to', n.requested_amount)); end if;
  if n.released_amount is distinct from p.released_amount then v_changes := v_changes || jsonb_build_object('released_amount', jsonb_build_object('from', p.released_amount, 'to', n.released_amount)); end if;
  if n.installment_amount is distinct from p.installment_amount then v_changes := v_changes || jsonb_build_object('installment_amount', jsonb_build_object('from', p.installment_amount, 'to', n.installment_amount)); end if;
  if n.term is distinct from p.term then v_changes := v_changes || jsonb_build_object('term', jsonb_build_object('from', p.term, 'to', n.term)); end if;
  if v_changes = '{}'::jsonb then return; end if;

  perform set_config('corban.contract_edit_rpc', 'on', true);
  update public.proposals_v2
  set product_table_version_id = n.product_table_version_id, seller_id = n.seller_id, requested_amount = n.requested_amount,
      released_amount = n.released_amount, installment_amount = n.installment_amount, term = n.term,
      commercial_snapshot = n.commercial_snapshot, updated_at = now()
  where id = p.id;
  perform set_config('corban.contract_edit_rpc', 'off', true);

  perform set_config('corban.contract_rpc', 'on', true);
  insert into public.contract_events (organization_id, proposal_id, kind, detail, reason, actor_user_id)
  values (p.organization_id, p.id, 'edit', v_changes, nullif(btrim(coalesce(p_reason, '')), ''), auth.uid());
  perform set_config('corban.contract_rpc', 'off', true);

  -- A calculated contract follows its new data at once; if the calculation cannot (no line for the new term, a payout
  -- change above the new receipt...), the whole edit is refused.
  if exists (select 1 from public.proposal_commission_calcs c where c.proposal_id = p.id and c.status = 'active') then
    perform public.calculate_contract_commission(p.id);
    for x in select * from private.contract_payable(p.id) loop
      if x.payable > x.received then raise exception 'override_exceeds_received'; end if;
    end loop;
  end if;
end
$$;
revoke all on function public.update_contract(uuid, jsonb, text) from public, anon;
grant execute on function public.update_contract(uuid, jsonb, text) to authenticated;

-- The seller's own view gains what is payable per commission type (the payout change, when there is one).
create or replace function public.proposal_commission_mine(p_proposal uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare p public.proposals_v2%rowtype; c public.proposal_commission_calcs%rowtype;
begin
  select * into p from public.proposals_v2 where id = p_proposal;
  if p.id is null or auth.uid() is null or not public.is_active_organization_member(p.organization_id)
     or not private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by) then
    raise exception 'not_authorized';
  end if;
  select * into c from public.proposal_commission_calcs where proposal_id = p.id and status = 'active';
  if c.id is null then return jsonb_build_object('calculated', false); end if;
  if not private.is_commission_originator(c.id) then
    return jsonb_build_object('calculated', true, 'calculated_at', c.calculated_at, 'mine', false);
  end if;
  return jsonb_build_object('calculated', true, 'calculated_at', c.calculated_at, 'mine', true,
    'lines', coalesce((select jsonb_agg(jsonb_build_object('component_key', l.component_key, 'part', l.part, 'multiplier', l.multiplier, 'amount', l.amount::text)
                               order by l.component_key, l.part)
              from public.proposal_commission_lines l where l.calc_id = c.id and l.line_kind = 'originator'), '[]'::jsonb),
    'payable', coalesce((select jsonb_agg(jsonb_build_object('component_key', x.component_key, 'amount', x.payable::text) order by x.component_key)
              from private.contract_payable(p.id) x where x.payable > 0), '[]'::jsonb));
end
$function$;

-- The calculation follows the same rule: recalculated after "pago ao cliente", frozen once the seller received.
create or replace function public.calculate_contract_commission(p_proposal_id uuid, p_condition_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  p public.proposals_v2%rowtype;
  v_org uuid;
  v_cond public.commercial_conditions%rowtype;
  v_count integer;
  v_bank uuid;
  v_ir numeric;
  v_seller public.commercial_sellers%rowtype;
  v_rule public.commission_group_rules%rowtype;
  it public.commission_group_rule_items%rowtype;
  v_orig uuid; v_sup uuid; v_mgr uuid;
  v_gross numeric; v_net numeric;
  v_pay_deferred boolean;
  v_calc uuid;
  c record;
  v_base numeric; v_received numeric; v_ref numeric;
  v_o numeric; v_s numeric; v_m numeric; v_t numeric; v_i numeric;
begin
  select * into p from public.proposals_v2 where id = p_proposal_id for update;
  v_org := p.organization_id;
  if v_org is null or auth.uid() is null or not public.is_active_organization_member(v_org) then raise exception 'not_authorized'; end if;
  if not private.can_see_proposal_row(v_org, p.seller_id, p.created_by) then raise exception 'not_authorized'; end if;
  if not (public.has_permission(v_org, 'propostas.edit') or public.has_permission(v_org, 'financeiro.edit')) then raise exception 'not_authorized'; end if;
  -- A paid contract can still be recalculated (it may be edited until the seller receives); a rejected or cancelled
  -- one keeps its last calculation; nothing moves once the seller received the commission.
  if p.status in ('rejected', 'cancelled') and exists (select 1 from public.proposal_commission_calcs x where x.proposal_id = p.id and x.status = 'active') then
    raise exception 'commission_frozen';
  end if;
  if private.contract_payout_received(p.id) then raise exception 'contract_payout_received'; end if;
  if exists (select 1 from public.payout_entries e where e.proposal_id = p.id and e.kind = 'commission') then raise exception 'commission_already_posted'; end if;

  -- Line of the table: explicit, or the only one of the contract's table version matching the term and amount.
  if p_condition_id is not null then
    select * into v_cond from public.commercial_conditions k where k.organization_id = v_org and k.id = p_condition_id and k.product_table_version_id = p.product_table_version_id;
    if v_cond.id is null then raise exception 'condition_not_found'; end if;
  else
    select count(*) into v_count from public.commercial_conditions k
    where k.organization_id = v_org and k.product_table_version_id = p.product_table_version_id
      and (p.term is null or (p.term between coalesce(k.term_min, k.term) and coalesce(k.term_max, k.term)))
      and (k.amount_min is null or coalesce(p.requested_amount, p.released_amount) >= k.amount_min)
      and (k.amount_max is null or coalesce(p.requested_amount, p.released_amount) <= k.amount_max);
    if v_count = 0 then raise exception 'condition_not_found'; end if;
    if v_count > 1 then raise exception 'condition_ambiguous'; end if;
    select * into v_cond from public.commercial_conditions k
    where k.organization_id = v_org and k.product_table_version_id = p.product_table_version_id
      and (p.term is null or (p.term between coalesce(k.term_min, k.term) and coalesce(k.term_max, k.term)))
      and (k.amount_min is null or coalesce(p.requested_amount, p.released_amount) >= k.amount_min)
      and (k.amount_max is null or coalesce(p.requested_amount, p.released_amount) <= k.amount_max);
  end if;

  select coalesce(b.ir_withheld_pct, 0) into v_ir
  from public.product_table_versions v
  join public.product_tables t on t.id = v.product_table_id
  join public.organization_product_routes r on r.id = t.route_id
  join public.organization_banks b on b.id = r.org_bank_id
  where v.id = p.product_table_version_id;
  v_ir := coalesce(v_ir, 0);

  -- Seller: the contract's, or the seller linked to whoever registered it. Their group decides the payout.
  if p.seller_id is not null then
    select * into v_seller from public.commercial_sellers s where s.organization_id = v_org and s.id = p.seller_id;
  else
    select * into v_seller from public.commercial_sellers s where s.organization_id = v_org and s.user_id = p.created_by and s.is_active order by s.created_at limit 1;
  end if;
  if v_seller.id is null then raise exception 'proposal_without_seller'; end if;
  if v_seller.commission_group_id is null then raise exception 'seller_without_group'; end if;
  select * into v_rule from public.commission_group_rules r where r.organization_id = v_org and r.group_id = v_seller.commission_group_id order by r.version desc limit 1;
  if v_rule.id is null then raise exception 'group_rule_missing'; end if;

  -- Supervisor = team leader of the seller's login; manager = the supervisor's leader. A seller without login has no
  -- hierarchy: those shares stay with the company.
  v_orig := v_seller.user_id;
  if v_orig is not null then
    select m.team_leader_user_id into v_sup from public.organization_memberships m where m.organization_id = v_org and m.user_id = v_orig and m.status = 'active';
    if v_sup is not null then
      select m.team_leader_user_id into v_mgr from public.organization_memberships m where m.organization_id = v_org and m.user_id = v_sup and m.status = 'active';
    end if;
  end if;

  v_gross := coalesce(p.requested_amount, p.released_amount, 0);
  v_net := coalesce(p.released_amount, p.requested_amount, 0);
  v_pay_deferred := not v_rule.own_production and exists (
    select 1 from public.commission_group_rule_items i join public.commission_component_types t on t.id = i.component_type_id
    where i.rule_id = v_rule.id and t.tech_key = 'deferred' and i.distributed_pct > 0);

  perform set_config('corban.commission_rpc', 'on', true);
  update public.proposal_commission_calcs set status = 'superseded' where proposal_id = p.id and status = 'active';
  insert into public.proposal_commission_calcs (organization_id, proposal_id, condition_id, mode, tax_rate_pct, tax_exempt, manager_pct, supervisor_pct,
    pay_deferred, gross_amount, net_amount, installments, originator_user_id, supervisor_user_id, manager_user_id, seller_id, rule_ids, calculated_by,
    group_id, group_rule_id, ir_withheld_pct)
  values (v_org, p.id, v_cond.id, 'group_values', v_cond.tax_pct, v_cond.tax_pct = 0, v_rule.manager_pct, v_rule.supervisor_pct,
    v_pay_deferred, v_gross, v_net, p.term, v_orig, v_sup, v_mgr, v_seller.id, array[v_rule.id], auth.uid(),
    v_seller.commission_group_id, v_rule.id, v_ir)
  returning id into v_calc;

  for c in
    select t.id as type_id, t.tech_key, k.value_kind, k.received_value, k.calculation_base
    from public.commercial_condition_components k join public.commission_component_types t on t.id = k.component_type_id
    where k.condition_id = v_cond.id order by t.sort_order
  loop
    -- A % without its base (gross or net) is never guessed.
    if c.value_kind = 'percentage' and nullif(btrim(coalesce(c.calculation_base, '')), '') is null then raise exception 'calculation_base_missing'; end if;
    v_base := case when upper(c.calculation_base) like 'L%' then v_net else v_gross end;
    v_received := case when c.value_kind = 'fixed_brl' then round(c.received_value, 2) else round(v_base * c.received_value / 100, 2) end;

    v_o := 0;
    if not v_rule.own_production then
      select * into it from public.commission_group_rule_items i where i.rule_id = v_rule.id and i.component_type_id = c.type_id;
      if it.rule_id is not null and it.distributed_pct > 0 then
        if it.reference_kind = 'company' then
          v_ref := v_received;
        else
          select case when g.value_kind = 'fixed_brl' then round(g.value, 2) else round(v_base * g.value / 100, 2) end into v_ref
          from public.commercial_condition_group_values g
          where g.condition_id = v_cond.id and g.component_type_id = c.type_id
            and g.group_id = case when it.reference_kind = 'own' then v_seller.commission_group_id else it.reference_group_id end;
        end if;
        v_o := round(coalesce(v_ref, 0) * it.distributed_pct / 100, 2);
      end if;
    end if;

    v_s := 0; v_m := 0;
    if v_sup is not null then
      v_s := round(case v_rule.supervisor_basis when 'spread' then greatest(v_received - v_o, 0) when 'payout' then v_o
                    else case when c.tech_key = 'upfront' then v_gross else 0 end end * v_rule.supervisor_pct / 100, 2);
    end if;
    if v_mgr is not null then
      v_m := round(case v_rule.manager_basis when 'spread' then greatest(v_received - v_o, 0) when 'payout' then v_o
                    else case when c.tech_key = 'upfront' then v_gross else 0 end end * v_rule.manager_pct / 100, 2);
    end if;
    if v_o + v_s + v_m > v_received then raise exception 'payout_exceeds_received'; end if;
    if v_received = 0 then continue; end if;

    v_t := round(v_received * v_cond.tax_pct / 100, 2);
    v_i := round(v_received * v_ir / 100, 2);

    if c.tech_key = 'deferred' and coalesce(p.term, 0) > 0 then
      insert into public.proposal_commission_lines (organization_id, calc_id, component_key, part, multiplier, line_kind, amount)
      select v_org, v_calc, c.tech_key, x.part, x.mult, x.kind, x.amt
      from (
        with s as (
          select kk.kind, d.standard, d.last
          from (values ('received', v_received), ('tax', v_t), ('ir_withheld', v_i), ('manager', v_m), ('supervisor', v_s), ('originator', v_o)) kk(kind, total)
          cross join lateral private.deferred_schedule(kk.total, p.term) d
        )
        select 'deferred_standard' as part, p.term - 1 as mult, s.kind, s.standard as amt from s
        union all select 'deferred_last', 1, s.kind, s.last from s
        union all select 'deferred_standard', p.term - 1, 'company', sum(case when s.kind = 'received' then s.standard else -s.standard end) from s
        union all select 'deferred_last', 1, 'company', sum(case when s.kind = 'received' then s.last else -s.last end) from s
      ) x;
    else
      insert into public.proposal_commission_lines (organization_id, calc_id, component_key, part, multiplier, line_kind, amount)
      select v_org, v_calc, c.tech_key, 'upfront', 1, x.kind, x.amt
      from (values ('received', v_received), ('tax', v_t), ('ir_withheld', v_i), ('manager', v_m), ('supervisor', v_s), ('originator', v_o),
                   ('company', v_received - v_t - v_i - v_m - v_s - v_o)) x(kind, amt);
    end if;
  end loop;
  perform set_config('corban.commission_rpc', 'off', true);
  return v_calc;
end
$$;
revoke all on function public.calculate_contract_commission(uuid, uuid) from public, anon;
grant execute on function public.calculate_contract_commission(uuid, uuid) to authenticated;
