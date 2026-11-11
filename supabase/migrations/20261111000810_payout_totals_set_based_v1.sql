-- Contratos mais rápido (dono, 10/11/2026): contract_list spent ~85% of its time in contract_payout_totals, which called
-- private.contract_credit_state once per contract. Each call re-plans that function and the functions inside it
-- (~1.3 ms per contract), so 169 contracts cost ~260 ms on every filter click. Here the same expressions run as one
-- lateral subquery inside a single query (~50 ms). Result is identical (checked against production data: same waiting,
-- credited and paid_on for every contract). private.contract_credit_state is unchanged and still used by contract_credit;
-- manual-commission-zero-contract.sql and gratification-receipt-apart-contract.sql fail if the two ever disagree.

create or replace function public.contract_payout_totals(p_org uuid)
returns table(proposal_id uuid, received numeric, rule_amount numeric, payable numeric, overridden boolean, waiting text, credited numeric, paid_on date,
              gratification_pending boolean)
language plpgsql
stable security definer
set search_path to ''
as $function$
declare v_admin boolean;
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.view') then raise exception 'not_authorized'; end if;
  v_admin := public.has_active_organization_role(p_org, array['admin']);
  return query
    select c.proposal_id, sum(x.received), case when v_admin then sum(x.rule_amount) else sum(x.payable) end, sum(x.payable),
           v_admin and bool_or(x.overridden), s.waiting, s.credited, s.paid_on, private.contract_gratification_pending(c.proposal_id)
    from public.proposal_commission_calcs c
    cross join lateral private.contract_payable(c.proposal_id) x
    -- Same expressions as private.contract_credit_state (20261110205134), inline so they are planned once.
    cross join lateral (
      select case when p.status <> 'paid' then 'client'
                  when p.formalization = 'physical' and p.physical_received_at is null then 'physical'
                  when not exists (select 1 from public.proposal_commission_calcs c2 where c2.proposal_id = p.id and c2.status = 'active') then 'calculation'
                  when private.contract_bank_receipt(p.id) is null
                   and exists (select 1 from public.proposal_commission_lines l join public.proposal_commission_calcs c2 on c2.id = l.calc_id
                               where c2.proposal_id = p.id and c2.status = 'active' and l.line_kind = 'received' and l.amount > 0) then 'bank'
                  when private.contract_bank_receipt(p.id) = 'divergent' then 'divergent'
                  when coalesce((select sum(y.payable) from private.contract_payable(p.id) y), 0) = 0
                   and coalesce((select sum(e.amount) from public.payout_entries e where e.proposal_id = p.id and e.beneficiary_role = 'originator'
                                 and e.source in ('contract', 'receipt') and e.status = 'approved'), 0) = 0 then 'no_payout'
             end as waiting,
             coalesce((select sum(e.amount) from public.payout_entries e where e.proposal_id = p.id and e.beneficiary_role = 'originator'
                       and e.source in ('contract', 'receipt') and e.status = 'approved'), 0) as credited,
             (select max(o.paid_on) from public.payout_entries e join public.payouts o on o.id = coalesce(e.statement_id, e.payout_id)
              where e.proposal_id = p.id and e.beneficiary_role = 'originator' and o.status in ('paid', 'settled')) as paid_on
      from public.proposals_v2 p where p.id = c.proposal_id
    ) s
    where c.organization_id = p_org and c.status = 'active'
    group by c.proposal_id, s.waiting, s.credited, s.paid_on;
end
$function$;
revoke all on function public.contract_payout_totals(uuid) from public, anon;
grant execute on function public.contract_payout_totals(uuid) to authenticated, service_role;
