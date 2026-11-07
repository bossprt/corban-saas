-- Safe seller payments (audit 06/11/2026, G1, G2, E2, E9). Additive; payout rows and their guards are unchanged.
--   * public.payout_pay_now_amount: the exact amount "Pagar agora" pays today (private.pay_now_amount, the same number
--     pay_account_now_checked compares with), read-only, so the screen shows what the database will record.
--   * public.pay_account_confirmed: "Pagar agora" with the amount shown on screen (refused with amount_changed when it
--     differs) and the company bank account recorded in the same transaction.
--   * public.mark_payout_paid_with_bank: "Marcar pago" with the company bank account in the same transaction.
--   * public.pay_payout_batch: "Confirmar pagos" as one transaction, all or nothing: every amount is checked before
--     anything is paid, one batch, the bank account recorded with the payments. Errors name the accounts (detail).
--   * payout_batch_list / payout_batch_detail: "total" counts only effective (paid) payments; the undone ones come apart
--     in undone_total, as the printed batch already did.
-- The bank account is recorded under the payment permission (repasse.approve / repasse.edit): the account the money left
-- from is part of the payment itself. It must be an active account of the same company.

create or replace function private.payout_check_bank_account(p_org uuid, p_bank_account uuid)
returns void
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if p_bank_account is not null
     and not exists (select 1 from public.fin_bank_accounts k where k.id = p_bank_account and k.organization_id = p_org and k.is_active) then
    raise exception 'fin_bank_account_invalid';
  end if;
end
$$;
revoke all on function private.payout_check_bank_account(uuid, uuid) from public, anon, authenticated;

-- Posts the company account on the finance outflows of the payouts just paid (as fin_assign_bank_account does).
create or replace function private.payout_record_bank_account(p_org uuid, p_payouts uuid[], p_bank_account uuid)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare e record; v_count integer := 0;
begin
  if p_bank_account is null or p_payouts is null or cardinality(p_payouts) = 0 then return 0; end if;
  perform private.payout_check_bank_account(p_org, p_bank_account);
  for e in
    select x.id, x.bank_account_id from public.fin_entries x
    where x.organization_id = p_org and x.source = 'payout' and x.source_ref = any(p_payouts) and x.status = 'settled'
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
revoke all on function private.payout_record_bank_account(uuid, uuid[], uuid) from public, anon, authenticated;

-- The amount "Pagar agora" would pay today, for whoever may pay. Null for the viewer's own account (nobody pays
-- themselves). Decimal text with two places, never a float.
create or replace function public.payout_pay_now_amount(p_account uuid)
returns text
language plpgsql
stable
security definer
set search_path to ''
as $$
declare a public.payout_accounts%rowtype;
begin
  select * into a from public.payout_accounts where id = p_account;
  if a.id is null or auth.uid() is null or not public.has_permission(a.organization_id, 'repasse.approve') then raise exception 'not_authorized'; end if;
  if private.is_payout_holder(a.id) then return null; end if;
  return round(coalesce(private.pay_now_amount(a.id), 0), 2)::text;
end
$$;
revoke all on function public.payout_pay_now_amount(uuid) from public, anon;
grant execute on function public.payout_pay_now_amount(uuid) to authenticated;

create or replace function public.pay_account_confirmed(p_account uuid, p_paid_on date, p_reference text, p_expected numeric, p_bank_account uuid)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare a public.payout_accounts%rowtype; v_id uuid;
begin
  select * into a from public.payout_accounts where id = p_account;
  if a.id is null or auth.uid() is null or not public.has_permission(a.organization_id, 'repasse.approve') then raise exception 'not_authorized'; end if;
  perform private.payout_check_bank_account(a.organization_id, p_bank_account);
  v_id := public.pay_account_now_checked(p_account, p_paid_on, p_reference, p_expected);
  perform private.payout_record_bank_account(a.organization_id, array[v_id], p_bank_account);
  return v_id;
end
$$;
revoke all on function public.pay_account_confirmed(uuid, date, text, numeric, uuid) from public, anon;
grant execute on function public.pay_account_confirmed(uuid, date, text, numeric, uuid) to authenticated;

create or replace function public.mark_payout_paid_with_bank(p_payout uuid, p_paid_on date, p_reference text, p_bank_account uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare p public.payouts%rowtype;
begin
  select * into p from public.payouts where id = p_payout;
  if p.id is null or auth.uid() is null
     or not (public.has_permission(p.organization_id, 'repasse.edit') or public.has_permission(p.organization_id, 'repasse.approve')) then
    raise exception 'not_authorized';
  end if;
  perform private.payout_check_bank_account(p.organization_id, p_bank_account);
  perform public.mark_payout_paid(p_payout, p_paid_on, p_reference);
  perform private.payout_record_bank_account(p.organization_id, array[p.id], p_bank_account);
end
$$;
revoke all on function public.mark_payout_paid_with_bank(uuid, date, text, uuid) from public, anon;
grant execute on function public.mark_payout_paid_with_bank(uuid, date, text, uuid) to authenticated;

-- "Confirmar pagos": p_lines = [{"account": uuid, "expected": "123.45"}, ...] (1 to 300 accounts). All or nothing.
create or replace function public.pay_payout_batch(p_org uuid, p_paid_on date, p_reference text, p_bank_account uuid, p_lines jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_batch uuid := gen_random_uuid();
  v_lines jsonb := coalesce(p_lines, 'null'::jsonb);
  v_bad text;
  v_ids uuid[] := '{}';
  v_total numeric := 0;
  v_id uuid;
  r record;
begin
  if auth.uid() is null or p_org is null or not public.has_permission(p_org, 'repasse.approve') then raise exception 'not_authorized'; end if;
  if jsonb_typeof(v_lines) is distinct from 'array' or jsonb_array_length(v_lines) not between 1 and 300 then raise exception 'invalid_batch_lines'; end if;
  if exists (select 1 from jsonb_array_elements(v_lines) el
             where jsonb_typeof(el) <> 'object'
                or coalesce(el->>'account', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                or case when coalesce(el->>'expected', '') ~ '^[0-9]{1,12}(\.[0-9]{1,2})?$' then (el->>'expected')::numeric <= 0 else true end) then
    raise exception 'invalid_batch_lines';
  end if;
  if (select count(distinct (el->>'account')::uuid) from jsonb_array_elements(v_lines) el) <> jsonb_array_length(v_lines) then
    raise exception 'invalid_batch_lines';
  end if;
  perform private.payout_check_bank_account(p_org, p_bank_account);

  -- Every account belongs to this company.
  select string_agg(el->>'account', ',') into v_bad from jsonb_array_elements(v_lines) el
  where not exists (select 1 from public.payout_accounts a where a.id = (el->>'account')::uuid and a.organization_id = p_org);
  if v_bad is not null then raise exception 'not_authorized' using detail = v_bad; end if;

  -- Lock the accounts (in a fixed order), then check them all before paying any.
  perform 1 from public.payout_accounts a
  where a.id in (select (el->>'account')::uuid from jsonb_array_elements(v_lines) el) order by a.id for update;
  select string_agg(el->>'account', ',') into v_bad from jsonb_array_elements(v_lines) el
  where private.is_payout_holder((el->>'account')::uuid);
  if v_bad is not null then raise exception 'cannot_pay_yourself' using detail = v_bad; end if;
  select string_agg(el->>'account', ',') into v_bad from jsonb_array_elements(v_lines) el
  where private.pay_now_amount((el->>'account')::uuid) is distinct from (el->>'expected')::numeric;
  if v_bad is not null then raise exception 'amount_changed' using detail = v_bad; end if;

  perform set_config('corban.payout_batch', v_batch::text, true);
  for r in select (el->>'account')::uuid as account, (el->>'expected')::numeric as expected from jsonb_array_elements(v_lines) el loop
    begin
      v_id := public.pay_account_now_checked(r.account, p_paid_on, p_reference, r.expected);
    exception when others then
      raise exception '%', sqlerrm using detail = r.account::text;
    end;
    v_ids := v_ids || v_id;
    v_total := v_total + r.expected;
  end loop;
  perform set_config('corban.payout_batch', '', true);
  perform private.payout_record_bank_account(p_org, v_ids, p_bank_account);
  return jsonb_build_object('batch_id', v_batch, 'paid', cardinality(v_ids), 'total', v_total::text);
end
$$;
revoke all on function public.pay_payout_batch(uuid, date, text, uuid, jsonb) from public, anon;
grant execute on function public.pay_payout_batch(uuid, date, text, uuid, jsonb) to authenticated;

-- Batch list: total and count of effective payments; the undone ones apart (undone, undone_total).
drop function public.payout_batch_list(uuid, integer);
create function public.payout_batch_list(p_org uuid, p_limit integer default 200)
returns table (id uuid, paid_on date, payment_reference text, origin text, created_at timestamptz, paid_by text, payouts integer,
               total text, undone integer, undone_total text, bank_accounts text, reversed_at timestamptz, reversal_reason text)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or not public.has_permission(p_org, 'repasse.view') then raise exception 'not_authorized'; end if;
  return query
  select b.id, b.paid_on, b.payment_reference, b.origin, b.created_at,
         (select coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), u.email) from auth.users u where u.id = b.created_by),
         count(p.id)::integer,
         coalesce(sum(p.amount) filter (where p.status = 'paid'), 0)::text,
         count(p.id) filter (where p.status = 'reversed')::integer,
         coalesce(sum(p.amount) filter (where p.status = 'reversed'), 0)::text,
         (select string_agg(distinct coalesce(nullif(a.label, ''), a.bank_name), ', ') from public.fin_entries f join public.fin_bank_accounts a on a.id = f.bank_account_id
          where f.organization_id = b.organization_id and f.source = 'payout' and f.source_ref in (select x.id from public.payouts x where x.batch_id = b.id)),
         b.reversed_at, b.reversal_reason
  from public.payout_batches b
  left join public.payouts p on p.batch_id = b.id
  where b.organization_id = p_org
  group by b.id
  having count(p.id) > 0
  order by b.paid_on desc, b.created_at desc
  limit least(greatest(coalesce(p_limit, 200), 1), 1000);
end
$$;
revoke all on function public.payout_batch_list(uuid, integer) from public, anon;
grant execute on function public.payout_batch_list(uuid, integer) to authenticated;

-- Batch detail: as 20261021041405_payout_reports_v1, with total = paid only and undone_total apart.
create or replace function public.payout_batch_detail(p_batch uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare b public.payout_batches%rowtype;
begin
  select * into b from public.payout_batches where id = p_batch;
  if b.id is null or auth.uid() is null or not public.has_permission(b.organization_id, 'repasse.view') then raise exception 'not_authorized'; end if;
  return jsonb_build_object(
    'id', b.id, 'paid_on', b.paid_on, 'payment_reference', b.payment_reference, 'origin', b.origin, 'created_at', b.created_at,
    'company', (select jsonb_build_object('name', o.name, 'document', o.document) from public.organizations o where o.id = b.organization_id),
    'paid_by', (select coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), u.email) from auth.users u where u.id = b.created_by),
    'reversed_at', b.reversed_at, 'reversal_reason', b.reversal_reason,
    'total', (select coalesce(sum(x.amount), 0)::text from public.payouts x where x.batch_id = b.id and x.status = 'paid'),
    'undone_total', (select coalesce(sum(x.amount), 0)::text from public.payouts x where x.batch_id = b.id and x.status = 'reversed'),
    'reversed_by', (select coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), u.email) from auth.users u where u.id = b.reversed_by),
    'bank_accounts', (select string_agg(distinct coalesce(nullif(a.label, ''), a.bank_name), ', ') from public.fin_entries f join public.fin_bank_accounts a on a.id = f.bank_account_id
                      where f.organization_id = b.organization_id and f.source = 'payout' and f.source_ref in (select x.id from public.payouts x where x.batch_id = b.id)),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'payout_id', p.id, 'account_id', p.account_id, 'holder', private.payout_holder_name(p.account_id), 'kind', p.kind,
        'amount', p.amount::text, 'status', p.status, 'reversal_reason', p.reversal_reason,
        'holder_document', private.payout_holder_info(p.account_id)->>'document', 'pay_target', private.payout_holder_info(p.account_id)->'pay_target',
        'contracts', private.payout_contracts(p.id)
      ) order by private.payout_holder_name(p.account_id))
      from public.payouts p where p.batch_id = b.id), '[]'::jsonb));
end
$$;
revoke all on function public.payout_batch_detail(uuid) from public, anon;
grant execute on function public.payout_batch_detail(uuid) to authenticated;
