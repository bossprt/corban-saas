-- Payment proof optional when paying an account in one action (owner request 29/09/2026): typing the PIX id meant
-- sending the receipt image elsewhere to transcribe it. A blank proof is recorded as "Sem comprovante informado"; the
-- payment still keeps who paid and when. Only the proof check changes; the rest of pay_account_now is unchanged.

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
  v_reference text := coalesce(nullif(btrim(coalesce(p_reference, '')), ''), 'Sem comprovante informado');
begin
  select * into a from public.payout_accounts where id = p_account for update;
  if a.id is null or auth.uid() is null or not public.has_permission(a.organization_id, 'repasse.approve') then raise exception 'not_authorized'; end if;
  if private.is_payout_holder(a.id) then raise exception 'cannot_pay_yourself'; end if;
  if p_paid_on is null or p_paid_on > v_today or p_paid_on < date '2000-01-01' then raise exception 'invalid_paid_on'; end if;
  if length(v_reference) < 3 then raise exception 'reference_required'; end if;

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
  perform public.mark_payout_paid(v_id, p_paid_on, v_reference);
  perform set_config('corban.payout_rpc', 'off', true);
  return v_id;
end
$$;
