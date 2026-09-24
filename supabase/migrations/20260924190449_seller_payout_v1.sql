-- F6: seller payout and current account (MAPA-OPERACAO §8, owner-approved design).
--
-- One account per person: a registered seller/broker (with or without login), or a team member who is not a seller
-- (supervisor, manager). Every movement is an immutable entry; corrections are new entries.
--   commission  credit posted when a receipt is reconciled (matched on confirmation, divergent only once accepted),
--               split with the percentages frozen on the proposal over the amount actually received;
--               deferred installments credit the team only when the frozen rule pays the deferred to the team.
--   chargeback  debit posted with a bank chargeback: each person loses the same fraction of what they received from
--               that contract, rounded to the cent, never more than they received.
--   advance, bonus, discount, adjustment  entered by finance, pending until someone else approves (two eyes).
--   payout      debit written when a statement or a withdrawal is marked paid.
-- Payment model per company with a per-person override:
--   closing  finance closes a period; each person gets a statement. A negative balance carries over and each statement
--            deducts at most debt_limit_pct of the period's net credits (owner: 30%).
--   account  the balance is available; the person or finance requests a withdrawal up to it.
-- Statements and withdrawals are approved by someone other than who created them, then marked paid by hand.

-- Settings -------------------------------------------------------------------------------------------------------------

create table public.payout_settings (
  organization_id uuid primary key references public.organizations(id) on delete restrict,
  default_model text not null default 'closing' check (default_model in ('closing','account')),
  closing_frequency text not null default 'monthly' check (closing_frequency in ('weekly','biweekly','monthly')),
  debt_limit_pct numeric(5,2) not null default 30 check (debt_limit_pct between 0 and 100),
  updated_by uuid,
  updated_at timestamptz not null default now()
);

-- Accounts ---------------------------------------------------------------------------------------------------------------

create table public.payout_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  seller_id uuid,
  user_id uuid,
  model text check (model in ('closing','account')),
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  constraint payout_account_holder check ((seller_id is null) <> (user_id is null)),
  foreign key (organization_id, seller_id) references public.commercial_sellers (organization_id, id) on delete restrict
);

create unique index payout_accounts_seller_idx on public.payout_accounts (organization_id, seller_id) where seller_id is not null;
create unique index payout_accounts_user_idx on public.payout_accounts (organization_id, user_id) where user_id is not null;

-- Payouts (statements of a closing, or withdrawals) ------------------------------------------------------------------------

create table public.payouts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  account_id uuid not null,
  kind text not null check (kind in ('closing','withdrawal')),
  period_start date,
  period_end date,
  carry_in numeric(15,2),
  period_net numeric(15,2),
  debt_deduction numeric(15,2),
  amount numeric(15,2) not null check (amount >= 0),
  carry_out numeric(15,2),
  status text not null check (status in ('pending','approved','paid','settled','cancelled')),
  requested_by uuid,
  requested_at timestamptz not null default now(),
  approved_by uuid,
  approved_at timestamptz,
  paid_by uuid,
  paid_at timestamptz,
  paid_on date,
  payment_reference text check (length(payment_reference) <= 120),
  cancelled_by uuid,
  cancelled_at timestamptz,
  note text check (length(note) <= 300),
  unique (organization_id, id),
  constraint payout_closing_shape check ((kind = 'closing') = (period_end is not null and carry_in is not null and period_net is not null and carry_out is not null)),
  foreign key (organization_id, account_id) references public.payout_accounts (organization_id, id) on delete restrict
);

create index payouts_account_idx on public.payouts (account_id, requested_at desc);

-- Entries ------------------------------------------------------------------------------------------------------------------

create table public.payout_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  account_id uuid not null,
  kind text not null check (kind in ('commission','chargeback','advance','bonus','discount','adjustment','payout')),
  amount numeric(15,2) not null check (amount <> 0),
  effective_on date not null,
  proposal_id uuid,
  receipt_id uuid,
  beneficiary_role text check (beneficiary_role in ('originator','supervisor','manager')),
  entry_group uuid,
  description text check (length(description) <= 200),
  status text not null check (status in ('approved','pending','rejected')),
  created_by uuid,
  created_at timestamptz not null default now(),
  decided_by uuid,
  decided_at timestamptz,
  decision_note text check (length(decision_note) <= 300),
  statement_id uuid,
  payout_id uuid,
  constraint payout_entry_sign check (
    (kind in ('commission','bonus') and amount > 0)
    or (kind in ('chargeback','advance','discount','payout') and amount < 0)
    or kind = 'adjustment'),
  constraint payout_entry_source check ((kind in ('commission','chargeback')) = (receipt_id is not null and beneficiary_role is not null)),
  foreign key (organization_id, account_id) references public.payout_accounts (organization_id, id) on delete restrict,
  foreign key (organization_id, proposal_id) references public.proposals_v2 (organization_id, id) on delete restrict,
  foreign key (receipt_id) references public.commission_receipts (id) on delete restrict,
  foreign key (organization_id, statement_id) references public.payouts (organization_id, id) on delete restrict,
  foreign key (organization_id, payout_id) references public.payouts (organization_id, id) on delete restrict
);

-- A receipt credits (or debits) each person and role once.
create unique index payout_entries_receipt_once_idx on public.payout_entries (receipt_id, account_id, beneficiary_role) where receipt_id is not null;
create index payout_entries_account_idx on public.payout_entries (account_id, effective_on);
create index payout_entries_proposal_idx on public.payout_entries (proposal_id) where proposal_id is not null;
create index payout_entries_pending_idx on public.payout_entries (organization_id) where status = 'pending';

-- Guards --------------------------------------------------------------------------------------------------------------------

create or replace function public.guard_payout_write()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if current_setting('corban.payout_rpc', true) is distinct from 'on' then raise exception 'payout_write_requires_governed_rpc'; end if;
  if tg_op = 'DELETE' then raise exception 'payout_records_are_not_deletable'; end if;
  if tg_op = 'UPDATE' then
    if tg_table_name = 'payout_entries' then
      -- Only the approval decision (once) and the statement link may change.
      if (to_jsonb(new) - array['status','decided_by','decided_at','decision_note','statement_id'])
         is distinct from (to_jsonb(old) - array['status','decided_by','decided_at','decision_note','statement_id']) then
        raise exception 'payout_entry_is_immutable';
      end if;
      if new.status is distinct from old.status and not (old.status = 'pending' and new.status in ('approved','rejected')) then
        raise exception 'payout_entry_decision_is_final';
      end if;
    elsif tg_table_name = 'payouts' then
      if old.status in ('paid','settled','cancelled') then raise exception 'payout_is_closed'; end if;
      if (to_jsonb(new) - array['status','approved_by','approved_at','paid_by','paid_at','paid_on','payment_reference','cancelled_by','cancelled_at','note'])
         is distinct from (to_jsonb(old) - array['status','approved_by','approved_at','paid_by','paid_at','paid_on','payment_reference','cancelled_by','cancelled_at','note']) then
        raise exception 'payout_is_immutable';
      end if;
    elsif tg_table_name = 'payout_accounts' then
      if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id or new.seller_id is distinct from old.seller_id or new.user_id is distinct from old.user_id then
        raise exception 'payout_account_holder_is_immutable';
      end if;
    end if;
  end if;
  return new;
end
$$;

revoke all on function public.guard_payout_write() from public, anon, authenticated;
create trigger payout_settings_00_guard before insert or update or delete on public.payout_settings for each row execute function public.guard_payout_write();
create trigger payout_accounts_00_guard before insert or update or delete on public.payout_accounts for each row execute function public.guard_payout_write();
create trigger payouts_00_guard before insert or update or delete on public.payouts for each row execute function public.guard_payout_write();
create trigger payout_entries_00_guard before insert or update or delete on public.payout_entries for each row execute function public.guard_payout_write();

-- Visibility: finance (repasse.view) sees every account; each person sees their own ------------------------------------------

create or replace function private.is_payout_holder(p_account uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
    select 1 from public.payout_accounts a
    left join public.commercial_sellers s on s.id = a.seller_id
    where a.id = p_account and (a.user_id = auth.uid() or s.user_id = auth.uid())
      and public.is_active_organization_member(a.organization_id))
$$;

revoke all on function private.is_payout_holder(uuid) from public, anon;
grant execute on function private.is_payout_holder(uuid) to authenticated;

alter table public.payout_settings enable row level security;
alter table public.payout_accounts enable row level security;
alter table public.payouts enable row level security;
alter table public.payout_entries enable row level security;
revoke all on table public.payout_settings, public.payout_accounts, public.payouts, public.payout_entries from anon, authenticated;
grant select on public.payout_settings, public.payout_accounts, public.payouts, public.payout_entries to authenticated;

create policy payout_settings_select on public.payout_settings for select to authenticated using (public.is_active_organization_member(organization_id));
create policy payout_accounts_select on public.payout_accounts for select to authenticated
  using (public.has_permission(organization_id, 'repasse.view') or private.is_payout_holder(id));
create policy payouts_select on public.payouts for select to authenticated
  using (public.has_permission(organization_id, 'repasse.view') or private.is_payout_holder(account_id));
create policy payout_entries_select on public.payout_entries for select to authenticated
  using (public.has_permission(organization_id, 'repasse.view') or private.is_payout_holder(account_id));

-- Helpers --------------------------------------------------------------------------------------------------------------------

-- The account of a person: the seller account when there is a seller (or the member is a registered seller), else the
-- member account. Created on first use.
create or replace function private.payout_account_for(p_org uuid, p_seller uuid, p_user uuid)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare v_seller uuid := p_seller; v_id uuid; v_prev text := current_setting('corban.payout_rpc', true);
begin
  if v_seller is null and p_user is not null then
    select s.id into v_seller from public.commercial_sellers s where s.organization_id = p_org and s.user_id = p_user;
  end if;
  if v_seller is null and p_user is null then return null; end if;
  if v_seller is not null then
    select id into v_id from public.payout_accounts where organization_id = p_org and seller_id = v_seller;
  else
    select id into v_id from public.payout_accounts where organization_id = p_org and user_id = p_user;
  end if;
  if v_id is null then
    perform set_config('corban.payout_rpc', 'on', true);
    insert into public.payout_accounts (organization_id, seller_id, user_id)
    values (p_org, v_seller, case when v_seller is null then p_user end)
    on conflict do nothing
    returning id into v_id;
    if v_id is null then
      select id into v_id from public.payout_accounts where organization_id = p_org and (seller_id = v_seller or (v_seller is null and user_id = p_user));
    end if;
    -- Restore the caller's flag: this runs inside other governed writes.
    perform set_config('corban.payout_rpc', coalesce(v_prev, 'off'), true);
  end if;
  return v_id;
end
$$;

revoke all on function private.payout_account_for(uuid, uuid, uuid) from public, anon, authenticated;

create or replace function private.payout_model(p_account uuid)
returns text
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(a.model, s.default_model, 'closing')
  from public.payout_accounts a left join public.payout_settings s on s.organization_id = a.organization_id
  where a.id = p_account
$$;

revoke all on function private.payout_model(uuid) from public, anon;
grant execute on function private.payout_model(uuid) to authenticated;

-- Posts the entries of one reconciled receipt (idempotent: a receipt posts once).
create or replace function private.post_receipt(p_receipt uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  x public.commission_receipts%rowtype;
  c public.proposal_commission_calcs%rowtype;
  d record;
  v_base numeric;
  v_ratio numeric;
  r record;
  v_debit numeric;
begin
  select * into x from public.commission_receipts where id = p_receipt;
  if x.id is null or exists (select 1 from public.payout_entries where receipt_id = x.id) then return; end if;
  perform set_config('corban.payout_rpc', 'on', true);

  if x.entry_kind = 'receipt' then
    select * into c from public.proposal_commission_calcs where id = x.calc_id;
    if c.id is null or (x.component_key = 'deferred' and not c.pay_deferred) then return; end if;
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
      where e.proposal_id = x.proposal_id and e.kind in ('commission','chargeback') and e.status = 'approved'
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
$$;

revoke all on function private.post_receipt(uuid) from public, anon, authenticated;

-- Matched receipts post on confirmation; divergent ones post once accepted.
create or replace function public.post_receipt_after_insert()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if tg_table_name = 'commission_receipts' then
    if new.reconciliation = 'matched' then perform private.post_receipt(new.id); end if;
  else
    perform private.post_receipt(new.receipt_id);
  end if;
  perform set_config('corban.payout_rpc', 'off', true);
  return null;
end
$$;

revoke all on function public.post_receipt_after_insert() from public, anon, authenticated;
create trigger commission_receipts_10_post_payout after insert on public.commission_receipts for each row execute function public.post_receipt_after_insert();
create trigger commission_receipt_resolutions_10_post_payout after insert on public.commission_receipt_resolutions for each row execute function public.post_receipt_after_insert();

-- F4 correction: the originator of a proposal with a seller is that seller, with or without login (never the person who
-- typed it); the hierarchy follows the seller's login only.
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
  -- A seller without login is still the originator (paid on the seller account), but has no team hierarchy: the
  -- supervisor and manager shares stay with the company instead of following whoever typed the proposal.
  v_orig := case when p.seller_id is not null then (select s.user_id from public.commercial_sellers s where s.organization_id = v_org and s.id = p.seller_id) else p.created_by end;
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
               v_mgr is not null and coalesce(r.pay_deferred, false), v_sup is not null and coalesce(r.pay_deferred, false), (p.seller_id is not null or v_orig is not null) and coalesce(r.pay_deferred, false)) s
        cross join lateral (values ('received', s.received), ('tax', s.tax), ('manager', s.manager), ('supervisor', s.supervisor), ('originator', s.originator), ('company', s.company)) x(kind, amt);
      end loop;
    else
      insert into public.proposal_commission_lines (organization_id, calc_id, component_key, part, multiplier, line_kind, amount)
      select v_org, v_calc, c.tech_key, 'upfront', 1, x.kind, x.amt
      from private.distribute_commission_amount(v_amount, r.mode, coalesce(r.tax_rate_pct, 0), v_exempt, r.profit_pct, r.manager_pct, r.supervisor_pct, r.originator_pct, v_share,
             v_mgr is not null, v_sup is not null, p.seller_id is not null or v_orig is not null) s
      cross join lateral (values ('received', s.received), ('tax', s.tax), ('manager', s.manager), ('supervisor', s.supervisor), ('originator', s.originator), ('company', s.company)) x(kind, amt);
    end if;
  end loop;
  perform set_config('corban.commission_rpc', 'off', true);
  return v_calc;
end
$$;

-- RPCs ---------------------------------------------------------------------------------------------------------------------------

create or replace function public.save_payout_settings(p_org uuid, p_default_model text, p_closing_frequency text, p_debt_limit_pct numeric)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare v_old text;
begin
  if auth.uid() is null or private.caller_role_in(p_org) not in ('admin','manager') or not public.has_permission(p_org, 'repasse.edit') then raise exception 'not_authorized'; end if;
  select default_model into v_old from public.payout_settings where organization_id = p_org;
  perform set_config('corban.payout_rpc', 'on', true);
  -- Changing the company default never moves accounts that already have history: they keep the model they had.
  if coalesce(v_old, 'closing') is distinct from p_default_model then
    update public.payout_accounts a set model = coalesce(v_old, 'closing')
    where a.organization_id = p_org and a.model is null and exists (select 1 from public.payout_entries e where e.account_id = a.id);
  end if;
  insert into public.payout_settings (organization_id, default_model, closing_frequency, debt_limit_pct, updated_by)
  values (p_org, p_default_model, p_closing_frequency, p_debt_limit_pct, auth.uid())
  on conflict (organization_id) do update
  set default_model = excluded.default_model, closing_frequency = excluded.closing_frequency, debt_limit_pct = excluded.debt_limit_pct,
      updated_by = auth.uid(), updated_at = now();
  perform set_config('corban.payout_rpc', 'off', true);
end
$$;

-- Opens (or returns) the account of a seller or member, so finance can post to someone who has not earned yet.
create or replace function public.ensure_payout_account(p_org uuid, p_seller uuid, p_user uuid)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or not (public.has_permission(p_org, 'repasse.create') or public.has_permission(p_org, 'repasse.edit')) then raise exception 'not_authorized'; end if;
  if p_seller is not null and not exists (select 1 from public.commercial_sellers where organization_id = p_org and id = p_seller) then raise exception 'payee_not_found'; end if;
  if p_seller is null and not exists (select 1 from public.organization_memberships where organization_id = p_org and user_id = p_user) then raise exception 'payee_not_found'; end if;
  return private.payout_account_for(p_org, p_seller, p_user);
end
$$;

create or replace function public.set_payout_account_model(p_account uuid, p_model text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare a public.payout_accounts%rowtype; v_from text; v_balance numeric; v_open uuid;
begin
  select * into a from public.payout_accounts where id = p_account for update;
  if a.id is null or auth.uid() is null or not public.has_permission(a.organization_id, 'repasse.edit') then raise exception 'not_authorized'; end if;
  if p_model is not null and p_model not in ('closing','account') then raise exception 'invalid_model'; end if;
  if exists (select 1 from public.payouts where account_id = p_account and status in ('pending','approved')) then raise exception 'payout_open'; end if;
  v_from := private.payout_model(p_account);
  perform set_config('corban.payout_rpc', 'on', true);
  update public.payout_accounts set model = p_model where id = p_account;
  -- From the account model to closings: what already happened is settled into an opening statement whose carry is the
  -- current balance, so the first closing neither pays twice nor forgets a debt.
  if v_from = 'account' and private.payout_model(p_account) = 'closing' then
    select coalesce(sum(amount), 0) into v_balance from public.payout_entries where account_id = p_account and status = 'approved' and effective_on <= current_date;
    insert into public.payouts (organization_id, account_id, kind, period_start, period_end, carry_in, period_net, debt_deduction, amount, carry_out, status, requested_by, note)
    values (a.organization_id, a.id, 'closing', current_date, current_date, 0, v_balance, 0, 0, v_balance, 'settled', auth.uid(), 'Saldo de abertura ao passar para fechamento')
    returning id into v_open;
    update public.payout_entries set statement_id = v_open where account_id = p_account and statement_id is null and effective_on <= current_date and status = 'approved';
  end if;
  perform set_config('corban.payout_rpc', 'off', true);
end
$$;

-- Manual entries (pending until someone else approves). Advances and discounts may be split in monthly installments
-- (rounded, residual in the last one).
create or replace function public.add_payout_entry(p_account uuid, p_kind text, p_amount numeric, p_direction text, p_description text, p_effective_on date, p_installments int default 1)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  a public.payout_accounts%rowtype;
  v_group uuid := gen_random_uuid();
  v_sign int;
  s record;
  i int;
begin
  select * into a from public.payout_accounts where id = p_account;
  if a.id is null or auth.uid() is null or not (public.has_permission(a.organization_id, 'repasse.create') or public.has_permission(a.organization_id, 'repasse.edit')) then raise exception 'not_authorized'; end if;
  if p_kind not in ('advance','bonus','discount','adjustment') then raise exception 'invalid_entry_kind'; end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then raise exception 'invalid_amount'; end if;
  if p_description is null or length(btrim(p_description)) < 3 then raise exception 'description_required'; end if;
  if coalesce(p_installments, 1) < 1 or p_installments > 48 or (p_installments > 1 and p_kind not in ('advance','discount')) then raise exception 'invalid_installments'; end if;
  v_sign := case p_kind when 'bonus' then 1 when 'adjustment' then case p_direction when 'credit' then 1 when 'debit' then -1 end else -1 end;
  if v_sign is null then raise exception 'invalid_direction'; end if;
  select * into s from private.deferred_schedule(p_amount, coalesce(p_installments, 1));
  perform set_config('corban.payout_rpc', 'on', true);
  for i in 1 .. coalesce(p_installments, 1) loop
    insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, entry_group, description, status, created_by)
    values (a.organization_id, a.id, p_kind, v_sign * case when i = coalesce(p_installments, 1) then s.last else s.standard end,
            (coalesce(p_effective_on, current_date) + make_interval(months => i - 1))::date, v_group,
            left(btrim(p_description), 180) || case when coalesce(p_installments, 1) > 1 then ' (' || i || '/' || p_installments || ')' else '' end,
            'pending', auth.uid());
  end loop;
  perform set_config('corban.payout_rpc', 'off', true);
  return v_group;
end
$$;

-- Approves or rejects a manual entry (all installments of it). Never by who entered it.
create or replace function public.decide_payout_entry(p_entry uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare e public.payout_entries%rowtype;
begin
  select * into e from public.payout_entries where id = p_entry;
  if e.id is null or auth.uid() is null or not public.has_permission(e.organization_id, 'repasse.approve') then raise exception 'not_authorized'; end if;
  if e.status <> 'pending' then raise exception 'payout_entry_decision_is_final'; end if;
  if e.created_by = auth.uid() or private.is_payout_holder(e.account_id) then raise exception 'four_eyes_required'; end if;
  if not p_approve and (p_note is null or length(btrim(p_note)) < 3) then raise exception 'note_required'; end if;
  perform set_config('corban.payout_rpc', 'on', true);
  update public.payout_entries
  set status = case when p_approve then 'approved' else 'rejected' end, decided_by = auth.uid(), decided_at = now(), decision_note = nullif(left(btrim(coalesce(p_note, '')), 300), '')
  where status = 'pending' and (id = e.id or (e.entry_group is not null and entry_group = e.entry_group));
  perform set_config('corban.payout_rpc', 'off', true);
end
$$;

-- Closes a period for every account on the closing model: approved entries not yet in a statement, effective up to
-- p_period_end, become one statement per account. A negative carry is deducted at most debt_limit_pct of the net.
create or replace function public.close_payout_period(p_org uuid, p_period_end date)
returns int
language plpgsql
security definer
set search_path to ''
as $$
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
  select coalesce((select debt_limit_pct from public.payout_settings where organization_id = p_org), 30) into v_limit;
  perform set_config('corban.payout_rpc', 'on', true);

  for a in select id from public.payout_accounts where organization_id = p_org and private.payout_model(id) = 'closing' order by created_at for update loop
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
$$;

-- Available balance of an account on the account model: approved entries effective until today, less open withdrawals.
create or replace function private.payout_available(p_account uuid)
returns numeric
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce((select sum(amount) from public.payout_entries where account_id = p_account and status = 'approved' and effective_on <= current_date), 0)
       - coalesce((select sum(amount) from public.payouts where account_id = p_account and kind = 'withdrawal' and status in ('pending','approved')), 0)
$$;

revoke all on function private.payout_available(uuid) from public, anon, authenticated;

create or replace function public.request_payout_withdrawal(p_account uuid, p_amount numeric, p_note text default null)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare a public.payout_accounts%rowtype; v_id uuid;
begin
  select * into a from public.payout_accounts where id = p_account for update;
  if a.id is null or auth.uid() is null
     or not (private.is_payout_holder(a.id) or public.has_permission(a.organization_id, 'repasse.create') or public.has_permission(a.organization_id, 'repasse.edit')) then
    raise exception 'not_authorized';
  end if;
  if private.payout_model(a.id) <> 'account' then raise exception 'account_model_required'; end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then raise exception 'invalid_amount'; end if;
  if p_amount > private.payout_available(a.id) then raise exception 'insufficient_balance'; end if;
  perform set_config('corban.payout_rpc', 'on', true);
  insert into public.payouts (organization_id, account_id, kind, amount, status, requested_by, note)
  values (a.organization_id, a.id, 'withdrawal', p_amount, 'pending', auth.uid(), nullif(left(btrim(coalesce(p_note, '')), 300), ''))
  returning id into v_id;
  perform set_config('corban.payout_rpc', 'off', true);
  return v_id;
end
$$;

-- Approves (or cancels) a statement or withdrawal. Never by who created it. Cancelling a statement frees its entries.
create or replace function public.decide_payout(p_payout uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare p public.payouts%rowtype;
begin
  select * into p from public.payouts where id = p_payout for update;
  if p.id is null or auth.uid() is null or not public.has_permission(p.organization_id, 'repasse.approve') then raise exception 'not_authorized'; end if;
  if p_approve and p.status <> 'pending' then raise exception 'payout_not_pending'; end if;
  if not p_approve and p.status not in ('pending','approved') then raise exception 'payout_not_open'; end if;
  if p_approve and (p.requested_by = auth.uid() or private.is_payout_holder(p.account_id)) then raise exception 'four_eyes_required'; end if;
  if not p_approve and (p_note is null or length(btrim(p_note)) < 3) then raise exception 'note_required'; end if;
  perform set_config('corban.payout_rpc', 'on', true);
  if p_approve then
    update public.payouts set status = 'approved', approved_by = auth.uid(), approved_at = now() where id = p.id;
  else
    update public.payouts set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = now(), note = left(btrim(p_note), 300) where id = p.id;
    update public.payout_entries set statement_id = null where statement_id = p.id;
  end if;
  perform set_config('corban.payout_rpc', 'off', true);
end
$$;

-- Marks an approved statement or withdrawal as paid (money left by hand) and writes the payout entry.
create or replace function public.mark_payout_paid(p_payout uuid, p_paid_on date, p_reference text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare p public.payouts%rowtype;
begin
  select * into p from public.payouts where id = p_payout for update;
  if p.id is null or auth.uid() is null or not (public.has_permission(p.organization_id, 'repasse.edit') or public.has_permission(p.organization_id, 'repasse.approve')) then raise exception 'not_authorized'; end if;
  if p.status <> 'approved' then raise exception 'payout_not_approved'; end if;
  if p_paid_on is null or p_paid_on > current_date then raise exception 'invalid_paid_on'; end if;
  if p_reference is null or length(btrim(p_reference)) < 3 then raise exception 'reference_required'; end if;
  perform set_config('corban.payout_rpc', 'on', true);
  update public.payouts set status = 'paid', paid_by = auth.uid(), paid_at = now(), paid_on = p_paid_on, payment_reference = left(btrim(p_reference), 120) where id = p.id;
  insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status, created_by, statement_id, payout_id)
  values (p.organization_id, p.account_id, 'payout', -p.amount, p_paid_on,
          case when p.kind = 'closing' then 'Repasse do período ' || to_char(p.period_end, 'DD/MM/YYYY') else 'Saque' end,
          'approved', auth.uid(), case when p.kind = 'closing' then p.id end, p.id);
  perform set_config('corban.payout_rpc', 'off', true);
end
$$;

-- Accounts with holder, model, balances and open items; finance sees all, a person only their own.
create or replace function public.payout_account_summaries(p_org uuid)
returns table (account_id uuid, holder_name text, holder_kind text, model text, balance numeric, available numeric, pending_entries int, open_payouts int)
language sql
stable
security definer
set search_path to ''
as $$
  select a.id, coalesce(s.name, u.email::text, 'Membro'), case when a.seller_id is not null then 'seller' else 'member' end, private.payout_model(a.id),
         coalesce((select sum(e.amount) from public.payout_entries e where e.account_id = a.id and e.status = 'approved'), 0),
         private.payout_available(a.id),
         (select count(*)::int from public.payout_entries e where e.account_id = a.id and e.status = 'pending'),
         (select count(*)::int from public.payouts p where p.account_id = a.id and p.status in ('pending','approved'))
  from public.payout_accounts a
  left join public.commercial_sellers s on s.id = a.seller_id
  left join auth.users u on u.id = a.user_id
  where a.organization_id = p_org and auth.uid() is not null and public.is_active_organization_member(p_org)
    and (public.has_permission(p_org, 'repasse.view') or private.is_payout_holder(a.id))
  order by 2
$$;

-- Counts for the Action Center: manual entries and payouts waiting for approval, approved payouts not yet paid.
create or replace function public.payout_alerts(p_org uuid)
returns table (kind text, total int, oldest timestamptz)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or not public.has_permission(p_org, 'repasse.view') then raise exception 'not_authorized'; end if;
  return query
  select 'approvals_pending'::text, count(*)::int, min(t.at) from (
    select e.created_at as at from public.payout_entries e where e.organization_id = p_org and e.status = 'pending'
    union all select p.requested_at from public.payouts p where p.organization_id = p_org and p.status = 'pending') t
  union all
  select 'approved_unpaid', count(*)::int, min(p.approved_at) from public.payouts p where p.organization_id = p_org and p.status = 'approved';
end
$$;

revoke all on function public.save_payout_settings(uuid, text, text, numeric) from public, anon;
revoke all on function public.ensure_payout_account(uuid, uuid, uuid) from public, anon;
revoke all on function public.set_payout_account_model(uuid, text) from public, anon;
revoke all on function public.add_payout_entry(uuid, text, numeric, text, text, date, int) from public, anon;
revoke all on function public.decide_payout_entry(uuid, boolean, text) from public, anon;
revoke all on function public.close_payout_period(uuid, date) from public, anon;
revoke all on function public.request_payout_withdrawal(uuid, numeric, text) from public, anon;
revoke all on function public.decide_payout(uuid, boolean, text) from public, anon;
revoke all on function public.mark_payout_paid(uuid, date, text) from public, anon;
revoke all on function public.payout_account_summaries(uuid) from public, anon;
revoke all on function public.payout_alerts(uuid) from public, anon;
grant execute on function public.save_payout_settings(uuid, text, text, numeric) to authenticated;
grant execute on function public.ensure_payout_account(uuid, uuid, uuid) to authenticated;
grant execute on function public.set_payout_account_model(uuid, text) to authenticated;
grant execute on function public.add_payout_entry(uuid, text, numeric, text, text, date, int) to authenticated;
grant execute on function public.decide_payout_entry(uuid, boolean, text) to authenticated;
grant execute on function public.close_payout_period(uuid, date) to authenticated;
grant execute on function public.request_payout_withdrawal(uuid, numeric, text) to authenticated;
grant execute on function public.decide_payout(uuid, boolean, text) to authenticated;
grant execute on function public.mark_payout_paid(uuid, date, text) to authenticated;
grant execute on function public.payout_account_summaries(uuid) to authenticated;
grant execute on function public.payout_alerts(uuid) to authenticated;
