-- Part C4: removal of the ChatGPT-era commission leftovers (owner approved the full list 27/09/2026, ADR-0042).
--
-- Checked in production before writing: the old company rule has 0 rows; no bank or partner is marked tax exempt; no
-- calculation of the old engine exists (all are by table and group); every old share already has its group values and
-- every old commission row its components; no table line points to a payout policy. Nothing in the app calls what goes.
--
-- Backup first: the tables that hold data are copied to schema backup_c4 (not exposed by the API), kept 30 days and then
-- removed only with the owner's approval.

create schema backup_c4;
revoke all on schema backup_c4 from public, anon, authenticated;
create table backup_c4.commercial_condition_shares as select * from public.commercial_condition_shares;
create table backup_c4.commercial_condition_commissions as select * from public.commercial_condition_commissions;
create table backup_c4.commission_group_component_limits as select * from public.commission_group_component_limits;
create table backup_c4.payout_policies as select * from public.payout_policies;
create table backup_c4.payout_policy_versions as select * from public.payout_policy_versions;
create table backup_c4.payout_policy_items as select * from public.payout_policy_items;
create table backup_c4.commission_rule_versions as select * from public.commission_rule_versions;
create table backup_c4.paying_source_tax_exempt as
  select 'bank'::text as kind, id, organization_id, tax_exempt from public.organization_banks
  union all select 'provider', id, organization_id, tax_exempt from public.organization_providers;
revoke all on all tables in schema backup_c4 from public, anon, authenticated;

-- What still runs stops depending on what goes.

create or replace function private.post_receipt(p_receipt uuid)
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  x public.commission_receipts%rowtype;
  c public.proposal_commission_calcs%rowtype;
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
    if c.id is null or c.mode <> 'group_values' or (x.component_key = 'deferred' and not c.pay_deferred) then return; end if;
    begin
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
    end;
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

CREATE OR REPLACE FUNCTION public.clone_table_version(p_version uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  src public.product_table_versions%rowtype;
  v_draft uuid;
  v_next integer;
  c record;
  v_new_condition uuid;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into src from public.product_table_versions where id = p_version;
  if src.id is null or not public.has_active_organization_role(src.organization_id, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  select id into v_draft from public.product_table_versions where product_table_id = src.product_table_id and status = 'draft' order by version desc limit 1;
  if v_draft is not null then return v_draft; end if;

  select coalesce(max(version), 0) + 1 into v_next from public.product_table_versions where product_table_id = src.product_table_id;
  insert into public.product_table_versions (organization_id, product_table_id, version, status, term_min, term_max, rate, coefficient, metadata)
  values (src.organization_id, src.product_table_id, v_next, 'draft', src.term_min, src.term_max, src.rate, src.coefficient,
          coalesce(src.metadata, '{}'::jsonb) || jsonb_build_object('cloned_from', src.id))
  returning id into v_draft;

  perform set_config('corban.condition_rpc', 'on', true);
  perform set_config('corban.component_condition_rpc', 'on', true);
  perform set_config('corban.group_values_rpc', 'on', true);
  for c in select * from public.commercial_conditions where product_table_version_id = src.id order by term_min, id loop
    insert into public.commercial_conditions (organization_id, product_table_version_id, contract_type_id, term, term_min, term_max, amount_min, amount_max, coefficient, rate, tax_pct, created_by)
    values (c.organization_id, v_draft, c.contract_type_id, c.term, c.term_min, c.term_max, c.amount_min, c.amount_max, c.coefficient, c.rate, c.tax_pct, auth.uid())
    returning id into v_new_condition;
    insert into public.commercial_condition_components (organization_id, condition_id, component_type_id, value_kind, received_value, calculation_base, source, created_by)
    select organization_id, v_new_condition, component_type_id, value_kind, received_value, calculation_base, source, auth.uid()
    from public.commercial_condition_components where condition_id = c.id;
    insert into public.commercial_condition_group_values (organization_id, condition_id, group_id, component_type_id, value_kind, value, source, created_by)
    select organization_id, v_new_condition, group_id, component_type_id, value_kind, value, source, auth.uid()
    from public.commercial_condition_group_values where condition_id = c.id;
  end loop;
  perform set_config('corban.group_values_rpc', 'off', true);
  perform set_config('corban.component_condition_rpc', 'off', true);
  perform set_config('corban.condition_rpc', 'off', true);
  return v_draft;
end
$function$;

-- The old company rule (Configurações > Comissão) and the tax exemption of banks and partners.
drop function public.save_commission_rule(uuid, text, uuid, text, numeric, numeric, numeric, numeric, numeric, boolean, text);
drop function private.resolve_commission_rule(uuid, uuid, uuid, uuid, uuid, timestamptz);
drop function public.set_paying_source_tax_exempt(text, uuid, boolean);
drop table public.commission_rule_versions;
drop function public.guard_commission_rule_versions();
alter table public.organization_banks drop column tax_exempt;
alter table public.organization_providers drop column tax_exempt;

-- The old calculation.
drop function public.calculate_proposal_commission(uuid, uuid);
drop function private.distribute_commission_amount(numeric, text, numeric, boolean, numeric, numeric, numeric, numeric, numeric, boolean, boolean, boolean);

-- Old shares, old commission rows, group limits and payout policies (replaced by group values and components).
drop function private.convert_shares_to_group_values(uuid);
drop function public.import_commercial_conditions(uuid, jsonb, uuid);
drop function public.save_commercial_condition(uuid, uuid, integer, numeric, numeric, numeric, jsonb, uuid, uuid);
drop function public.save_commercial_condition_range(uuid, uuid, integer, integer, numeric, numeric, numeric, jsonb, uuid, uuid);
drop function public.save_commercial_condition_range(uuid, uuid, integer, integer, numeric, numeric, numeric, jsonb, uuid, uuid, numeric, numeric);
drop function public.save_payout_policy(uuid, text, text, numeric, jsonb, uuid);
drop function public.save_commission_group_configuration(uuid, uuid, text, jsonb);
drop table public.commercial_condition_shares;
drop table public.commercial_condition_commissions;
drop table public.payout_policy_items;
drop table public.payout_policy_versions;
drop table public.payout_policies;
drop table public.commission_group_component_limits;
drop function public.guard_commission_group_component_limit_write();
drop function public.guard_component_payout_group_limit();
