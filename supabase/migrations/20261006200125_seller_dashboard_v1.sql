-- The seller's dashboard (owner request 06/10/2026, model F, mobile first): for the person who is the seller, what they
-- will earn and what they have to do, never the company's numbers nor the amount by the rule.
--   * goal of the month: public.goal_progress for the caller (target, production paid, contracts);
--   * expected: what is payable to the seller on their contracts not released yet (client not paid, physical, bank
--     commission not in, divergence) — the payable amount, after any change the owner made;
--   * released: what the next payment of their payout account brings (private.pay_now_amount);
--   * received this month: their payouts paid this month;
--   * pending: their contracts with a pendency at the bank (reason and deadline) and their latest contracts.
-- Only for a member bound to a seller (commercial_sellers.user_id = the caller). Read only.

create or replace function public.seller_dashboard(p_org uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_user uuid := auth.uid();
  v_month date := date_trunc('month', (now() at time zone 'America/Sao_Paulo'))::date;
  v_sellers uuid[];
  v_result jsonb;
begin
  if v_user is null or not public.is_active_organization_member(p_org) then raise exception 'not_authorized'; end if;
  select array_agg(s.id) into v_sellers from public.commercial_sellers s where s.organization_id = p_org and s.user_id = v_user and s.is_active;
  if v_sellers is null then return jsonb_build_object('seller', false); end if;

  with mine as (
    select p.id, p.status, p.external_proposal_id, p.customer_snapshot->>'full_name' as client, p.created_at,
           coalesce(p.released_amount, p.requested_amount, 0) as amount, st.waiting, st.paid_on,
           coalesce((select sum(x.payable) from private.contract_payable(p.id) x), 0) as payable,
           oc.canonical_state, oc.pendency_reason, oc.pendency_due_at, os.name as stage
    from public.proposals_v2 p
    cross join lateral private.contract_credit_state(p.id) st
    left join public.operational_cases oc on oc.proposal_id = p.id
    left join public.operational_stages os on os.id = oc.current_stage_id
    where p.organization_id = p_org and p.seller_id = any (v_sellers)
  ),
  accounts as (
    select a.id from public.payout_accounts a where a.organization_id = p_org and a.seller_id = any (v_sellers)
  )
  select jsonb_build_object(
    'seller', true,
    'name', (select string_agg(s.name, ' · ') from public.commercial_sellers s where s.id = any (v_sellers)),
    'goal', coalesce((select jsonb_build_object('target', g.target_amount, 'paid', g.paid_amount, 'count', g.paid_count)
                      from public.goal_progress(p_org, v_month) g where g.user_id = v_user), jsonb_build_object('target', 0, 'paid', 0, 'count', 0)),
    'expected', (select coalesce(sum(payable), 0) from mine where status not in ('cancelled', 'rejected') and paid_on is null and waiting is not null and waiting <> 'no_payout'),
    'released', (select coalesce(sum(greatest(private.pay_now_amount(a.id), 0)), 0) from accounts a),
    'received_month', (select coalesce(sum(y.amount), 0) from public.payouts y join accounts a on a.id = y.account_id where y.status = 'paid' and y.paid_on >= v_month),
    'pending', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'client', client, 'ade', external_proposal_id, 'reason', pendency_reason, 'due', pendency_due_at) order by pendency_due_at nulls last)
                         from mine where canonical_state = 'pending_external'), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(r order by r->>'created_at' desc) from (
                          select jsonb_build_object('id', id, 'client', client, 'ade', external_proposal_id, 'amount', amount, 'status', status, 'stage', stage,
                                                    'payable', payable, 'waiting', waiting, 'paid_on', paid_on, 'created_at', created_at) as r
                          from mine order by created_at desc limit 6) z), '[]'::jsonb)
  ) into v_result;
  return v_result;
end
$$;
revoke all on function public.seller_dashboard(uuid) from public, anon;
grant execute on function public.seller_dashboard(uuid) to authenticated;
