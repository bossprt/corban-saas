-- Pay a broker or seller in one action from their account (owner decision 29/09/2026, ADR-0048): the owner spent 30
-- minutes failing to pay one commission because the flow needed a period closing, a second person's approval and a
-- separate "mark paid". Chosen: whoever may approve payouts pays directly, without a second approval; the record keeps
-- who paid, when, and the proof.
--
-- The amount is computed exactly as before:
--   * closing model: the same statement as close_payout_period, for this account only, up to today (carry from the last
--     paid statement, the debt deduction limit, the carry to the next one). The per-account calculation moves to
--     private.close_payout_account, now used by both, so there is one money rule, not two.
--   * account (withdrawal) model: the available balance.
-- An open payout of the account (pending or approved) is paid as it is instead of creating another. Paying goes through
-- public.mark_payout_paid: entry in the statement, company finance posting and seller credit exactly as before. Nobody
-- pays themselves. Nothing to pay is refused, not recorded as a zero payment.

create or replace function private.close_payout_account(p_account uuid, p_period_end date, p_limit numeric)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  a public.payout_accounts%rowtype;
  prev public.payouts%rowtype;
  v_net numeric;
  v_first date;
  v_carry numeric;
  v_amount numeric;
  v_id uuid;
begin
  -- Caller holds corban.payout_rpc and has checked permissions and the account model.
  select * into a from public.payout_accounts where id = p_account;
  if exists (select 1 from public.payouts where account_id = a.id and kind = 'closing' and status in ('pending','approved')) then return null; end if;
  select coalesce(sum(amount), 0), min(effective_on) into v_net, v_first from public.payout_entries
  where account_id = a.id and status = 'approved' and statement_id is null and kind <> 'payout' and effective_on <= p_period_end;
  if v_first is null then return null; end if;
  select * into prev from public.payouts where account_id = a.id and kind = 'closing' and status in ('paid','settled') order by period_end desc, requested_at desc limit 1;
  v_carry := coalesce(prev.carry_out, 0);
  if v_carry >= 0 then
    v_amount := greatest(0, v_carry + v_net);
  elsif v_net <= 0 then
    v_amount := 0;
  else
    v_amount := v_net - least(-v_carry, trunc(v_net * p_limit / 100, 2));
  end if;
  insert into public.payouts (organization_id, account_id, kind, period_start, period_end, carry_in, period_net, debt_deduction, amount, carry_out, status, requested_by)
  values (a.organization_id, a.id, 'closing', least(coalesce(prev.period_end + 1, v_first), v_first), p_period_end, v_carry, v_net,
          case when v_carry < 0 and v_net > 0 then v_net - v_amount else 0 end, v_amount, v_carry + v_net - v_amount,
          case when v_amount > 0 then 'pending' else 'settled' end, auth.uid())
  returning id into v_id;
  update public.payout_entries set statement_id = v_id
  where account_id = a.id and status = 'approved' and statement_id is null and kind <> 'payout' and effective_on <= p_period_end;
  return v_id;
end
$$;
revoke all on function private.close_payout_account(uuid, date, numeric) from public, anon, authenticated;

-- Same behaviour as before; the per-account statement now comes from private.close_payout_account.
create or replace function public.close_payout_period(p_org uuid, p_period_end date, p_frequency text default null)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_limit numeric;
  a record;
  v_count int := 0;
begin
  if auth.uid() is null or not (public.has_permission(p_org, 'repasse.create') or public.has_permission(p_org, 'repasse.edit')) then raise exception 'not_authorized'; end if;
  if p_period_end is null or p_period_end > current_date then raise exception 'invalid_period_end'; end if;
  if p_frequency is not null and p_frequency not in ('daily', 'weekly', 'biweekly', 'monthly') then raise exception 'invalid_frequency'; end if;
  select coalesce((select debt_limit_pct from public.payout_settings where organization_id = p_org), 30) into v_limit;
  perform set_config('corban.payout_rpc', 'on', true);
  for a in select id from public.payout_accounts where organization_id = p_org and private.payout_model(id) = 'closing'
                and (p_frequency is null or private.payout_frequency(id) = p_frequency) order by created_at for update loop
    if private.close_payout_account(a.id, p_period_end, v_limit) is not null then v_count := v_count + 1; end if;
  end loop;
  perform set_config('corban.payout_rpc', 'off', true);
  return v_count;
end
$$;

create or replace function public.pay_account_now(p_account uuid, p_paid_on date, p_reference text)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  a public.payout_accounts%rowtype;
  p public.payouts%rowtype;
  v_today date := (now() at time zone 'America/Sao_Paulo')::date;
  v_limit numeric;
  v_id uuid;
  v_available numeric;
begin
  select * into a from public.payout_accounts where id = p_account for update;
  if a.id is null or auth.uid() is null or not public.has_permission(a.organization_id, 'repasse.approve') then raise exception 'not_authorized'; end if;
  if private.is_payout_holder(a.id) then raise exception 'cannot_pay_yourself'; end if;
  if p_paid_on is null or p_paid_on > v_today or p_paid_on < date '2000-01-01' then raise exception 'invalid_paid_on'; end if;
  if p_reference is null or length(btrim(p_reference)) < 3 then raise exception 'reference_required'; end if;

  perform set_config('corban.payout_rpc', 'on', true);
  -- An open payout of this account is paid as it is.
  select * into p from public.payouts where account_id = a.id and status in ('pending','approved') order by requested_at limit 1 for update;
  if p.id is not null then
    v_id := p.id;
  elsif private.payout_model(a.id) = 'closing' then
    select coalesce((select debt_limit_pct from public.payout_settings where organization_id = a.organization_id), 30) into v_limit;
    v_id := private.close_payout_account(a.id, v_today, v_limit);
    if v_id is null then raise exception 'nothing_to_pay'; end if;
    select * into p from public.payouts where id = v_id;
    if p.status = 'settled' then raise exception 'nothing_to_pay'; end if;
  else
    v_available := private.payout_available(a.id);
    if v_available <= 0 then raise exception 'nothing_to_pay'; end if;
    insert into public.payouts (organization_id, account_id, kind, amount, status, requested_by, note)
    values (a.organization_id, a.id, 'withdrawal', v_available, 'pending', auth.uid(), 'Pago direto pela conta')
    returning id into v_id;
  end if;

  update public.payouts
     set status = 'approved', approved_by = auth.uid(), approved_at = now(),
         note = left(coalesce(nullif(note, '') || ' · ', '') || 'Pago direto, sem segunda aprovação', 300)
   where id = v_id and status = 'pending';
  perform public.mark_payout_paid(v_id, p_paid_on, p_reference);
  perform set_config('corban.payout_rpc', 'off', true);
  return v_id;
end
$$;
revoke all on function public.pay_account_now(uuid, date, text) from public, anon;
grant execute on function public.pay_account_now(uuid, date, text) to authenticated;
