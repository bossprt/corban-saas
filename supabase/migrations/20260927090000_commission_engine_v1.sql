-- F4 step 1: unified commission engine (approved by the owner, MAPA-OPERACAO §5-§7).
--
-- Revenue: the proposal's commercial condition components (upfront, deferred, bonus...), each a percentage of the
-- gross (BRUTO = contract amount) or net (LÍQUIDO = released amount) value, or a fixed amount.
-- Per component: tax (company regime rate; zero when the paying source — bank, or promoter on third-party routes — is
-- exempt), then the distribution in the mode the owner chose:
--   cascade      base = received − tax; profit % of base stays with the company; the rest is split among manager,
--                supervisor and originator by %; a missing role's part stays with the company.
--   group_table  originator gets the share of their commission group on that table (% of base, or the rule's
--                originator % when there is no group share); manager and supervisor optional, % of base; the company
--                keeps the remainder.
-- Every line is rounded to cents (half away from zero) and the company line is the remainder, so lines always add up
-- to the amount received. Deferred commission follows the client's installments (rounded, residual in the last one;
-- truncated when rounding up would overshoot) and is distributed per installment; the owner chooses whether it is paid
-- out to the team at all. All percentages are the owner's, versioned, resolved with precedence
-- global < bank < table < commission group < seller, and frozen on the proposal when calculated.
-- src/lib/commission/distribution.ts mirrors the arithmetic; tests pin the same numbers on both sides.

-- Tax exemption of the paying source -------------------------------------------------------------------------------

alter table public.organization_banks add column tax_exempt boolean not null default false;
alter table public.organization_providers add column tax_exempt boolean not null default false;

-- Owner rules ---------------------------------------------------------------------------------------------------------

create table public.commission_rule_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  scope_kind text not null check (scope_kind in ('global','bank','table','group','seller')),
  scope_id uuid,
  effective_from timestamptz not null default now(),
  mode text check (mode in ('cascade','group_table')),
  tax_rate_pct numeric(7,4) check (tax_rate_pct between 0 and 100),
  profit_pct numeric(7,4) check (profit_pct between 0 and 100),
  manager_pct numeric(7,4) check (manager_pct between 0 and 100),
  supervisor_pct numeric(7,4) check (supervisor_pct between 0 and 100),
  originator_pct numeric(7,4) check (originator_pct between 0 and 100),
  pay_deferred boolean,
  note text check (note is null or length(note) <= 300),
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint commission_rule_scope check ((scope_kind = 'global') = (scope_id is null)),
  constraint commission_rule_tax_global_only check (tax_rate_pct is null or scope_kind = 'global'),
  constraint commission_rule_cascade_split check (coalesce(manager_pct, 0) + coalesce(supervisor_pct, 0) + coalesce(originator_pct, 0) <= 100 or mode = 'group_table')
);

create index commission_rule_versions_lookup_idx on public.commission_rule_versions (organization_id, scope_kind, scope_id, effective_from desc);

alter table public.commission_rule_versions enable row level security;
revoke all on table public.commission_rule_versions from anon, authenticated;
grant select on public.commission_rule_versions to authenticated;
create policy commission_rule_versions_select on public.commission_rule_versions for select to authenticated
  using (public.has_permission(organization_id, 'comercial.view') or public.has_permission(organization_id, 'financeiro.view'));

-- Versions are append-only: a change is a new version.
create or replace function public.guard_commission_rule_versions()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  raise exception 'commission_rules_are_append_only';
end
$$;

revoke all on function public.guard_commission_rule_versions() from public, anon, authenticated;
create trigger commission_rule_versions_00_append_only before update or delete on public.commission_rule_versions
  for each row execute function public.guard_commission_rule_versions();

create or replace function public.save_commission_rule(
  p_org uuid, p_scope_kind text, p_scope_id uuid, p_mode text, p_tax_rate_pct numeric, p_profit_pct numeric,
  p_manager_pct numeric, p_supervisor_pct numeric, p_originator_pct numeric, p_pay_deferred boolean, p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare v_id uuid;
begin
  if auth.uid() is null or private.caller_role_in(p_org) not in ('admin','manager') or not public.has_permission(p_org, 'comercial.edit') then raise exception 'not_authorized'; end if;
  if p_scope_kind = 'bank' and not exists (select 1 from public.organization_banks where organization_id = p_org and id = p_scope_id) then raise exception 'scope_not_found'; end if;
  if p_scope_kind = 'table' and not exists (select 1 from public.product_tables where organization_id = p_org and id = p_scope_id) then raise exception 'scope_not_found'; end if;
  if p_scope_kind = 'group' and not exists (select 1 from public.commission_groups where organization_id = p_org and id = p_scope_id) then raise exception 'scope_not_found'; end if;
  if p_scope_kind = 'seller' and not exists (select 1 from public.commercial_sellers where organization_id = p_org and id = p_scope_id) then raise exception 'scope_not_found'; end if;
  insert into public.commission_rule_versions (organization_id, scope_kind, scope_id, mode, tax_rate_pct, profit_pct, manager_pct, supervisor_pct, originator_pct, pay_deferred, note, created_by)
  values (p_org, p_scope_kind, case when p_scope_kind = 'global' then null else p_scope_id end, p_mode, p_tax_rate_pct, p_profit_pct, p_manager_pct, p_supervisor_pct, p_originator_pct, p_pay_deferred, nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning id into v_id;
  return v_id;
end
$$;

revoke all on function public.save_commission_rule(uuid, text, uuid, text, numeric, numeric, numeric, numeric, numeric, boolean, text) from public, anon;
grant execute on function public.save_commission_rule(uuid, text, uuid, text, numeric, numeric, numeric, numeric, numeric, boolean, text) to authenticated;

-- Field by field, the most specific scope that sets a value wins (latest version per scope at p_at).
create or replace function private.resolve_commission_rule(p_org uuid, p_bank uuid, p_table uuid, p_group uuid, p_seller uuid, p_at timestamptz)
returns table (mode text, tax_rate_pct numeric, profit_pct numeric, manager_pct numeric, supervisor_pct numeric, originator_pct numeric, pay_deferred boolean, rule_ids uuid[])
language sql
stable
security definer
set search_path to ''
as $$
  with latest as (
    select distinct on (v.scope_kind, v.scope_id) v.*,
           case v.scope_kind when 'global' then 1 when 'bank' then 2 when 'table' then 3 when 'group' then 4 when 'seller' then 5 end as rank
    from public.commission_rule_versions v
    where v.organization_id = p_org and v.effective_from <= p_at
      and ((v.scope_kind = 'global') or (v.scope_kind = 'bank' and v.scope_id = p_bank) or (v.scope_kind = 'table' and v.scope_id = p_table)
           or (v.scope_kind = 'group' and v.scope_id = p_group) or (v.scope_kind = 'seller' and v.scope_id = p_seller))
    order by v.scope_kind, v.scope_id, v.effective_from desc, v.created_at desc
  )
  select
    (select l.mode from latest l where l.mode is not null order by l.rank desc limit 1),
    (select l.tax_rate_pct from latest l where l.tax_rate_pct is not null order by l.rank desc limit 1),
    (select l.profit_pct from latest l where l.profit_pct is not null order by l.rank desc limit 1),
    (select l.manager_pct from latest l where l.manager_pct is not null order by l.rank desc limit 1),
    (select l.supervisor_pct from latest l where l.supervisor_pct is not null order by l.rank desc limit 1),
    (select l.originator_pct from latest l where l.originator_pct is not null order by l.rank desc limit 1),
    (select l.pay_deferred from latest l where l.pay_deferred is not null order by l.rank desc limit 1),
    (select coalesce(array_agg(l.id order by l.rank), '{}') from latest l)
$$;

revoke all on function private.resolve_commission_rule(uuid, uuid, uuid, uuid, uuid, timestamptz) from public, anon, authenticated;

-- Arithmetic (mirrors src/lib/commission/distribution.ts) --------------------------------------------------------------

create or replace function private.distribute_commission_amount(
  p_received numeric, p_mode text, p_tax_rate numeric, p_exempt boolean, p_profit numeric,
  p_manager numeric, p_supervisor numeric, p_originator numeric, p_group_share numeric,
  p_has_manager boolean, p_has_supervisor boolean, p_has_originator boolean
)
returns table (received numeric, tax numeric, manager numeric, supervisor numeric, originator numeric, company numeric)
language plpgsql
immutable
set search_path to ''
as $$
declare
  v_received numeric := round(p_received, 2);
  v_tax numeric; v_base numeric; v_dist numeric;
  v_m numeric := 0; v_s numeric := 0; v_o numeric := 0; v_c numeric;
begin
  if v_received < 0 then raise exception 'negative_received'; end if;
  v_tax := case when p_exempt then 0 else round(v_received * coalesce(p_tax_rate, 0) / 100, 2) end;
  v_base := v_received - v_tax;
  if p_mode = 'cascade' then
    v_dist := v_base - round(v_base * coalesce(p_profit, 0) / 100, 2);
    if p_has_manager then v_m := round(v_dist * coalesce(p_manager, 0) / 100, 2); end if;
    if p_has_supervisor then v_s := round(v_dist * coalesce(p_supervisor, 0) / 100, 2); end if;
    if p_has_originator then v_o := round(v_dist * coalesce(p_originator, 0) / 100, 2); end if;
  elsif p_mode = 'group_table' then
    if p_has_manager then v_m := round(v_base * coalesce(p_manager, 0) / 100, 2); end if;
    if p_has_supervisor then v_s := round(v_base * coalesce(p_supervisor, 0) / 100, 2); end if;
    if p_has_originator then v_o := round(v_base * coalesce(p_group_share, p_originator, 0) / 100, 2); end if;
  else
    raise exception 'commission_mode_not_configured';
  end if;
  v_c := v_base - v_m - v_s - v_o;
  if v_c < 0 then raise exception 'payout_exceeds_received'; end if;
  return query select v_received, v_tax, v_m, v_s, v_o, v_c;
end
$$;

create or replace function private.deferred_schedule(p_total numeric, p_installments int)
returns table (standard numeric, last numeric)
language plpgsql
immutable
set search_path to ''
as $$
declare v_std numeric;
begin
  if p_installments is null or p_installments < 1 then raise exception 'invalid_installments'; end if;
  v_std := round(round(p_total, 2) / p_installments, 2);
  if v_std * (p_installments - 1) > round(p_total, 2) then v_std := trunc(round(p_total, 2) / p_installments, 2); end if;
  return query select v_std, round(p_total, 2) - v_std * (p_installments - 1);
end
$$;

revoke all on function private.distribute_commission_amount(numeric, text, numeric, boolean, numeric, numeric, numeric, numeric, numeric, boolean, boolean, boolean) from public, anon;
revoke all on function private.deferred_schedule(numeric, int) from public, anon;
grant execute on function private.distribute_commission_amount(numeric, text, numeric, boolean, numeric, numeric, numeric, numeric, numeric, boolean, boolean, boolean) to authenticated;
grant execute on function private.deferred_schedule(numeric, int) to authenticated;

-- Frozen calculations -----------------------------------------------------------------------------------------------------

create table public.proposal_commission_calcs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  proposal_id uuid not null,
  condition_id uuid not null,
  status text not null default 'active' check (status in ('active','superseded')),
  mode text not null check (mode in ('cascade','group_table')),
  tax_rate_pct numeric(7,4) not null,
  tax_exempt boolean not null,
  profit_pct numeric(7,4),
  manager_pct numeric(7,4),
  supervisor_pct numeric(7,4),
  originator_pct numeric(7,4),
  group_share_pct numeric(9,6),
  pay_deferred boolean not null,
  gross_amount numeric(15,2),
  net_amount numeric(15,2),
  installments int,
  originator_user_id uuid,
  supervisor_user_id uuid,
  manager_user_id uuid,
  seller_id uuid,
  rule_ids uuid[] not null default '{}',
  calculated_by uuid,
  calculated_at timestamptz not null default now(),
  foreign key (organization_id, proposal_id) references public.proposals_v2 (organization_id, id) on delete restrict,
  foreign key (organization_id, condition_id) references public.commercial_conditions (organization_id, id) on delete restrict
);

create unique index proposal_commission_calcs_one_active_idx on public.proposal_commission_calcs (proposal_id) where status = 'active';
create unique index proposal_commission_calcs_org_id_key on public.proposal_commission_calcs (organization_id, id);

-- One row per component part and line. part: 'upfront' (paid once) or 'deferred_standard' / 'deferred_last'
-- (per installment; multiplier = how many installments carry that amount).
create table public.proposal_commission_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  calc_id uuid not null,
  component_key text not null,
  part text not null check (part in ('upfront','deferred_standard','deferred_last')),
  multiplier int not null default 1 check (multiplier >= 0),
  line_kind text not null check (line_kind in ('received','tax','manager','supervisor','originator','company')),
  amount numeric(15,2) not null check (amount >= 0),
  foreign key (organization_id, calc_id) references public.proposal_commission_calcs (organization_id, id) on delete restrict
);

create index proposal_commission_lines_calc_idx on public.proposal_commission_lines (calc_id);

create or replace function public.guard_commission_calc_write()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if current_setting('corban.commission_rpc', true) is distinct from 'on' then raise exception 'commission_write_requires_governed_rpc'; end if;
  if tg_op = 'DELETE' then raise exception 'commission_records_are_not_deletable'; end if;
  -- The only change a calculation accepts: active -> superseded, nothing else.
  if tg_op = 'UPDATE' and (old.status <> 'active' or new.status <> 'superseded'
     or (to_jsonb(new) - 'status') is distinct from (to_jsonb(old) - 'status')) then
    raise exception 'commission_calc_is_immutable';
  end if;
  return new;
end
$$;

create or replace function public.guard_commission_line_write()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if current_setting('corban.commission_rpc', true) is distinct from 'on' or tg_op <> 'INSERT' then raise exception 'commission_lines_are_immutable'; end if;
  return new;
end
$$;

revoke all on function public.guard_commission_calc_write() from public, anon, authenticated;
revoke all on function public.guard_commission_line_write() from public, anon, authenticated;
create trigger proposal_commission_calcs_00_guard before insert or update or delete on public.proposal_commission_calcs
  for each row execute function public.guard_commission_calc_write();
create trigger proposal_commission_lines_00_guard before insert or update or delete on public.proposal_commission_lines
  for each row execute function public.guard_commission_line_write();

alter table public.proposal_commission_calcs enable row level security;
alter table public.proposal_commission_lines enable row level security;
revoke all on table public.proposal_commission_calcs, public.proposal_commission_lines from anon, authenticated;
grant select on public.proposal_commission_calcs, public.proposal_commission_lines to authenticated;

-- Company-level lines (received, tax, company, manager, supervisor) are for finance; a seller sees their own
-- originator line through the calc of a proposal in their scope.
create policy proposal_commission_calcs_select on public.proposal_commission_calcs for select to authenticated
  using (public.is_active_organization_member(organization_id)
         and exists (select 1 from public.proposals_v2 p where p.id = proposal_id)
         and (public.has_permission(organization_id, 'financeiro.view') or originator_user_id = (select auth.uid())));
create policy proposal_commission_lines_select on public.proposal_commission_lines for select to authenticated
  using (exists (select 1 from public.proposal_commission_calcs c where c.id = calc_id)
         and (public.has_permission(organization_id, 'financeiro.view') or line_kind = 'originator'));

-- Calculate and freeze ----------------------------------------------------------------------------------------------------

create or replace function public.calculate_proposal_commission(p_proposal_id uuid, p_condition_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  p public.proposals_v2%rowtype;
  v_org uuid;
  v_cond uuid;
  v_count int;
  v_table uuid; v_route uuid; v_bank uuid; v_provider uuid; v_origin text;
  v_exempt boolean;
  v_seller_group uuid;
  r record;
  v_share numeric;
  v_orig uuid; v_sup uuid; v_mgr uuid;
  v_calc uuid;
  c record;
  v_amount numeric;
  v_sched record;
  d record;
begin
  select * into p from public.proposals_v2 where id = p_proposal_id for update;
  v_org := p.organization_id;
  if v_org is null or auth.uid() is null or not public.is_active_organization_member(v_org) then raise exception 'not_authorized'; end if;
  if not private.can_see_proposal_row(v_org, p.seller_id, p.created_by) then raise exception 'not_authorized'; end if;
  if not (public.has_permission(v_org, 'propostas.edit') or public.has_permission(v_org, 'financeiro.edit')) then raise exception 'not_authorized'; end if;
  if p.status in ('paid','rejected','cancelled') and exists (select 1 from public.proposal_commission_calcs x where x.proposal_id = p.id and x.status = 'active') then
    raise exception 'commission_frozen';
  end if;

  -- Condition: explicit, or the only one of the table version matching the term and amount.
  if p_condition_id is not null then
    select k.id into v_cond from public.commercial_conditions k where k.organization_id = v_org and k.id = p_condition_id and k.product_table_version_id = p.product_table_version_id;
    if v_cond is null then raise exception 'condition_not_found'; end if;
  else
    select count(*), min(k.id::text)::uuid into v_count, v_cond from public.commercial_conditions k
    where k.organization_id = v_org and k.product_table_version_id = p.product_table_version_id
      and (p.term is null or (p.term between coalesce(k.term_min, k.term) and coalesce(k.term_max, k.term)))
      and (k.amount_min is null or coalesce(p.requested_amount, p.released_amount) >= k.amount_min)
      and (k.amount_max is null or coalesce(p.requested_amount, p.released_amount) <= k.amount_max);
    if v_count = 0 then raise exception 'condition_not_found'; end if;
    if v_count > 1 then raise exception 'condition_ambiguous'; end if;
  end if;

  select v.product_table_id, t.route_id, r2.org_bank_id, r2.org_provider_id, r2.production_origin
    into v_table, v_route, v_bank, v_provider, v_origin
  from public.product_table_versions v
  join public.product_tables t on t.id = v.product_table_id
  join public.organization_product_routes r2 on r2.id = t.route_id
  where v.id = p.product_table_version_id;

  v_exempt := case when v_origin = 'third_party'
                   then coalesce((select op.tax_exempt from public.organization_providers op where op.id = v_provider), false)
                   else coalesce((select ob.tax_exempt from public.organization_banks ob where ob.id = v_bank), false) end;

  select s.commission_group_id into v_seller_group from public.commercial_sellers s where s.organization_id = v_org and s.id = p.seller_id;
  select * into r from private.resolve_commission_rule(v_org, v_bank, v_table, v_seller_group, p.seller_id, now());
  if r.mode is null then raise exception 'commission_mode_not_configured'; end if;
  select sh.share_pct into v_share from public.commercial_condition_shares sh where sh.condition_id = v_cond and sh.group_id = v_seller_group;

  -- Beneficiaries: originator = seller's user, else creator; supervisor = originator's team leader; manager = supervisor's team leader.
  v_orig := private.proposal_owner(v_org, p.seller_id, p.created_by);
  select m.team_leader_user_id into v_sup from public.organization_memberships m where m.organization_id = v_org and m.user_id = v_orig and m.status = 'active';
  select m.team_leader_user_id into v_mgr from public.organization_memberships m where m.organization_id = v_org and m.user_id = v_sup and m.status = 'active';

  perform set_config('corban.commission_rpc', 'on', true);
  update public.proposal_commission_calcs set status = 'superseded' where proposal_id = p.id and status = 'active';
  insert into public.proposal_commission_calcs (organization_id, proposal_id, condition_id, mode, tax_rate_pct, tax_exempt, profit_pct, manager_pct, supervisor_pct, originator_pct,
    group_share_pct, pay_deferred, gross_amount, net_amount, installments, originator_user_id, supervisor_user_id, manager_user_id, seller_id, rule_ids, calculated_by)
  values (v_org, p.id, v_cond, r.mode, coalesce(r.tax_rate_pct, 0), v_exempt, r.profit_pct, r.manager_pct, r.supervisor_pct, r.originator_pct,
    v_share, coalesce(r.pay_deferred, false), coalesce(p.requested_amount, p.released_amount), coalesce(p.released_amount, p.requested_amount), p.term,
    v_orig, v_sup, v_mgr, p.seller_id, r.rule_ids, auth.uid())
  returning id into v_calc;

  for c in
    select t.tech_key, k.value_kind, k.received_value, k.calculation_base
    from public.commercial_condition_components k join public.commission_component_types t on t.id = k.component_type_id
    where k.condition_id = v_cond order by t.sort_order
  loop
    v_amount := case when c.value_kind = 'fixed_brl' then c.received_value
                     else coalesce(case when upper(coalesce(c.calculation_base, '')) like 'L%' then coalesce(p.released_amount, p.requested_amount) else coalesce(p.requested_amount, p.released_amount) end, 0) * c.received_value / 100 end;
    if c.tech_key = 'deferred' and coalesce(p.term, 0) > 0 then
      select * into v_sched from private.deferred_schedule(v_amount, p.term);
      for d in select 'deferred_standard' as part, v_sched.standard as amt, p.term - 1 as mult union all select 'deferred_last', v_sched.last, 1 loop
        insert into public.proposal_commission_lines (organization_id, calc_id, component_key, part, multiplier, line_kind, amount)
        select v_org, v_calc, c.tech_key, d.part, d.mult, x.kind, x.amt
        from private.distribute_commission_amount(d.amt, r.mode, coalesce(r.tax_rate_pct, 0), v_exempt, r.profit_pct, r.manager_pct, r.supervisor_pct, r.originator_pct, v_share,
               v_mgr is not null and coalesce(r.pay_deferred, false), v_sup is not null and coalesce(r.pay_deferred, false), v_orig is not null and coalesce(r.pay_deferred, false)) s
        cross join lateral (values ('received', s.received), ('tax', s.tax), ('manager', s.manager), ('supervisor', s.supervisor), ('originator', s.originator), ('company', s.company)) x(kind, amt);
      end loop;
    else
      insert into public.proposal_commission_lines (organization_id, calc_id, component_key, part, multiplier, line_kind, amount)
      select v_org, v_calc, c.tech_key, 'upfront', 1, x.kind, x.amt
      from private.distribute_commission_amount(v_amount, r.mode, coalesce(r.tax_rate_pct, 0), v_exempt, r.profit_pct, r.manager_pct, r.supervisor_pct, r.originator_pct, v_share,
             v_mgr is not null, v_sup is not null, v_orig is not null) s
      cross join lateral (values ('received', s.received), ('tax', s.tax), ('manager', s.manager), ('supervisor', s.supervisor), ('originator', s.originator), ('company', s.company)) x(kind, amt);
    end if;
  end loop;
  perform set_config('corban.commission_rpc', 'off', true);
  return v_calc;
end
$$;

revoke all on function public.calculate_proposal_commission(uuid, uuid) from public, anon;
grant execute on function public.calculate_proposal_commission(uuid, uuid) to authenticated;
