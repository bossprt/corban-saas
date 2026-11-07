-- Contracts of each seller payment (owner, 06/11/2026: "verificar quais os contratos fazem parte de cada comissão de
-- vendedores"). Every payment, in a batch or not, and the payment about to be made ("Pagar vendedores") show the
-- contracts it pays and how its amount is made:
--   Soma dos contratos + outros lançamentos (bônus, vales, descontos, ajustes sem contrato, saldo anterior, desconto do
--   negativo, negativo que passa para o próximo) = Total pago.
-- Each part is computed on its own; "difference" = total - contracts - others is returned as is (never forced to zero),
-- so a payment whose parts do not add up shows the difference instead of hiding it. Read only; no table changes.
-- Commission percentages never appear (only amounts of the person's own entries).
--
--   * private.withdrawal_allocation_with: private.withdrawal_allocation plus one simulated payment (p_preview at
--     p_preview_at), returned with payout id 00000000-0000-0000-0000-000000000000. private.withdrawal_allocation now
--     calls it with no simulated payment (same result as before).
--   * private.payout_breakdown(payout): contracts (as private.payout_contracts) and the other items of one payment.
--   * private.payout_preview(account): the same for what "Pagar agora" would pay today (private.pay_now_amount).
--   * public.payout_breakdown(payout): finance (repasse.view) or the person (own payments, not undone ones).
--   * public.payout_pay_preview(account): whoever may pay (repasse.approve), never the own account.
--   * payout_batch_detail and payout_account_report: each payment carries the breakdown (contracts now lists only
--     real contracts; items without contract moved to "others").

create or replace function private.withdrawal_allocation_with(p_account uuid, p_preview numeric, p_preview_at timestamptz)
returns table(r_payout uuid, r_proposal uuid, r_kind text, r_amount numeric, r_item numeric)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  ev record;
  q_prop uuid[] := '{}';
  q_kind text[] := '{}';
  q_left numeric[] := '{}';
  q_full numeric[] := '{}';
  v_head int := 1;
  i int;
  v_debt numeric := 0;
  v_amt numeric;
  v_need numeric;
  v_take numeric;
begin
  for ev in
    select x.payout, x.proposal, x.kind, x.amount
    from (
      select null::uuid as payout, e.proposal_id as proposal, e.kind, e.amount,
             greatest(e.created_at, e.effective_on::timestamp at time zone 'America/Sao_Paulo') as at, e.created_at as tie
      from public.payout_entries e
      where e.account_id = p_account and e.status = 'approved' and e.kind <> 'payout'
        and e.statement_id is null and e.payout_id is null and e.amount <> 0
      union all
      select p.id, null, 'withdrawal', p.amount, p.requested_at, p.requested_at
      from public.payouts p
      where p.account_id = p_account and p.kind = 'withdrawal' and p.status = 'paid' and p.amount > 0
      union all
      select '00000000-0000-0000-0000-000000000000'::uuid, null, 'withdrawal', p_preview, coalesce(p_preview_at, now()), coalesce(p_preview_at, now())
      where p_preview > 0
    ) x
    order by x.at, x.tie, (x.payout is not null)
  loop
    if ev.payout is null and ev.amount > 0 then
      v_amt := ev.amount;
      v_take := least(v_debt, v_amt);
      v_debt := v_debt - v_take;
      v_amt := v_amt - v_take;
      if v_amt > 0 then
        q_prop := q_prop || ev.proposal; q_kind := q_kind || ev.kind; q_left := q_left || v_amt; q_full := q_full || v_amt;
      end if;
    elsif ev.payout is null then
      v_need := -ev.amount;
      if ev.proposal is not null then
        for i in v_head .. coalesce(array_length(q_left, 1), 0) loop
          exit when v_need = 0;
          if q_prop[i] = ev.proposal and q_left[i] > 0 then
            v_take := least(q_left[i], v_need);
            q_left[i] := q_left[i] - v_take; q_full[i] := q_full[i] - v_take; v_need := v_need - v_take;
          end if;
        end loop;
      end if;
      for i in v_head .. coalesce(array_length(q_left, 1), 0) loop
        exit when v_need = 0;
        if q_left[i] > 0 then
          v_take := least(q_left[i], v_need);
          q_left[i] := q_left[i] - v_take; v_need := v_need - v_take;
        end if;
      end loop;
      v_debt := v_debt + v_need;
    else
      v_need := ev.amount;
      for i in v_head .. coalesce(array_length(q_left, 1), 0) loop
        exit when v_need = 0;
        if q_left[i] > 0 then
          v_take := least(q_left[i], v_need);
          q_left[i] := q_left[i] - v_take; v_need := v_need - v_take;
          r_payout := ev.payout; r_proposal := q_prop[i]; r_kind := q_kind[i]; r_amount := v_take; r_item := q_full[i];
          return next;
        end if;
      end loop;
      if v_need > 0 then
        r_payout := ev.payout; r_proposal := null; r_kind := 'unmatched'; r_amount := v_need; r_item := v_need;
        return next;
      end if;
    end if;
    while v_head <= coalesce(array_length(q_left, 1), 0) and q_left[v_head] = 0 loop v_head := v_head + 1; end loop;
  end loop;
end
$$;
revoke all on function private.withdrawal_allocation_with(uuid, numeric, timestamptz) from public, anon, authenticated;

create or replace function private.withdrawal_allocation(p_account uuid)
returns table(r_payout uuid, r_proposal uuid, r_kind text, r_amount numeric, r_item numeric)
language sql
stable
security definer
set search_path to ''
as $$
  select * from private.withdrawal_allocation_with(p_account, null, null)
$$;
revoke all on function private.withdrawal_allocation(uuid) from public, anon, authenticated;

-- Items of a payment from the balance (real or simulated): contracts, and what has no contract by kind.
create or replace function private.payout_alloc_items(p_account uuid, p_key uuid, p_preview numeric, p_at timestamptz)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  with a as (select * from private.withdrawal_allocation_with(p_account, p_preview, p_at) where r_payout = p_key)
  select jsonb_build_object(
    'contracts', coalesce((
      select jsonb_agg(jsonb_build_object('proposal_id', c.proposal_id, 'ade', c.ade, 'client', c.client, 'amount', c.amount::text,
                                          'partial', c.partial, 'kind', null) || coalesce(private.batch_contract_info(c.proposal_id), '{}'::jsonb)
                       order by c.ade nulls last)
      from (select a.r_proposal as proposal_id, pr.external_proposal_id as ade, pr.customer_snapshot->>'full_name' as client,
                   sum(a.r_amount) as amount, bool_or(a.r_amount < a.r_item) as partial
            from a join public.proposals_v2 pr on pr.id = a.r_proposal
            group by a.r_proposal, pr.external_proposal_id, pr.customer_snapshot->>'full_name') c), '[]'::jsonb),
    'others', coalesce((
      select jsonb_agg(jsonb_build_object('kind', o.kind, 'description', null, 'effective_on', null, 'amount', o.amount::text, 'partial', o.partial)
                       order by o.kind)
      from (select a.r_kind as kind, sum(a.r_amount) as amount, bool_or(a.r_amount < a.r_item) as partial
            from a where a.r_proposal is null or not exists (select 1 from public.proposals_v2 pr where pr.id = a.r_proposal)
            group by a.r_kind) o), '[]'::jsonb))
$$;
revoke all on function private.payout_alloc_items(uuid, uuid, numeric, timestamptz) from public, anon, authenticated;

-- Items of a closing: the entries it closed (p_statement), or the ones a closing up to p_until would close today.
-- Contracts as private.payout_contracts (commission, chargeback, adjustment with a contract); every other entry listed.
create or replace function private.payout_closing_items(p_account uuid, p_statement uuid, p_until date)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  with e as (
    select x.id, x.kind, x.amount, x.effective_on, x.description, x.proposal_id, x.created_at,
           (x.proposal_id is not null and x.kind in ('commission', 'chargeback', 'adjustment')) as is_contract
    from public.payout_entries x
    where x.status = 'approved' and x.kind <> 'payout'
      and case when p_statement is not null then x.statement_id = p_statement
               else x.account_id = p_account and x.statement_id is null and x.effective_on <= p_until end)
  select jsonb_build_object(
    'contracts', coalesce((
      select jsonb_agg(jsonb_build_object('proposal_id', c.proposal_id, 'ade', c.ade, 'client', c.client, 'amount', c.amount::text,
                                          'partial', false, 'kind', null) || coalesce(private.batch_contract_info(c.proposal_id), '{}'::jsonb)
                       order by c.ade)
      from (select e.proposal_id, pr.external_proposal_id as ade, pr.customer_snapshot->>'full_name' as client, sum(e.amount) as amount
            from e join public.proposals_v2 pr on pr.id = e.proposal_id
            where e.is_contract
            group by e.proposal_id, pr.external_proposal_id, pr.customer_snapshot->>'full_name') c), '[]'::jsonb),
    'others', coalesce((
      select jsonb_agg(jsonb_build_object('kind', e.kind, 'description', e.description, 'effective_on', e.effective_on, 'amount', e.amount::text)
                       order by e.effective_on, e.created_at)
      from e where not e.is_contract), '[]'::jsonb),
    'net', (select coalesce(sum(e.amount), 0) from e)::text,
    'first', (select min(e.effective_on) from e))
$$;
revoke all on function private.payout_closing_items(uuid, uuid, date) from public, anon, authenticated;

-- Totals of a breakdown. For a closing (p_carry_in not null) adds the balance lines: positive previous balance,
-- discount of the negative balance, negative of the period passed to the next one. Each part on its own rule.
create or replace function private.payout_breakdown_of(p_items jsonb, p_amount numeric, p_carry_in numeric, p_net numeric, p_debt numeric)
returns jsonb
language plpgsql
immutable
set search_path to ''
as $$
declare
  v_contracts jsonb := coalesce(p_items->'contracts', '[]'::jsonb);
  v_others jsonb := coalesce(p_items->'others', '[]'::jsonb);
  v_ct numeric;
  v_ot numeric;
  v_cf numeric;
begin
  if p_carry_in is not null then
    if p_carry_in > 0 then
      v_others := v_others || jsonb_build_array(jsonb_build_object('kind', 'carry_in', 'description', null, 'effective_on', null, 'amount', round(p_carry_in, 2)::text));
    end if;
    if coalesce(p_debt, 0) > 0 then
      v_others := v_others || jsonb_build_array(jsonb_build_object('kind', 'debt_deduction', 'description', null, 'effective_on', null, 'amount', round(-p_debt, 2)::text));
    end if;
    -- A closing never pays below zero: a negative result stays for the next period (it is added back here).
    v_cf := case when p_carry_in >= 0 then greatest(0, -(p_carry_in + coalesce(p_net, 0)))
                 when coalesce(p_net, 0) <= 0 then -coalesce(p_net, 0) else 0 end;
    if v_cf > 0 then
      v_others := v_others || jsonb_build_array(jsonb_build_object('kind', 'carry_forward', 'description', null, 'effective_on', null, 'amount', round(v_cf, 2)::text));
    end if;
  end if;
  select coalesce(sum((c->>'amount')::numeric), 0) into v_ct from jsonb_array_elements(v_contracts) c;
  select coalesce(sum((o->>'amount')::numeric), 0) into v_ot from jsonb_array_elements(v_others) o;
  return jsonb_build_object('contracts', v_contracts, 'contracts_total', round(v_ct, 2)::text, 'others', v_others, 'others_total', round(v_ot, 2)::text,
                            'total', round(coalesce(p_amount, 0), 2)::text, 'difference', round(coalesce(p_amount, 0) - v_ct - v_ot, 2)::text, 'undone', false);
end
$$;
revoke all on function private.payout_breakdown_of(jsonb, numeric, numeric, numeric, numeric) from public, anon, authenticated;

create or replace function private.payout_breakdown(p_payout uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare p public.payouts%rowtype;
begin
  select * into p from public.payouts where id = p_payout;
  if p.id is null then return null; end if;
  -- Undone or cancelled: its entries went back to the balance; nothing to list.
  if p.status in ('reversed', 'cancelled') then
    return jsonb_build_object('contracts', '[]'::jsonb, 'contracts_total', '0.00', 'others', '[]'::jsonb, 'others_total', '0.00',
                              'total', p.amount::text, 'difference', '0.00', 'undone', true);
  end if;
  if p.kind = 'closing' then
    return private.payout_breakdown_of(private.payout_closing_items(p.account_id, p.id, null), p.amount, p.carry_in, p.period_net, p.debt_deduction);
  end if;
  if p.status = 'paid' then
    return private.payout_breakdown_of(private.payout_alloc_items(p.account_id, p.id, null, null), p.amount, null, null, null);
  end if;
  -- A withdrawal not paid yet: as if paid when it was requested.
  return private.payout_breakdown_of(private.payout_alloc_items(p.account_id, '00000000-0000-0000-0000-000000000000'::uuid, p.amount, p.requested_at),
                                     p.amount, null, null, null);
end
$$;
revoke all on function private.payout_breakdown(uuid) from public, anon, authenticated;

-- What "Pagar agora" would pay today (same paths as private.pay_now_amount / pay_account_now). The total is
-- private.pay_now_amount itself; the parts are computed apart, so any mismatch shows as a difference.
create or replace function private.payout_preview(p_account uuid)
returns jsonb
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
  v_items jsonb;
  v_net numeric;
  v_carry numeric;
  v_amount numeric;
begin
  select * into a from public.payout_accounts where id = p_account;
  if a.id is null then return null; end if;
  v_amount := coalesce(private.pay_now_amount(a.id), 0);
  select * into p from public.payouts where account_id = a.id and status in ('pending','approved') order by requested_at limit 1;
  if p.id is not null then
    v_items := private.payout_breakdown(p.id);
    return v_items || jsonb_build_object('total', round(v_amount, 2)::text, 'kind', p.kind, 'payout_id', p.id,
             'difference', round(v_amount - (v_items->>'contracts_total')::numeric - (v_items->>'others_total')::numeric, 2)::text);
  end if;
  if private.payout_model(a.id) <> 'closing' then
    return private.payout_breakdown_of(private.payout_alloc_items(a.id, '00000000-0000-0000-0000-000000000000'::uuid, v_amount, now()), v_amount, null, null, null)
           || jsonb_build_object('kind', 'withdrawal', 'payout_id', null);
  end if;
  v_items := private.payout_closing_items(a.id, null, v_today);
  if v_items->>'first' is null then
    return private.payout_breakdown_of(v_items, v_amount, null, null, null) || jsonb_build_object('kind', 'closing', 'payout_id', null);
  end if;
  v_net := (v_items->>'net')::numeric;
  select coalesce((select debt_limit_pct from public.payout_settings where organization_id = a.organization_id), 30) into v_limit;
  select * into prev from public.payouts where account_id = a.id and kind = 'closing' and status in ('paid','settled') order by period_end desc, requested_at desc limit 1;
  v_carry := coalesce(prev.carry_out, 0);
  return private.payout_breakdown_of(v_items, v_amount, v_carry, v_net,
                                     case when v_carry < 0 and v_net > 0 then least(-v_carry, trunc(v_net * v_limit / 100, 2)) else 0 end)
         || jsonb_build_object('kind', 'closing', 'payout_id', null);
end
$$;
revoke all on function private.payout_preview(uuid) from public, anon, authenticated;

-- One payment with its contracts and the composition of its amount. Finance, or the person (own payments, not undone).
create or replace function public.payout_breakdown(p_payout uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare p public.payouts%rowtype;
begin
  select * into p from public.payouts where id = p_payout;
  if p.id is null or auth.uid() is null
     or not (public.has_permission(p.organization_id, 'repasse.view')
             or (private.is_payout_holder(p.account_id) and p.status <> 'reversed')) then
    raise exception 'not_authorized';
  end if;
  return private.payout_breakdown(p.id) || jsonb_build_object(
    'payout_id', p.id, 'account_id', p.account_id, 'holder', private.payout_holder_name(p.account_id), 'kind', p.kind, 'status', p.status,
    'amount', p.amount::text, 'paid_on', p.paid_on, 'payment_reference', p.payment_reference, 'period_start', p.period_start,
    'period_end', p.period_end, 'requested_at', p.requested_at, 'batch_id', p.batch_id, 'note', p.note);
end
$$;
revoke all on function public.payout_breakdown(uuid) from public, anon;
grant execute on function public.payout_breakdown(uuid) to authenticated;

-- What "Pagar vendedores" / "Pagar agora" would pay this account today, before paying. Whoever may pay; never the own account.
create or replace function public.payout_pay_preview(p_account uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare a public.payout_accounts%rowtype;
begin
  select * into a from public.payout_accounts where id = p_account;
  if a.id is null or auth.uid() is null or not public.has_permission(a.organization_id, 'repasse.approve') then raise exception 'not_authorized'; end if;
  if private.is_payout_holder(a.id) then raise exception 'cannot_pay_yourself'; end if;
  return private.payout_preview(a.id) || jsonb_build_object('account_id', a.id, 'holder', private.payout_holder_name(a.id));
end
$$;
revoke all on function public.payout_pay_preview(uuid) from public, anon;
grant execute on function public.payout_pay_preview(uuid) to authenticated;

-- Batch detail: as 20261106234355_payout_safe_payment_v1; each line carries the breakdown of its payment.
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
        'holder_document', private.payout_holder_info(p.account_id)->>'document', 'pay_target', private.payout_holder_info(p.account_id)->'pay_target'
      ) || (private.payout_breakdown(p.id) - 'total') order by private.payout_holder_name(p.account_id))
      from public.payouts p where p.batch_id = b.id), '[]'::jsonb));
end
$$;
revoke all on function public.payout_batch_detail(uuid) from public, anon;
grant execute on function public.payout_batch_detail(uuid) to authenticated;

-- One person over a period: as 20261021041405_payout_reports_v1; each payment carries its breakdown.
create or replace function public.payout_account_report(p_account uuid, p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare a public.payout_accounts%rowtype;
begin
  select * into a from public.payout_accounts where id = p_account;
  if a.id is null or auth.uid() is null
     or not (public.has_permission(a.organization_id, 'repasse.view') or private.is_payout_holder(a.id)) then raise exception 'not_authorized'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 400 then raise exception 'invalid_period'; end if;
  return jsonb_build_object(
    'company', (select jsonb_build_object('name', o.name, 'document', o.document) from public.organizations o where o.id = a.organization_id),
    'holder', private.payout_holder_info(a.id),
    'from', p_from, 'to', p_to,
    'total', (select coalesce(sum(p.amount), 0)::text from public.payouts p where p.account_id = a.id and p.status = 'paid' and p.paid_on between p_from and p_to),
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object('payout_id', p.id, 'paid_on', p.paid_on, 'kind', p.kind, 'amount', p.amount::text,
                                          'reference', p.payment_reference) || (private.payout_breakdown(p.id) - 'total') order by p.paid_on, p.requested_at)
      from public.payouts p where p.account_id = a.id and p.status = 'paid' and p.paid_on between p_from and p_to), '[]'::jsonb));
end
$$;
revoke all on function public.payout_account_report(uuid, date, date) from public, anon;
grant execute on function public.payout_account_report(uuid, date, date) to authenticated;
