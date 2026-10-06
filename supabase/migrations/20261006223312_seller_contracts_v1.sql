-- "Meus contratos" for the seller and the external broker (owner request 06/10/2026): every contract where the caller
-- is the seller, also the ones the company typed for them, with the situation and their own share (the payable
-- amount, never the amount by the rule) and where that share stands (waiting for the client, the bank..., released,
-- received). Only for a member bound to a seller record; newest first, up to 300. Read only.

create or replace function public.seller_contracts(p_org uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_user uuid := auth.uid();
  v_sellers uuid[];
begin
  if v_user is null or not public.is_active_organization_member(p_org) then raise exception 'not_authorized'; end if;
  select array_agg(s.id) into v_sellers from public.commercial_sellers s where s.organization_id = p_org and s.user_id = v_user;
  if v_sellers is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(x order by x->>'created_at' desc) from (
      select jsonb_build_object(
        'id', p.id, 'client', p.customer_snapshot->>'full_name', 'ade', p.external_proposal_id,
        'bank', p.commercial_snapshot->>'bank', 'table', p.commercial_snapshot->>'table', 'term', p.term,
        'amount', coalesce(p.released_amount, p.requested_amount, 0), 'status', p.status, 'stage', os.name,
        'paid_to_client_on', p.paid_to_client_on, 'created_at', p.created_at,
        'by_me', exists (select 1 from public.proposal_submissions ps where ps.proposal_id = p.id),
        'payable', coalesce((select sum(x.payable) from private.contract_payable(p.id) x), 0),
        'calculated', exists (select 1 from public.proposal_commission_calcs c where c.proposal_id = p.id and c.status = 'active'),
        'waiting', st.waiting, 'paid_on', st.paid_on) as x
      from public.proposals_v2 p
      cross join lateral private.contract_credit_state(p.id) st
      left join public.operational_cases oc on oc.proposal_id = p.id
      left join public.operational_stages os on os.id = oc.current_stage_id
      where p.organization_id = p_org and p.seller_id = any (v_sellers)
        and not exists (select 1 from public.proposal_submissions ps where ps.proposal_id = p.id and ps.status <> 'validated')
      order by p.created_at desc
      limit 300) z), '[]'::jsonb);
end
$$;
revoke all on function public.seller_contracts(uuid) from public, anon;
grant execute on function public.seller_contracts(uuid) to authenticated;
