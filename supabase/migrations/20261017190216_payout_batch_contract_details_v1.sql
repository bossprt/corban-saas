-- Owner (17/10/2026), payment batch screen and Excel:
--   1. each contract paid shows its details: bank, agreement, product (contract type), amount released to the client and
--      the day it was paid to the client (owner chose option 1);
--   2. a payment from the balance ("Saque do saldo") lists the contracts inside the amount paid (below).
--
-- Payment from the balance: until now it showed only the person (no such payment existed yet on 17/10; all were closings).
-- Owner chose: the amount paid covers the oldest contracts of the balance first; each contract shows how much of it this
-- payment paid, and "pago em parte" when the payment ended in the middle of it. The sum always equals the amount paid.
-- Read only: nothing is stored or changed.
--
-- private.withdrawal_allocation walks the account's ledger in time order (no closing entries, no undone payments):
--   * a credit enters the queue (first paying any debt left by an earlier chargeback);
--   * a negative entry (chargeback, discount) first lowers the same contract still in the queue, then the oldest ones,
--     and what is left becomes debt;
--   * a paid withdrawal takes from the oldest items in the queue; anything it cannot match is "unmatched".

create or replace function private.withdrawal_allocation(p_account uuid)
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
      -- The same contract still waiting is lowered first (its value really went down).
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
revoke all on function private.withdrawal_allocation(uuid) from public, anon, authenticated;

-- The details of one contract shown in a payment batch (bank, agreement, product, released, paid to the client on).
create or replace function private.batch_contract_info(p_proposal uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  select jsonb_build_object('bank', b.name, 'agreement', ag.name, 'product', coalesce(ct.name, t.name),
                            'released', pr.released_amount::text, 'paid_to_client_on', pr.paid_to_client_on)
  from public.proposals_v2 pr
  left join public.product_table_versions v on v.id = pr.product_table_version_id
  left join public.product_tables t on t.id = v.product_table_id
  left join public.organization_product_routes r on r.id = t.route_id
  left join public.organization_banks b on b.id = r.org_bank_id
  left join public.organization_agreements ag on ag.id = r.org_agreement_id
  left join public.contract_types ct on ct.id = pr.contract_type_id
  where pr.id = p_proposal
$$;
revoke all on function private.batch_contract_info(uuid) from public, anon, authenticated;

-- One batch: header and one line per payment, with the contracts it paid (ADE, client, amount). A closing lists the
-- contracts it closed; a payment from the balance lists the contracts its amount covered, oldest first (17/10/2026).
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
    'paid_by', (select coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), u.email) from auth.users u where u.id = b.created_by),
    'reversed_at', b.reversed_at, 'reversal_reason', b.reversal_reason,
    'total', (select coalesce(sum(x.amount), 0)::text from public.payouts x where x.batch_id = b.id),
    'reversed_by', (select coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), u.email) from auth.users u where u.id = b.reversed_by),
    'bank_accounts', (select string_agg(distinct coalesce(nullif(a.label, ''), a.bank_name), ', ') from public.fin_entries f join public.fin_bank_accounts a on a.id = f.bank_account_id
                      where f.organization_id = b.organization_id and f.source = 'payout' and f.source_ref in (select x.id from public.payouts x where x.batch_id = b.id)),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'payout_id', p.id, 'account_id', p.account_id, 'holder', private.payout_holder_name(p.account_id), 'kind', p.kind,
        'amount', p.amount::text, 'status', p.status, 'reversal_reason', p.reversal_reason,
        'contracts', case when p.kind = 'withdrawal' then coalesce((
          -- What this payment from the balance covered: one line per contract (or per item without a contract).
          select jsonb_agg(jsonb_build_object('proposal_id', c.proposal_id, 'ade', c.ade, 'client', c.client, 'amount', c.amount::text,
                                              'partial', c.partial, 'kind', c.kind) || coalesce(private.batch_contract_info(c.proposal_id), '{}'::jsonb) order by c.ade nulls last, c.kind)
          from (select a.r_proposal as proposal_id, pr.external_proposal_id as ade, pr.customer_snapshot->>'full_name' as client,
                       sum(a.r_amount) as amount, bool_or(a.r_amount < a.r_item) as partial,
                       case when a.r_proposal is null then a.r_kind end as kind
                from private.withdrawal_allocation(p.account_id) a left join public.proposals_v2 pr on pr.id = a.r_proposal
                where a.r_payout = p.id
                group by a.r_proposal, pr.external_proposal_id, pr.customer_snapshot->>'full_name', case when a.r_proposal is null then a.r_kind end) c), '[]'::jsonb)
        else coalesce((
          -- One line per contract: its commission, chargebacks and adjustments in this closing, added up.
          select jsonb_agg(jsonb_build_object('proposal_id', c.proposal_id, 'ade', c.ade, 'client', c.client, 'amount', c.amount::text,
                                              'partial', false, 'kind', null) || coalesce(private.batch_contract_info(c.proposal_id), '{}'::jsonb) order by c.ade)
          from (select e.proposal_id, pr.external_proposal_id as ade, pr.customer_snapshot->>'full_name' as client, sum(e.amount) as amount
                from public.payout_entries e join public.proposals_v2 pr on pr.id = e.proposal_id
                where e.statement_id = p.id and e.kind in ('commission', 'chargeback', 'adjustment') and e.status = 'approved'
                group by e.proposal_id, pr.external_proposal_id, pr.customer_snapshot->>'full_name') c), '[]'::jsonb) end
      ) order by private.payout_holder_name(p.account_id))
      from public.payouts p where p.batch_id = b.id), '[]'::jsonb));
end
$$;
revoke all on function public.payout_batch_detail(uuid) from public, anon;
grant execute on function public.payout_batch_detail(uuid) to authenticated;
