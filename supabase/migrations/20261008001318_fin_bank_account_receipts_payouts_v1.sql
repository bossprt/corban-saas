-- Company bank account on commission receipts and seller payouts (owner request 07/10/2026).
--
-- The commission report import, the manual receipt and the seller payment posted to the company finance without saying
-- which company bank account the money went into or out of, so the statement of each account could not be checked.
-- 1. receipt_reports.bank_account_id: the account that received the report's money, chosen at import. The receipts of the
--    report are posted with it (also the ones linked later). It is the only field of a report that may still change once
--    the report is closed: it says where the money went, not what the bank sent.
-- 2. fin_assign_bank_account: sets the account of settled entries posted from receipts or payouts (financeiro.edit), with
--    an event per entry (from / to). The screens call it right after paying a seller or registering a receipt.
-- 3. Owner decision 07/10/2026: every commission received so far came into the C6 account and every payout left from it.
--    The existing receipt and payout entries of Smart Promotora without account get "C6 MART PROMOTORA", with an event;
--    its reports point to the same account.
-- Amounts and dates never change. Contract: tests/security/fin-bank-account-contract.sql

alter table public.receipt_reports add column if not exists bank_account_id uuid references public.fin_bank_accounts(id) on delete restrict;

CREATE OR REPLACE FUNCTION public.guard_receipt_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if current_setting('corban.receipt_rpc', true) is distinct from 'on' then raise exception 'receipt_write_requires_governed_rpc'; end if;
  if tg_op = 'DELETE' then raise exception 'receipt_records_are_not_deletable'; end if;
  if tg_table_name in ('commission_receipts','commission_receipt_resolutions') and tg_op <> 'INSERT' then
    raise exception 'receipt_ledger_is_append_only';
  end if;
  if tg_table_name = 'receipt_lines' and tg_op = 'UPDATE' then
    if exists (select 1 from public.receipt_reports r where r.id = old.report_id and r.status <> 'draft') then raise exception 'receipt_report_is_closed'; end if;
    if new.report_id is distinct from old.report_id or new.row_number is distinct from old.row_number or new.ade is distinct from old.ade
       or new.amount is distinct from old.amount or new.installment_number is distinct from old.installment_number or new.organization_id is distinct from old.organization_id then
      raise exception 'receipt_line_source_is_immutable';
    end if;
  end if;
  if tg_table_name = 'receipt_reports' and tg_op = 'UPDATE' then
    -- The bank account that received the money may be set or corrected at any time (07/10/2026).
    if (to_jsonb(new) - 'bank_account_id') is not distinct from (to_jsonb(old) - 'bank_account_id') then return new; end if;
    if old.status <> 'draft' then raise exception 'receipt_report_is_closed'; end if;
    if (to_jsonb(new) - array['status','line_count','lines_total','confirmed_by','confirmed_at','discarded_by','discarded_at','bank_account_id'])
       is distinct from (to_jsonb(old) - array['status','line_count','lines_total','confirmed_by','confirmed_at','discarded_by','discarded_at','bank_account_id']) then
      raise exception 'receipt_report_source_is_immutable';
    end if;
  end if;
  return new;
end
$function$;

CREATE OR REPLACE FUNCTION private.fin_post_receipt(p_receipt uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare x public.commission_receipts%rowtype; v_account uuid; v_key text; v_id uuid; v_ade text; v_bank text; v_bank_account uuid;
begin
  select * into x from public.commission_receipts where id = p_receipt;
  if x.id is null then return null; end if;
  if exists (select 1 from public.fin_entries e where e.organization_id = x.organization_id and e.source = 'commission_receipt' and e.source_ref = x.id and e.status <> 'cancelled') then return null; end if;
  perform private.fin_ensure_chart(x.organization_id);
  v_key := case when x.entry_kind = 'chargeback' then 'chargeback' when x.component_key = 'deferred' then 'commission_deferred' else 'commission_upfront' end;
  select id into v_account from public.fin_chart_accounts where organization_id = x.organization_id and system_key = v_key;
  select p.external_proposal_id, p.commercial_snapshot->>'bank' into v_ade, v_bank from public.proposals_v2 p where p.id = x.proposal_id;
  -- The account that received the report's money, when the import said it.
  select r.bank_account_id into v_bank_account from public.receipt_reports r
  join public.fin_bank_accounts k on k.id = r.bank_account_id and k.organization_id = x.organization_id
  where r.id = x.report_id;
  insert into public.fin_entries (organization_id, direction, status, description, account_id, counterpart, amount, due_on, competence_on, settled_on, source, source_ref, proposal_id, bank_account_id, created_by)
  values (x.organization_id, case when x.entry_kind = 'chargeback' then 'out' else 'in' end, 'settled',
          left(case when x.entry_kind = 'chargeback' then 'Estorno de comissão' when x.component_key = 'deferred' then 'Comissão diferida parcela ' || coalesce(x.installment_number::text, '')
               else 'Comissão à vista' end || coalesce(' · ADE ' || v_ade, ''), 200),
          v_account, left(v_bank, 120), x.amount, coalesce(x.received_on, current_date), coalesce(x.received_on, current_date), coalesce(x.received_on, current_date),
          'commission_receipt', x.id, x.proposal_id, v_bank_account, auth.uid())
  returning id into v_id;
  perform private.fin_event(x.organization_id, v_id, 'created', jsonb_build_object('source', 'commission_receipt'), null);
  return v_id;
end
$function$;

-- Sets the company bank account of settled entries posted from commission receipts or seller payouts. Returns how many
-- entries changed. Only the account changes; the event keeps the previous one.
create or replace function public.fin_assign_bank_account(p_org uuid, p_source text, p_refs uuid[], p_bank_account uuid)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare e record; v_count integer := 0;
begin
  if auth.uid() is null or p_org is null or not public.has_permission(p_org, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if p_source not in ('commission_receipt', 'payout') or p_refs is null or cardinality(p_refs) = 0 or cardinality(p_refs) > 500 then raise exception 'fin_assign_invalid'; end if;
  if p_bank_account is null or not exists (select 1 from public.fin_bank_accounts k where k.id = p_bank_account and k.organization_id = p_org and k.is_active) then
    raise exception 'fin_bank_account_invalid';
  end if;
  for e in
    select x.id, x.bank_account_id from public.fin_entries x
    where x.organization_id = p_org and x.source = p_source and x.source_ref = any(p_refs) and x.status = 'settled'
      and x.bank_account_id is distinct from p_bank_account
    for update
  loop
    update public.fin_entries set bank_account_id = p_bank_account, updated_at = now() where id = e.id;
    perform private.fin_event(p_org, e.id, 'edited', jsonb_build_object('field', 'bank_account', 'from', e.bank_account_id, 'to', p_bank_account), null);
    v_count := v_count + 1;
  end loop;
  return v_count;
end
$$;
revoke all on function public.fin_assign_bank_account(uuid, text, uuid[], uuid) from public, anon;
grant execute on function public.fin_assign_bank_account(uuid, text, uuid[], uuid) to authenticated;

-- The account that received a commission report's money; its receipts already posted take it too.
create or replace function public.set_receipt_report_bank_account(p_report uuid, p_bank_account uuid)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare r public.receipt_reports%rowtype; v_refs uuid[];
begin
  select * into r from public.receipt_reports where id = p_report for update;
  if r.id is null or auth.uid() is null or not public.has_permission(r.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if p_bank_account is null or not exists (select 1 from public.fin_bank_accounts k where k.id = p_bank_account and k.organization_id = r.organization_id and k.is_active) then
    raise exception 'fin_bank_account_invalid';
  end if;
  perform set_config('corban.receipt_rpc', 'on', true);
  update public.receipt_reports set bank_account_id = p_bank_account where id = r.id;
  perform set_config('corban.receipt_rpc', 'off', true);
  select array_agg(c.id) into v_refs from public.commission_receipts c where c.report_id = r.id;
  if v_refs is null then return 0; end if;
  return public.fin_assign_bank_account(r.organization_id, 'commission_receipt', v_refs, p_bank_account);
end
$$;
revoke all on function public.set_receipt_report_bank_account(uuid, uuid) from public, anon;
grant execute on function public.set_receipt_report_bank_account(uuid, uuid) to authenticated;

-- Owner decision 07/10/2026: Smart Promotora's commissions came into C6 and its payouts left from C6.
do $$
declare v_org uuid := '62405e20-af29-4359-b39c-79c206146b6c'; v_c6 uuid; e record; v_n integer := 0;
begin
  select k.id into v_c6 from public.fin_bank_accounts k where k.organization_id = v_org and k.label = 'C6 MART PROMOTORA' and k.is_active;
  if v_c6 is null then raise notice 'fin bank account: company or account not here, nothing to do'; return; end if;
  for e in
    select x.id from public.fin_entries x
    where x.organization_id = v_org and x.source in ('commission_receipt', 'payout') and x.status = 'settled' and x.bank_account_id is null
    for update
  loop
    update public.fin_entries set bank_account_id = v_c6, updated_at = now() where id = e.id;
    perform private.fin_event(v_org, e.id, 'edited', jsonb_build_object('field', 'bank_account', 'from', null, 'to', v_c6),
                              'Decisão do dono 07/10/2026: comissões entraram e repasses saíram pela conta C6');
    v_n := v_n + 1;
  end loop;
  perform set_config('corban.receipt_rpc', 'on', true);
  update public.receipt_reports set bank_account_id = v_c6 where organization_id = v_org and bank_account_id is null;
  perform set_config('corban.receipt_rpc', 'off', true);
  raise notice 'fin bank account: % entries set to C6', v_n;
end
$$;
