-- Seller credit, physical file and payment dates, part C3 of the payout bridge (owner decisions 26/09/2026, ADR-0041).
--
-- 1. "Pago ao cliente em": the date the contract was paid to the client is recorded when the contract moves to paid
--    (not in the future); it can be corrected in the contract file.
-- 2. Physical file: every table says whether its contracts are digital or physical (default digital); a contract takes
--    it from its table and can be changed. A physical contract has three milestones (received by the company, sent to
--    the bank, received by the bank), each with date, time and who.
-- 3. Seller credit: released only when the contract is paid to the client, (when physical) the company received the
--    file, and the bank's commission was received by the company and reconciled (a divergent receipt waits until
--    finance accepts it). Then what is payable to the seller (the rule or the owner's change) is credited to the
--    seller's payout account automatically, and supervisor/manager get theirs by the group rule. Deferred is credited
--    month by month when the bank pays each installment, only to sellers enabled to receive it. Any later change (edit,
--    payout change, seller change) before the seller is paid is posted as an adjustment with the difference; nothing
--    is deleted. The ChatGPT-era credit on bank receipts stays only for contracts of the old engine.
-- 4. Closing by frequency: each seller has their own payment frequency (daily, weekly, biweekly, monthly); closing a
--    period closes the accounts of one frequency. A payment already made outside Corban can be registered by the owner
--    (date and reference), which also locks the contract.

-- Frequencies: biweekly for sellers, daily for the company default.
alter table public.commercial_sellers drop constraint commercial_sellers_commission_payment_frequency_check;
alter table public.commercial_sellers add constraint commercial_sellers_commission_payment_frequency_check
  check (commission_payment_frequency in ('daily', 'weekly', 'biweekly', 'monthly'));
alter table public.commercial_sellers add column receives_deferred boolean not null default false;
alter table public.payout_settings drop constraint payout_settings_closing_frequency_check;
alter table public.payout_settings add constraint payout_settings_closing_frequency_check
  check (closing_frequency in ('daily', 'weekly', 'biweekly', 'monthly'));

-- Formalization and the physical milestones.
alter table public.product_tables add column formalization text not null default 'digital' check (formalization in ('digital', 'physical'));
alter table public.proposals_v2
  add column formalization text not null default 'digital' check (formalization in ('digital', 'physical')),
  add column paid_to_client_on date,
  add column physical_received_at timestamptz,
  add column physical_received_by uuid references auth.users(id) on delete set null,
  add column physical_sent_at timestamptz,
  add column physical_sent_by uuid references auth.users(id) on delete set null,
  add column physical_bank_at timestamptz,
  add column physical_bank_by uuid references auth.users(id) on delete set null;
create index proposals_v2_physical_received_by_idx on public.proposals_v2 (physical_received_by);
create index proposals_v2_physical_sent_by_idx on public.proposals_v2 (physical_sent_by);
create index proposals_v2_physical_bank_by_idx on public.proposals_v2 (physical_bank_by);

-- A new contract takes the formalization of its table.
create or replace function private.contract_formalization_from_table()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  select t.formalization into new.formalization
  from public.product_table_versions v join public.product_tables t on t.id = v.product_table_id
  where v.id = new.product_table_version_id;
  new.formalization := coalesce(new.formalization, 'digital');
  return new;
end
$$;
revoke all on function private.contract_formalization_from_table() from public, anon, authenticated;
create trigger proposals_v2_10_formalization before insert on public.proposals_v2
  for each row execute function private.contract_formalization_from_table();

create or replace function public.set_table_formalization(p_table uuid, p_formalization text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare t public.product_tables%rowtype;
begin
  select * into t from public.product_tables where id = p_table;
  if t.id is null or auth.uid() is null or not public.has_active_organization_role(t.organization_id, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  if p_formalization not in ('digital', 'physical') then raise exception 'invalid_formalization'; end if;
  perform set_config('corban.catalog_rpc', 'on', true);
  update public.product_tables set formalization = p_formalization where id = t.id;
  perform set_config('corban.catalog_rpc', 'off', true);
end
$$;
revoke all on function public.set_table_formalization(uuid, text) from public, anon;
grant execute on function public.set_table_formalization(uuid, text) to authenticated;

alter table public.contract_events drop constraint contract_events_kind_check;
alter table public.contract_events add constraint contract_events_kind_check
  check (kind in ('edit', 'note', 'recalculated', 'payout_override', 'payout_override_cleared', 'calc_failed', 'physical', 'external_payout'));
drop policy contract_events_select on public.contract_events;
create policy contract_events_select on public.contract_events for select to authenticated
  using (exists (select 1 from public.proposals_v2 p where p.id = proposal_id and p.organization_id = contract_events.organization_id
                 and public.is_active_organization_member(p.organization_id) and private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by))
         and (kind in ('edit', 'note', 'recalculated', 'calc_failed', 'physical') or public.has_permission(organization_id, 'financeiro.view')));

-- Record one physical milestone (in order: received -> sent -> bank). A date can be corrected; the history keeps it.
create or replace function public.set_contract_physical(p_proposal uuid, p_step text, p_at timestamptz)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare p public.proposals_v2%rowtype;
begin
  select * into p from public.proposals_v2 where id = p_proposal for update;
  if p.id is null or auth.uid() is null or not public.is_active_organization_member(p.organization_id)
     or not private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by)
     or not public.has_permission(p.organization_id, 'esteira.edit') then raise exception 'not_authorized'; end if;
  if p.formalization <> 'physical' then raise exception 'contract_not_physical'; end if;
  if p_at is null or p_at > now() + interval '5 minutes' then raise exception 'invalid_physical_date'; end if;
  if p_step = 'sent' and p.physical_received_at is null then raise exception 'physical_out_of_order'; end if;
  if p_step = 'bank' and p.physical_sent_at is null then raise exception 'physical_out_of_order'; end if;
  if p_step not in ('received', 'sent', 'bank') then raise exception 'invalid_physical_step'; end if;
  perform set_config('corban.proposal_rpc', 'on', true);
  update public.proposals_v2
  set physical_received_at = case when p_step = 'received' then p_at else physical_received_at end,
      physical_received_by = case when p_step = 'received' then auth.uid() else physical_received_by end,
      physical_sent_at = case when p_step = 'sent' then p_at else physical_sent_at end,
      physical_sent_by = case when p_step = 'sent' then auth.uid() else physical_sent_by end,
      physical_bank_at = case when p_step = 'bank' then p_at else physical_bank_at end,
      physical_bank_by = case when p_step = 'bank' then auth.uid() else physical_bank_by end,
      updated_at = now()
  where id = p.id;
  perform set_config('corban.proposal_rpc', 'off', true);
  perform set_config('corban.contract_rpc', 'on', true);
  insert into public.contract_events (organization_id, proposal_id, kind, detail, actor_user_id)
  values (p.organization_id, p.id, 'physical', jsonb_build_object('step', p_step, 'at', p_at), auth.uid());
  perform set_config('corban.contract_rpc', 'off', true);
end
$$;
revoke all on function public.set_contract_physical(uuid, text, timestamptz) from public, anon;
grant execute on function public.set_contract_physical(uuid, text, timestamptz) to authenticated;

-- Contract credits carry their origin, commission type and installment.
alter table public.payout_entries
  add column source text check (source in ('receipt', 'contract')),
  add column component_key text check (component_key is null or length(component_key) between 1 and 40),
  add column installment_number integer check (installment_number is null or installment_number > 0);
alter table public.payout_entries drop constraint payout_entry_source;
alter table public.payout_entries add constraint payout_entry_source check (
  (kind not in ('commission', 'chargeback') or (beneficiary_role is not null and (receipt_id is not null or source = 'contract')))
  and (source is distinct from 'contract' or (proposal_id is not null and beneficiary_role is not null and kind in ('commission', 'adjustment')))
  and (kind in ('commission', 'chargeback') or source = 'contract' or beneficiary_role is null));
create index payout_entries_contract_idx on public.payout_entries (proposal_id, source, beneficiary_role, account_id);

-- Where the bank's commission of the contract stands: 'reconciled' once the company received it and it matches (or
-- finance accepted the difference), 'divergent' while a difference waits for finance, null while nothing arrived. The
-- receipt that counts is the à vista; a contract with no à vista counts its first receipt.
create or replace function private.contract_bank_receipt(p_proposal uuid)
returns text
language sql
stable
security definer
set search_path to ''
as $$
  with relevant as (
    select r.reconciliation = 'matched' or exists (select 1 from public.commission_receipt_resolutions z where z.receipt_id = r.id) as reconciled
    from public.commission_receipts r
    where r.proposal_id = p_proposal and r.entry_kind = 'receipt'
      and (r.component_key = 'upfront'
           or not exists (select 1 from private.contract_payable(p_proposal) x where x.component_key = 'upfront' and x.received > 0))
  )
  select case when bool_or(reconciled) then 'reconciled' when count(*) > 0 then 'divergent' end from relevant
$$;
revoke all on function private.contract_bank_receipt(uuid) from public, anon, authenticated;

-- The seller's commission is released only when all hold: paid to the client; when physical, the file received by the
-- company; the calculation in force; and the bank's commission received by the company and reconciled.
create or replace function private.contract_credit_released(p_proposal uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (select 1 from public.proposals_v2 p
                 where p.id = p_proposal and p.status = 'paid' and (p.formalization = 'digital' or p.physical_received_at is not null)
                   and exists (select 1 from public.proposal_commission_calcs c where c.proposal_id = p.id and c.status = 'active')
                   and private.contract_bank_receipt(p.id) = 'reconciled')
$$;
revoke all on function private.contract_credit_released(uuid) from public, anon, authenticated;

-- Bring the contract's credits (everything but deferred) to what is due now, per account and role: the first credit is
-- a commission entry, any later difference an adjustment. The seller's part stops moving once the seller was paid.
-- p_force credits the seller's part before release: only for a payment the owner already made outside Corban.
create or replace function private.sync_contract_credit(p_proposal uuid, p_force boolean default false)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  p public.proposals_v2%rowtype;
  c public.proposal_commission_calcs%rowtype;
  v_released boolean;
  v_paid boolean;
  r record;
begin
  select * into p from public.proposals_v2 where id = p_proposal;
  if p.id is null then return; end if;
  select * into c from public.proposal_commission_calcs where proposal_id = p.id and status = 'active';
  -- Calculations of the old rule credit per receipt (post_receipt); only the table and group engine credits here.
  if c.id is not null and c.mode <> 'group_values' then return; end if;
  v_released := private.contract_credit_released(p.id);
  v_paid := private.contract_payout_received(p.id);
  perform set_config('corban.payout_rpc', 'on', true);
  for r in
    with target as (
      select 'originator'::text as role, private.payout_account_for(p.organization_id, c.seller_id, c.originator_user_id) as account,
             coalesce((select sum(x.payable) from private.contract_payable(p.id) x where x.component_key <> 'deferred'), 0) as amount
      where (v_released or p_force) and c.id is not null and not v_paid
      union all
      select 'supervisor', private.payout_account_for(p.organization_id, null, c.supervisor_user_id),
             coalesce((select sum(l.amount * l.multiplier) from public.proposal_commission_lines l where l.calc_id = c.id and l.line_kind = 'supervisor' and l.component_key <> 'deferred'), 0)
      where v_released and c.supervisor_user_id is not null
      union all
      select 'manager', private.payout_account_for(p.organization_id, null, c.manager_user_id),
             coalesce((select sum(l.amount * l.multiplier) from public.proposal_commission_lines l where l.calc_id = c.id and l.line_kind = 'manager' and l.component_key <> 'deferred'), 0)
      where v_released and c.manager_user_id is not null
    ),
    existing as (
      select e.beneficiary_role as role, e.account_id as account, sum(e.amount) as amount
      from public.payout_entries e
      where e.proposal_id = p.id and e.source = 'contract' and e.status <> 'rejected'
        and not (v_paid and e.beneficiary_role = 'originator')
      group by 1, 2
    )
    select coalesce(t.role, x.role) as role, coalesce(t.account, x.account) as account,
           coalesce(t.amount, 0) - coalesce(x.amount, 0) as diff, coalesce(x.amount, 0) = 0 as first
    from target t full join existing x on x.role = t.role and x.account = t.account
  loop
    if r.account is not null and r.diff <> 0 then
      insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, proposal_id, beneficiary_role, description, status, created_by, source)
      values (p.organization_id, r.account, case when r.first and r.diff > 0 then 'commission' else 'adjustment' end, r.diff, current_date, p.id, r.role,
              left((case when r.first and r.diff > 0 then 'Comissão do contrato' else 'Ajuste da comissão do contrato' end)
                   || coalesce(' ' || p.external_proposal_id, '') || coalesce(' · ' || (p.customer_snapshot->>'full_name'), ''), 200),
              'approved', auth.uid(), 'contract');
    end if;
  end loop;
  perform set_config('corban.payout_rpc', 'off', true);
  -- Deferred installments reconciled before the release are credited now (post_receipt skips what it already posted).
  if v_released then
    for r in select x.id from public.commission_receipts x
             where x.proposal_id = p.id and x.entry_kind = 'receipt' and x.component_key = 'deferred'
               and (x.reconciliation = 'matched' or exists (select 1 from public.commission_receipt_resolutions z where z.receipt_id = x.id))
             order by x.installment_number loop
      perform private.post_receipt(r.id);
    end loop;
    perform set_config('corban.payout_rpc', 'off', true);
  end if;
end
$$;
revoke all on function private.sync_contract_credit(uuid, boolean) from public, anon, authenticated;

-- At commit, after whatever changed the contract (status, physical, edit, calculation, payout change, bank receipt or
-- the acceptance of a divergent one).
create or replace function private.sync_contract_credit_trigger()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if tg_table_name = 'proposals_v2' then
    perform private.sync_contract_credit((to_jsonb(new)->>'id')::uuid);
  elsif tg_table_name = 'commission_receipt_resolutions' then
    perform private.sync_contract_credit((select x.proposal_id from public.commission_receipts x where x.id = (to_jsonb(new)->>'receipt_id')::uuid));
  else
    perform private.sync_contract_credit((to_jsonb(new)->>'proposal_id')::uuid);
  end if;
  return null;
end
$$;
revoke all on function private.sync_contract_credit_trigger() from public, anon, authenticated;
create constraint trigger proposals_v2_95_sync_credit after update on public.proposals_v2
  deferrable initially deferred for each row execute function private.sync_contract_credit_trigger();
create constraint trigger proposal_commission_calcs_95_sync_credit after insert on public.proposal_commission_calcs
  deferrable initially deferred for each row execute function private.sync_contract_credit_trigger();
create constraint trigger contract_payout_overrides_95_sync_credit after insert on public.contract_payout_overrides
  deferrable initially deferred for each row execute function private.sync_contract_credit_trigger();
create constraint trigger commission_receipts_95_sync_credit after insert on public.commission_receipts
  deferrable initially deferred for each row execute function private.sync_contract_credit_trigger();
create constraint trigger commission_receipt_resolutions_95_sync_credit after insert on public.commission_receipt_resolutions
  deferrable initially deferred for each row execute function private.sync_contract_credit_trigger();

-- The calculation no longer stops at posted credits: a recalculation before the seller is paid becomes an adjustment.

create or replace function private.contract_commission_core(p_proposal_id uuid, p_condition_id uuid default null)
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
  if v_org is null then raise exception 'proposal_not_found'; end if;
  -- A paid contract can still be recalculated (it may be edited until the seller receives); a rejected or cancelled
  -- one keeps its last calculation; nothing moves once the seller received the commission.
  if p.status in ('rejected', 'cancelled') and exists (select 1 from public.proposal_commission_calcs x where x.proposal_id = p.id and x.status = 'active') then
    raise exception 'commission_frozen';
  end if;
  if private.contract_payout_received(p.id) then raise exception 'contract_payout_received'; end if;

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
revoke all on function private.contract_commission_core(uuid, uuid) from public, anon, authenticated;

-- Deferred of the new engine: credited per installment (part C3).
create or replace function private.post_receipt(p_receipt uuid)
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  x public.commission_receipts%rowtype;
  c public.proposal_commission_calcs%rowtype;
  d record;
  v_base numeric;
  v_ratio numeric;
  r record;
  v_debit numeric;
  v_total numeric;
  v_amount numeric;
  v_sched record;
  v_account uuid;
begin
  select * into x from public.commission_receipts where id = p_receipt;
  if x.id is null or exists (select 1 from public.payout_entries where receipt_id = x.id) then return; end if;
  perform set_config('corban.payout_rpc', 'on', true);

  if x.entry_kind = 'receipt' then
    select * into c from public.proposal_commission_calcs where id = x.calc_id;
    if c.id is null or (x.component_key = 'deferred' and not c.pay_deferred) then return; end if;
    if c.mode = 'group_values' then
      -- Part C3: à vista and the other types are credited with the contract (sync_contract_credit); deferred is
      -- credited here, installment by installment, only to a seller enabled to receive it and once the credit is due.
      if x.component_key <> 'deferred' or x.installment_number is null or coalesce(c.installments, 0) < 1 then return; end if;
      if not coalesce((select s.receives_deferred from public.commercial_sellers s where s.id = c.seller_id), false) then return; end if;
      if not private.contract_credit_released(x.proposal_id) then return; end if;
      select payable into v_total from private.contract_payable(x.proposal_id) where component_key = 'deferred';
      if coalesce(v_total, 0) <= 0 then return; end if;
      select * into v_sched from private.deferred_schedule(v_total, c.installments);
      v_amount := case when x.installment_number >= c.installments then v_sched.last else v_sched.standard end;
      v_account := private.payout_account_for(x.organization_id, c.seller_id, c.originator_user_id);
      if v_amount > 0 and v_account is not null then
        insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, proposal_id, receipt_id, beneficiary_role, description, status, created_by,
                                           source, component_key, installment_number)
        values (x.organization_id, v_account, 'commission', v_amount, current_date, x.proposal_id, x.id, 'originator',
                'Comissão diferido parcela ' || x.installment_number, 'approved', auth.uid(), 'receipt', 'deferred', x.installment_number);
      end if;
      return;
    end if;
    select * into d from private.distribute_commission_amount(x.amount, c.mode, c.tax_rate_pct, c.tax_exempt, c.profit_pct, c.manager_pct, c.supervisor_pct, c.originator_pct,
      c.group_share_pct, c.manager_user_id is not null, c.supervisor_user_id is not null, c.seller_id is not null or c.originator_user_id is not null);
    -- The originator is the proposal's seller when there is one (a seller without login included).
    insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, proposal_id, receipt_id, beneficiary_role, description, status, created_by)
    select x.organization_id, v.account, 'commission', v.amount, current_date, x.proposal_id, x.id, v.role,
           case when x.component_key = 'deferred' then 'Comissão diferido parcela ' || x.installment_number else 'Comissão à vista' end, 'approved', auth.uid()
    from (values ('originator', private.payout_account_for(x.organization_id, c.seller_id, c.originator_user_id), d.originator),
                 ('supervisor', private.payout_account_for(x.organization_id, null, c.supervisor_user_id), d.supervisor),
                 ('manager', private.payout_account_for(x.organization_id, null, c.manager_user_id), d.manager)) v(role, account, amount)
    where v.account is not null and v.amount > 0;
  else
    -- Base: what the contract received, less the chargebacks already posted.
    select coalesce(sum(amount), 0) into v_base from public.commission_receipts where proposal_id = x.proposal_id and entry_kind = 'receipt';
    v_base := v_base - coalesce((select sum(k.amount) from public.commission_receipts k
                                 where k.proposal_id = x.proposal_id and k.entry_kind = 'chargeback' and k.id <> x.id
                                   and exists (select 1 from public.payout_entries e where e.receipt_id = k.id)), 0);
    if v_base <= 0 then return; end if;
    v_ratio := least(1, x.amount / v_base);
    for r in
      select e.account_id, e.beneficiary_role, sum(e.amount) as net
      from public.payout_entries e
      where e.proposal_id = x.proposal_id and e.kind in ('commission','chargeback','adjustment') and e.status = 'approved'
      group by e.account_id, e.beneficiary_role
      having sum(e.amount) > 0
    loop
      v_debit := least(r.net, round(r.net * v_ratio, 2));
      if v_debit > 0 then
        insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, proposal_id, receipt_id, beneficiary_role, description, status, created_by)
        values (x.organization_id, r.account_id, 'chargeback', -v_debit, current_date, x.proposal_id, x.id, r.beneficiary_role, 'Estorno do banco', 'approved', auth.uid());
      end if;
    end loop;
  end if;
end
$function$;

-- Editing a contract also covers its formalization and the date it was paid to the client.
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
    if p_data ? 'paid_to_client_on' then n.paid_to_client_on := nullif(p_data->>'paid_to_client_on', '')::date; end if;
    if p_data ? 'formalization' then n.formalization := p_data->>'formalization'; end if;
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
  if n.formalization not in ('digital', 'physical') then raise exception 'invalid_formalization'; end if;
  if n.paid_to_client_on is distinct from p.paid_to_client_on and (p.status <> 'paid' or n.paid_to_client_on is null or n.paid_to_client_on > current_date) then
    raise exception 'invalid_paid_on';
  end if;
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
  if n.formalization is distinct from p.formalization then v_changes := v_changes || jsonb_build_object('formalization', jsonb_build_object('from', p.formalization, 'to', n.formalization)); end if;
  if n.paid_to_client_on is distinct from p.paid_to_client_on then v_changes := v_changes || jsonb_build_object('paid_to_client_on', jsonb_build_object('from', p.paid_to_client_on, 'to', n.paid_to_client_on)); end if;
  if v_changes = '{}'::jsonb then return; end if;

  perform set_config('corban.contract_edit_rpc', 'on', true);
  update public.proposals_v2
  set product_table_version_id = n.product_table_version_id, seller_id = n.seller_id, requested_amount = n.requested_amount,
      released_amount = n.released_amount, installment_amount = n.installment_amount, term = n.term,
      commercial_snapshot = n.commercial_snapshot, formalization = n.formalization, paid_to_client_on = n.paid_to_client_on, updated_at = now()
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

-- "Pago ao cliente em" when moving to paid.
drop function public.move_operational_case(uuid, text, text, timestamptz);
CREATE OR REPLACE FUNCTION public.move_operational_case(p_case_id uuid, p_to_state text, p_note text DEFAULT NULL::text, p_pendency_due_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_paid_on date DEFAULT NULL::date)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c public.operational_cases%rowtype;
  v_stage uuid;
  v_sla integer;
  v_status text;
  v_paid_on date := coalesce(p_paid_on, current_date);
begin
  select * into c from public.operational_cases where id = p_case_id for update;
  if not found or not public.is_active_organization_member(c.organization_id) then raise exception 'operational_case_not_found_or_forbidden'; end if;
  -- The caller must see the proposal (scope) and be allowed to edit the pipeline.
  if not exists (
    select 1 from public.proposals_v2 p
    where p.id = c.proposal_id and private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by)
  ) then raise exception 'operational_case_not_found_or_forbidden'; end if;
  if not public.has_permission(c.organization_id, 'esteira.edit') then raise exception 'not_authorized'; end if;

  if not (
    (p_to_state = 'pending_external' and c.canonical_state in ('submitted','approved')) or
    (p_to_state = 'submitted' and c.canonical_state = 'pending_external') or
    (p_to_state = 'paid' and c.canonical_state in ('submitted','pending_external','approved'))
  ) then
    -- Not one of the new moves: the governed transition decides (and enforces its own rules).
    return public.transition_operational_case(p_case_id, p_to_state, null);
  end if;

  if p_to_state in ('pending_external','paid') and (p_note is null or length(btrim(p_note)) < 3) then raise exception 'note_required'; end if;
  if p_to_state = 'pending_external' and (p_pendency_due_at is null or p_pendency_due_at < now()) then raise exception 'pendency_due_required'; end if;
  if p_to_state = 'paid' and v_paid_on > current_date then raise exception 'invalid_paid_on'; end if;

  select s.id, s.sla_minutes into v_stage, v_sla from public.operational_stages s
  where s.organization_id = c.organization_id and s.canonical_state = p_to_state and s.is_active
  order by s.sort_order, s.created_at limit 1;
  if v_stage is null then raise exception 'target_operational_stage_not_configured'; end if;

  perform set_config('corban.operational_rpc', 'on', true);
  perform set_config('corban.proposal_rpc', 'on', true);
  update public.operational_cases
  set current_stage_id = v_stage,
      canonical_state = p_to_state,
      entered_stage_at = now(),
      due_at = case when v_sla is null then null else now() + make_interval(mins => v_sla) end,
      pendency_reason = case when p_to_state = 'pending_external' then btrim(p_note) else null end,
      pendency_due_at = case when p_to_state = 'pending_external' then p_pendency_due_at else null end,
      updated_at = now()
  where id = c.id;

  select p.status into v_status from public.proposals_v2 p where p.id = c.proposal_id for update;
  if p_to_state = 'paid' then
    -- The proposal status machine only allows approved -> paid.
    if v_status in ('digitization') then
      update public.proposals_v2 set status = 'submitted', updated_at = now() where id = c.proposal_id;
      v_status := 'submitted';
    end if;
    if v_status = 'submitted' then
      update public.proposals_v2 set status = 'approved', updated_at = now() where id = c.proposal_id;
    end if;
    perform set_config('corban.paid_evidence_rpc', 'on', true);
    update public.proposals_v2 set status = 'paid', paid_to_client_on = v_paid_on, updated_at = now() where id = c.proposal_id;
    insert into public.proposal_status_evidence (organization_id, proposal_id, canonical_status, raw_status, evidenced_at, created_by, source, note)
    values (c.organization_id, c.proposal_id, 'paid', 'manual', now(), auth.uid(), 'manual', btrim(p_note));
    perform set_config('corban.paid_evidence_rpc', 'off', true);
  elsif v_status not in ('submitted') and p_to_state in ('submitted','pending_external') then
    if v_status = 'digitization' then
      update public.proposals_v2 set status = 'submitted', updated_at = now() where id = c.proposal_id;
    end if;
  end if;

  insert into public.operational_events (organization_id, operational_case_id, event_type, from_state, to_state, source, actor_user_id, metadata)
  values (c.organization_id, c.id, 'state_transition', c.canonical_state, p_to_state, 'corban_os', auth.uid(),
          jsonb_build_object('note', nullif(btrim(coalesce(p_note, '')), ''), 'pendency_due_at', p_pendency_due_at, 'paid_on', case when p_to_state = 'paid' then v_paid_on end));
  perform set_config('corban.operational_rpc', 'off', true);
  perform set_config('corban.proposal_rpc', 'off', true);
  return p_to_state;
end
$function$;
revoke all on function public.move_operational_case(uuid, text, text, timestamptz, date) from public, anon;
grant execute on function public.move_operational_case(uuid, text, text, timestamptz, date) to authenticated;

-- Closing one frequency at a time.
drop function public.close_payout_period(uuid, date);
CREATE OR REPLACE FUNCTION public.close_payout_period(p_org uuid, p_period_end date, p_frequency text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_limit numeric;
  a record;
  prev public.payouts%rowtype;
  v_net numeric;
  v_first date;
  v_carry numeric;
  v_amount numeric;
  v_id uuid;
  v_count int := 0;
begin
  if auth.uid() is null or not (public.has_permission(p_org, 'repasse.create') or public.has_permission(p_org, 'repasse.edit')) then raise exception 'not_authorized'; end if;
  if p_period_end is null or p_period_end > current_date then raise exception 'invalid_period_end'; end if;
  if p_frequency is not null and p_frequency not in ('daily', 'weekly', 'biweekly', 'monthly') then raise exception 'invalid_frequency'; end if;
  select coalesce((select debt_limit_pct from public.payout_settings where organization_id = p_org), 30) into v_limit;
  perform set_config('corban.payout_rpc', 'on', true);

  for a in select id from public.payout_accounts where organization_id = p_org and private.payout_model(id) = 'closing'
                and (p_frequency is null or private.payout_frequency(id) = p_frequency) order by created_at for update loop
    -- An account with an unpaid statement waits until it is paid or cancelled.
    if exists (select 1 from public.payouts where account_id = a.id and kind = 'closing' and status in ('pending','approved')) then continue; end if;
    select coalesce(sum(amount), 0), min(effective_on) into v_net, v_first from public.payout_entries
    where account_id = a.id and status = 'approved' and statement_id is null and kind <> 'payout' and effective_on <= p_period_end;
    if v_first is null then continue; end if;
    select * into prev from public.payouts where account_id = a.id and kind = 'closing' and status in ('paid','settled') order by period_end desc, requested_at desc limit 1;
    v_carry := coalesce(prev.carry_out, 0);
    if v_carry >= 0 then
      v_amount := greatest(0, v_carry + v_net);
    elsif v_net <= 0 then
      v_amount := 0;
    else
      v_amount := v_net - least(-v_carry, trunc(v_net * v_limit / 100, 2));
    end if;
    insert into public.payouts (organization_id, account_id, kind, period_start, period_end, carry_in, period_net, debt_deduction, amount, carry_out, status, requested_by)
    values (p_org, a.id, 'closing', least(coalesce(prev.period_end + 1, v_first), v_first), p_period_end, v_carry, v_net,
            case when v_carry < 0 and v_net > 0 then v_net - v_amount else 0 end, v_amount, v_carry + v_net - v_amount,
            case when v_amount > 0 then 'pending' else 'settled' end, auth.uid())
    returning id into v_id;
    update public.payout_entries set statement_id = v_id
    where account_id = a.id and status = 'approved' and statement_id is null and kind <> 'payout' and effective_on <= p_period_end;
    v_count := v_count + 1;
  end loop;
  perform set_config('corban.payout_rpc', 'off', true);
  return v_count;
end
$function$;
revoke all on function public.close_payout_period(uuid, date, text) from public, anon;
grant execute on function public.close_payout_period(uuid, date, text) to authenticated;

-- The seller file gains the payment frequency and the deferred switch.
CREATE OR REPLACE FUNCTION public.save_seller(p_org uuid, p_seller uuid, p_data jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_seller uuid;
  v_name text := btrim(coalesce(p_data->>'name', ''));
  v_tax text := regexp_replace(coalesce(p_data->>'tax_id', ''), '\D', '', 'g');
  v_cat text := p_data->>'category';
  v_group uuid;
  v_branch uuid;
  p jsonb := coalesce(p_data->'profile', '{}'::jsonb);
  v_mobile text;
  v_whats text;
  v_email text := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
  a jsonb;
  c jsonb;
  v_acc public.seller_bank_accounts%rowtype;
  v_new public.seller_bank_accounts%rowtype;
  v_id uuid;
  v_primary uuid;
  v_key text;
  v_doc text;
  v_email_re constant text := '^[^\s@]+@[^\s@]+\.[^\s@]+$';
begin
  if auth.uid() is null or p_org is null or not public.has_active_organization_role(p_org, array['admin', 'manager']) then
    raise exception 'not_authorized';
  end if;

  -- Required: name, CPF/CNPJ, mobile, e-mail.
  if length(v_name) not between 1 and 160 then raise exception 'seller_name_required'; end if;
  if not ((length(v_tax) = 11 and private.is_valid_cpf(v_tax)) or (length(v_tax) = 14 and private.is_valid_cnpj(v_tax))) then raise exception 'seller_tax_id_invalid'; end if;
  if coalesce(v_cat, '') not in ('pf', 'pj', 'sub') then raise exception 'seller_category_invalid'; end if;
  v_mobile := private.normalize_phone(coalesce(p->>'mobile', ''));
  if v_mobile is null then raise exception 'seller_mobile_required'; end if;
  if v_email is null or v_email !~ v_email_re then raise exception 'seller_email_required'; end if;
  if nullif(btrim(coalesce(p->>'whatsapp', '')), '') is not null then
    v_whats := private.normalize_phone(p->>'whatsapp');
    if v_whats is null then raise exception 'seller_phone_invalid'; end if;
  end if;
  begin
    v_group := (p_data->>'group_id')::uuid;
    v_branch := nullif(p_data->>'branch_id', '')::uuid;
  exception when others then
    raise exception 'seller_group_invalid';
  end;
  if v_group is null or not exists (select 1 from public.commission_groups g where g.id = v_group and g.organization_id = p_org and g.is_active) then
    raise exception 'seller_group_invalid';
  end if;
  if v_branch is not null and not exists (select 1 from public.organization_branches b where b.id = v_branch and b.organization_id = p_org and b.is_active) then
    raise exception 'seller_branch_invalid';
  end if;
  if exists (select 1 from public.commercial_sellers s where s.organization_id = p_org and regexp_replace(s.tax_id, '[^0-9]', '', 'g') = v_tax and s.id is distinct from p_seller) then
    raise exception 'seller_tax_id_exists';
  end if;

  if p_seller is null then
    insert into public.commercial_sellers (organization_id, name, seller_category, tax_id, commission_group_id, branch_id, created_by)
    values (p_org, v_name, v_cat, v_tax, v_group, v_branch, auth.uid())
    returning id into v_seller;
  else
    select s.id into v_seller from public.commercial_sellers s where s.id = p_seller and s.organization_id = p_org for update;
    if v_seller is null then raise exception 'seller_not_found'; end if;
    update public.commercial_sellers
    set name = v_name, seller_category = v_cat, tax_id = v_tax, commission_group_id = v_group,
        branch_id = coalesce(v_branch, branch_id), updated_at = now()
    where id = v_seller;
  end if;
  -- Part C3: how often the seller is paid and whether they receive the deferred (month by month).
  if p_data ? 'payment_frequency' then
    if coalesce(p_data->>'payment_frequency', '') not in ('daily', 'weekly', 'biweekly', 'monthly') then raise exception 'seller_frequency_invalid'; end if;
    update public.commercial_sellers set commission_payment_frequency = p_data->>'payment_frequency' where id = v_seller;
  end if;
  if p_data ? 'receives_deferred' then
    update public.commercial_sellers set receives_deferred = coalesce((p_data->>'receives_deferred')::boolean, false) where id = v_seller;
  end if;

  perform set_config('corban.seller_profile_rpc', 'on', true);
  insert into public.seller_profiles (organization_id, seller_id, legal_name, trade_name, email, phone, whatsapp, other_phones,
    birth_or_opening_date, identity_or_registration_number, identity_issuer, rg_issued_on, mother_name, father_name,
    zip, street, number, complement, district, city, state,
    business_zip, business_street, business_number, business_complement, business_district, business_city, business_state,
    created_by, updated_by)
  values (p_org, v_seller, v_name, nullif(btrim(p->>'trade_name'), ''), v_email, v_mobile, v_whats, nullif(btrim(p->>'other_phones'), ''),
    nullif(p->>'birth_date', '')::date, nullif(btrim(p->>'rg'), ''), nullif(upper(btrim(p->>'rg_issuer')), ''), nullif(p->>'rg_issued_on', '')::date,
    nullif(btrim(p->>'mother_name'), ''), nullif(btrim(p->>'father_name'), ''),
    nullif(regexp_replace(coalesce(p->>'zip', ''), '\D', '', 'g'), ''), nullif(btrim(p->>'street'), ''), nullif(btrim(p->>'number'), ''),
    nullif(btrim(p->>'complement'), ''), nullif(btrim(p->>'district'), ''), nullif(btrim(p->>'city'), ''), nullif(upper(btrim(p->>'state')), ''),
    nullif(regexp_replace(coalesce(p->>'business_zip', ''), '\D', '', 'g'), ''), nullif(btrim(p->>'business_street'), ''), nullif(btrim(p->>'business_number'), ''),
    nullif(btrim(p->>'business_complement'), ''), nullif(btrim(p->>'business_district'), ''), nullif(btrim(p->>'business_city'), ''),
    nullif(upper(btrim(p->>'business_state')), ''),
    auth.uid(), auth.uid())
  on conflict (organization_id, seller_id) do update set
    legal_name = excluded.legal_name, trade_name = excluded.trade_name, email = excluded.email, phone = excluded.phone,
    whatsapp = excluded.whatsapp, other_phones = excluded.other_phones, birth_or_opening_date = excluded.birth_or_opening_date,
    identity_or_registration_number = excluded.identity_or_registration_number, identity_issuer = excluded.identity_issuer,
    rg_issued_on = excluded.rg_issued_on, mother_name = excluded.mother_name, father_name = excluded.father_name,
    zip = excluded.zip, street = excluded.street, number = excluded.number, complement = excluded.complement,
    district = excluded.district, city = excluded.city, state = excluded.state,
    business_zip = excluded.business_zip, business_street = excluded.business_street, business_number = excluded.business_number,
    business_complement = excluded.business_complement, business_district = excluded.business_district,
    business_city = excluded.business_city, business_state = excluded.business_state,
    updated_by = auth.uid(), updated_at = now();

  perform set_config('corban.seller_rpc', 'on', true);

  -- Bank accounts: existing rows are changed or removed (kept with removed_at); new rows are added. Every change is logged.
  if jsonb_typeof(coalesce(p_data->'accounts', '[]'::jsonb)) <> 'array' then raise exception 'seller_account_invalid'; end if;
  update public.seller_bank_accounts set is_primary = false, updated_at = now() where seller_id = v_seller and is_primary and removed_at is null;
  for a in select * from jsonb_array_elements(coalesce(p_data->'accounts', '[]'::jsonb)) loop
    v_id := nullif(a->>'id', '')::uuid;
    if v_id is not null then
      select * into v_acc from public.seller_bank_accounts x where x.id = v_id and x.seller_id = v_seller and x.removed_at is null;
      if v_acc.id is null then raise exception 'seller_account_not_found'; end if;
      if coalesce((a->>'remove')::boolean, false) then
        update public.seller_bank_accounts set removed_at = now(), removed_by = auth.uid(), is_primary = false, updated_at = now() where id = v_id;
        insert into public.seller_bank_account_events (organization_id, seller_id, account_id, action, before, actor)
        values (p_org, v_seller, v_id, 'removed', to_jsonb(v_acc) - 'is_primary' - 'updated_at', auth.uid());
        continue;
      end if;
    end if;

    v_key := nullif(btrim(coalesce(a->>'pix_key', '')), '');
    if a->>'transfer_method' = 'pix' then
      case a->>'pix_key_type'
        when 'cpf_cnpj' then
          v_key := regexp_replace(coalesce(v_key, ''), '\D', '', 'g');
          if not ((length(v_key) = 11 and private.is_valid_cpf(v_key)) or (length(v_key) = 14 and private.is_valid_cnpj(v_key))) then raise exception 'seller_pix_key_invalid'; end if;
        when 'phone' then
          v_key := private.normalize_phone(coalesce(v_key, ''));
          if v_key is null then raise exception 'seller_pix_key_invalid'; end if;
          v_key := '+' || v_key;
        when 'email' then
          v_key := lower(coalesce(v_key, ''));
          if v_key !~ v_email_re then raise exception 'seller_pix_key_invalid'; end if;
        when 'random' then
          v_key := lower(coalesce(v_key, ''));
          if v_key !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'seller_pix_key_invalid'; end if;
        else raise exception 'seller_pix_key_invalid';
      end case;
    elsif a->>'transfer_method' = 'ted' then
      v_key := null;
    else
      raise exception 'seller_account_invalid';
    end if;
    v_doc := nullif(regexp_replace(coalesce(a->>'holder_document', ''), '\D', '', 'g'), '');
    if v_doc is not null and not ((length(v_doc) = 11 and private.is_valid_cpf(v_doc)) or (length(v_doc) = 14 and private.is_valid_cnpj(v_doc))) then
      raise exception 'seller_holder_invalid';
    end if;

    begin
      if v_id is null then
        insert into public.seller_bank_accounts (organization_id, seller_id, transfer_method, account_type, bank_code, bank_name, branch,
          account_number, account_digit, pix_key_type, pix_key, holder_name, holder_document, note, created_by)
        values (p_org, v_seller, a->>'transfer_method', nullif(a->>'account_type', ''), nullif(btrim(a->>'bank_code'), ''), nullif(btrim(a->>'bank_name'), ''),
          nullif(btrim(a->>'branch'), ''), nullif(btrim(a->>'account_number'), ''), nullif(upper(btrim(a->>'account_digit')), ''),
          case when a->>'transfer_method' = 'pix' then a->>'pix_key_type' end, v_key,
          nullif(btrim(a->>'holder_name'), ''), v_doc, nullif(btrim(a->>'note'), ''), auth.uid())
        returning * into v_new;
        insert into public.seller_bank_account_events (organization_id, seller_id, account_id, action, after, actor)
        values (p_org, v_seller, v_new.id, 'added', to_jsonb(v_new) - 'is_primary' - 'updated_at', auth.uid());
      else
        update public.seller_bank_accounts set
          transfer_method = a->>'transfer_method', account_type = nullif(a->>'account_type', ''), bank_code = nullif(btrim(a->>'bank_code'), ''),
          bank_name = nullif(btrim(a->>'bank_name'), ''), branch = nullif(btrim(a->>'branch'), ''), account_number = nullif(btrim(a->>'account_number'), ''),
          account_digit = nullif(upper(btrim(a->>'account_digit')), ''), pix_key_type = case when a->>'transfer_method' = 'pix' then a->>'pix_key_type' end,
          pix_key = v_key, holder_name = nullif(btrim(a->>'holder_name'), ''), holder_document = v_doc, note = nullif(btrim(a->>'note'), ''), updated_at = now()
        where id = v_id
        returning * into v_new;
        if (to_jsonb(v_new) - 'is_primary' - 'updated_at') is distinct from (to_jsonb(v_acc) - 'is_primary' - 'updated_at') then
          insert into public.seller_bank_account_events (organization_id, seller_id, account_id, action, before, after, actor)
          values (p_org, v_seller, v_id, 'changed', to_jsonb(v_acc) - 'is_primary' - 'updated_at', to_jsonb(v_new) - 'is_primary' - 'updated_at', auth.uid());
        end if;
      end if;
    exception when check_violation then
      raise exception 'seller_account_invalid';
    end;
    if coalesce((a->>'primary')::boolean, false) and v_primary is null then v_primary := v_new.id; end if;
  end loop;
  -- Exactly one primary among the active accounts: the one marked, else the oldest.
  if v_primary is null then
    select x.id into v_primary from public.seller_bank_accounts x where x.seller_id = v_seller and x.removed_at is null order by x.created_at, x.id limit 1;
  end if;
  if v_primary is not null then update public.seller_bank_accounts set is_primary = true where id = v_primary; end if;

  -- Contacts: the list sent replaces the previous one.
  if jsonb_typeof(coalesce(p_data->'contacts', '[]'::jsonb)) <> 'array' then raise exception 'seller_contact_invalid'; end if;
  delete from public.seller_contacts where seller_id = v_seller;
  for c in select * from jsonb_array_elements(coalesce(p_data->'contacts', '[]'::jsonb)) loop
    v_doc := nullif(regexp_replace(coalesce(c->>'cpf', ''), '\D', '', 'g'), '');
    if v_doc is not null and not private.is_valid_cpf(v_doc) then raise exception 'seller_contact_invalid'; end if;
    if nullif(btrim(coalesce(c->>'email', '')), '') is not null and lower(btrim(c->>'email')) !~ v_email_re then raise exception 'seller_contact_invalid'; end if;
    begin
      insert into public.seller_contacts (organization_id, seller_id, name, cpf, role, mobile, email)
      values (p_org, v_seller, btrim(coalesce(c->>'name', '')), v_doc, nullif(btrim(c->>'role'), ''),
        case when nullif(btrim(coalesce(c->>'mobile', '')), '') is null then null else coalesce(private.normalize_phone(c->>'mobile'), 'x') end,
        nullif(lower(btrim(c->>'email')), ''));
    exception when check_violation then
      raise exception 'seller_contact_invalid';
    end;
  end loop;
  perform set_config('corban.seller_rpc', 'off', true);
  perform set_config('corban.seller_profile_rpc', 'off', true);

  return v_seller;
end
$function$;

-- How often an account is paid: the seller's frequency, otherwise the company default (monthly when not set).
create or replace function private.payout_frequency(p_account uuid)
returns text
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(
    (select s.commission_payment_frequency from public.payout_accounts a join public.commercial_sellers s on s.id = a.seller_id where a.id = p_account),
    (select ps.closing_frequency from public.payout_accounts a join public.payout_settings ps on ps.organization_id = a.organization_id where a.id = p_account),
    'monthly')
$$;
revoke all on function private.payout_frequency(uuid) from public, anon, authenticated;

-- The owner registers a payment of this contract's commission already made outside Corban (date and reference): a paid
-- statement holding the seller's open credits of the contract. It locks the contract like any paid statement.
create or replace function public.register_external_payout(p_proposal uuid, p_paid_on date, p_reference text)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  p public.proposals_v2%rowtype;
  v_account uuid;
  v_sum numeric;
  v_payout uuid;
begin
  select * into p from public.proposals_v2 where id = p_proposal for update;
  if p.id is null or auth.uid() is null or not public.has_active_organization_role(p.organization_id, array['admin']) then raise exception 'not_authorized'; end if;
  if p_paid_on is null or p_paid_on > current_date then raise exception 'invalid_paid_on'; end if;
  if length(btrim(coalesce(p_reference, ''))) < 3 then raise exception 'reference_required'; end if;
  -- The owner already paid: the seller's part is credited even if the bank's commission is not reconciled yet.
  perform private.sync_contract_credit(p.id, true);
  select e.account_id, sum(e.amount) into v_account, v_sum
  from public.payout_entries e
  where e.proposal_id = p.id and e.beneficiary_role = 'originator' and e.statement_id is null and e.status = 'approved' and e.source in ('contract', 'receipt')
  group by e.account_id order by sum(e.amount) desc limit 1;
  if v_account is null or v_sum <= 0 then raise exception 'nothing_to_pay'; end if;

  perform set_config('corban.payout_rpc', 'on', true);
  insert into public.payouts (organization_id, account_id, kind, period_start, period_end, carry_in, period_net, debt_deduction, amount, carry_out, status,
                              requested_by, requested_at, approved_by, approved_at, paid_by, paid_at, paid_on, payment_reference, note)
  values (p.organization_id, v_account, 'closing', p_paid_on, p_paid_on, 0, v_sum, 0, v_sum, 0, 'paid',
          auth.uid(), now(), auth.uid(), now(), auth.uid(), now(), p_paid_on, left(btrim(p_reference), 120), 'Pago fora do Corban')
  returning id into v_payout;
  update public.payout_entries set statement_id = v_payout
  where proposal_id = p.id and account_id = v_account and beneficiary_role = 'originator' and statement_id is null and status = 'approved' and source in ('contract', 'receipt');
  insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status, created_by, statement_id, payout_id)
  values (p.organization_id, v_account, 'payout', -v_sum, p_paid_on, 'Repasse pago fora do Corban', 'approved', auth.uid(), v_payout, v_payout);
  perform set_config('corban.payout_rpc', 'off', true);

  perform set_config('corban.contract_rpc', 'on', true);
  insert into public.contract_events (organization_id, proposal_id, kind, detail, reason, actor_user_id)
  values (p.organization_id, p.id, 'external_payout', jsonb_build_object('amount', v_sum, 'paid_on', p_paid_on), left(btrim(p_reference), 120), auth.uid());
  perform set_config('corban.contract_rpc', 'off', true);
  return v_payout;
end
$$;
revoke all on function public.register_external_payout(uuid, date, text) from public, anon;
grant execute on function public.register_external_payout(uuid, date, text) to authenticated;

-- Where the seller's payout of one contract stands: waiting (for the client payment, the physical file, the calculation,
-- the bank's commission or finance on a divergent receipt), credited, paid (date and reference).
create or replace function private.contract_credit_state(p_proposal uuid)
returns table (waiting text, credited numeric, paid_on date, reference text)
language sql
stable
security definer
set search_path to ''
as $$
  select case when p.status <> 'paid' then 'client'
              when p.formalization = 'physical' and p.physical_received_at is null then 'physical'
              when not exists (select 1 from public.proposal_commission_calcs c where c.proposal_id = p.id and c.status = 'active') then 'calculation'
              when private.contract_bank_receipt(p.id) is null then 'bank'
              when private.contract_bank_receipt(p.id) = 'divergent' then 'divergent'
         end,
         coalesce((select sum(e.amount) from public.payout_entries e where e.proposal_id = p.id and e.beneficiary_role = 'originator' and e.source in ('contract', 'receipt') and e.status = 'approved'), 0),
         (select max(y.paid_on) from public.payout_entries e join public.payouts y on y.id = coalesce(e.statement_id, e.payout_id)
          where e.proposal_id = p.id and e.beneficiary_role = 'originator' and y.status in ('paid', 'settled')),
         (select y.payment_reference from public.payout_entries e join public.payouts y on y.id = coalesce(e.statement_id, e.payout_id)
          where e.proposal_id = p.id and e.beneficiary_role = 'originator' and y.status in ('paid', 'settled') order by y.paid_on desc nulls last limit 1)
  from public.proposals_v2 p where p.id = p_proposal
$$;
revoke all on function private.contract_credit_state(uuid) from public, anon, authenticated;

create or replace function public.contract_credit(p_proposal uuid)
returns table (waiting text, credited numeric, paid_on date, reference text)
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
  return query select * from private.contract_credit_state(p.id);
end
$$;
revoke all on function public.contract_credit(uuid) from public, anon;
grant execute on function public.contract_credit(uuid) to authenticated;

-- The Contratos screen also shows where each seller payout stands.
drop function public.contract_payout_totals(uuid);
create or replace function public.contract_payout_totals(p_org uuid)
returns table (proposal_id uuid, received numeric, rule_amount numeric, payable numeric, overridden boolean, waiting text, credited numeric, paid_on date)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.view') then raise exception 'not_authorized'; end if;
  return query
    select c.proposal_id, sum(x.received), sum(x.rule_amount), sum(x.payable), bool_or(x.overridden), s.waiting, s.credited, s.paid_on
    from public.proposal_commission_calcs c
    cross join lateral private.contract_payable(c.proposal_id) x
    cross join lateral private.contract_credit_state(c.proposal_id) s
    where c.organization_id = p_org and c.status = 'active'
    group by c.proposal_id, s.waiting, s.credited, s.paid_on;
end
$$;
revoke all on function public.contract_payout_totals(uuid) from public, anon;
grant execute on function public.contract_payout_totals(uuid) to authenticated;
