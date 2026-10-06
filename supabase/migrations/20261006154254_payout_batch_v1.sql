-- Pay several sellers at once (owner request 06/10/2026). The owner sees, for each account with money to pay, the exact
-- amount "Pagar agora" would pay today, pays them in the bank (PIX QR Code or TED) and then confirms the ones paid.
--   * private.pay_now_amount: the amount pay_account_now would pay today, computed without writing anything: an open
--     payout as it is; a closing account as private.close_payout_account would close it today (carry, debt limit);
--     an account-model account its available balance. Mirrors those functions line by line.
--   * public.payout_pay_list: the accounts with something to pay, for whoever may pay (repasse.approve), never the
--     viewer's own account (nobody pays themselves).
--   * public.pay_account_now_checked: pay_account_now, refused with 'amount_changed' when the amount is no longer the
--     one shown (a commission was released or reversed meanwhile), so what is recorded is always what was paid.
-- No table changes; pay_account_now itself is untouched.

create or replace function private.pay_now_amount(p_account uuid)
returns numeric
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  a public.payout_accounts%rowtype;
  p public.payouts%rowtype;
  prev public.payouts%rowtype;
  v_today date := (now() at time zone 'America/Sao_Paulo')::date;
  v_limit numeric;
  v_net numeric;
  v_first date;
  v_carry numeric;
begin
  select * into a from public.payout_accounts where id = p_account;
  if a.id is null then return null; end if;
  select * into p from public.payouts where account_id = a.id and status in ('pending','approved') order by requested_at limit 1;
  if p.id is not null then return p.amount; end if;
  if private.payout_model(a.id) <> 'closing' then return greatest(0, private.payout_available(a.id)); end if;

  select coalesce((select debt_limit_pct from public.payout_settings where organization_id = a.organization_id), 30) into v_limit;
  select coalesce(sum(amount), 0), min(effective_on) into v_net, v_first from public.payout_entries
  where account_id = a.id and status = 'approved' and statement_id is null and kind <> 'payout' and effective_on <= v_today;
  if v_first is null then return 0; end if;
  select * into prev from public.payouts where account_id = a.id and kind = 'closing' and status in ('paid','settled') order by period_end desc, requested_at desc limit 1;
  v_carry := coalesce(prev.carry_out, 0);
  if v_carry >= 0 then return greatest(0, v_carry + v_net); end if;
  if v_net <= 0 then return 0; end if;
  return v_net - least(-v_carry, trunc(v_net * v_limit / 100, 2));
end
$$;
revoke all on function private.pay_now_amount(uuid) from public, anon, authenticated;

create or replace function public.payout_pay_list(p_org uuid)
returns table(account_id uuid, seller_id uuid, holder_name text, amount numeric)
language sql
stable
security definer
set search_path to ''
as $$
  select x.id, x.seller_id, x.holder_name, x.amount
  from (select a.id, a.seller_id, coalesce(s.name, u.email::text, 'Membro') as holder_name, private.pay_now_amount(a.id) as amount
        from public.payout_accounts a
        left join public.commercial_sellers s on s.id = a.seller_id
        left join auth.users u on u.id = a.user_id
        where a.organization_id = p_org and auth.uid() is not null and public.is_active_organization_member(p_org)
          and public.has_permission(p_org, 'repasse.approve') and not private.is_payout_holder(a.id)) x
  where x.amount > 0
  order by x.holder_name
$$;
revoke all on function public.payout_pay_list(uuid) from public, anon;
grant execute on function public.payout_pay_list(uuid) to authenticated;

create or replace function public.pay_account_now_checked(p_account uuid, p_paid_on date, p_reference text, p_expected numeric)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare a public.payout_accounts%rowtype;
begin
  select * into a from public.payout_accounts where id = p_account for update;
  if a.id is null or auth.uid() is null or not public.has_permission(a.organization_id, 'repasse.approve') then raise exception 'not_authorized'; end if;
  if p_expected is null or private.pay_now_amount(a.id) is distinct from p_expected then raise exception 'amount_changed'; end if;
  return public.pay_account_now(p_account, p_paid_on, p_reference);
end
$$;
revoke all on function public.pay_account_now_checked(uuid, date, text, numeric) from public, anon;
grant execute on function public.pay_account_now_checked(uuid, date, text, numeric) to authenticated;
