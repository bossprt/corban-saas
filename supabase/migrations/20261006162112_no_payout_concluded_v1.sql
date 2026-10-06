-- A contract whose seller receives R$ 0,00 (own production, group "Smart Promotora") is concluded once the client was
-- paid and the bank commission arrived (owner request 06/10/2026): there is no seller payment to wait for, so it no
-- longer shows "liberado, a pagar" forever. private.contract_credit_state gains the state 'no_payout' for that case:
-- every step done, nothing payable to the seller and nothing credited. No payment of R$ 0,00 is recorded; if the
-- contract is recalculated and the seller comes to receive something, it goes back to the normal flow by itself.
-- Display only: no table or data changes; contract_credit and contract_payout_totals pass the state through.

create or replace function private.contract_credit_state(p_proposal uuid)
returns table(waiting text, credited numeric, paid_on date, reference text)
language sql
stable
security definer
set search_path to ''
as $$
  select case when p.status <> 'paid' then 'client'
              when p.formalization = 'physical' and p.physical_received_at is null then 'physical'
              when not exists (select 1 from public.proposal_commission_calcs c where c.proposal_id = p.id and c.status = 'active') then 'calculation'
              when private.contract_bank_receipt(p.id) is null then 'bank'
              when private.contract_bank_receipt(p.id) = 'divergent' then 'divergent'
              when coalesce((select sum(x.payable) from private.contract_payable(p.id) x), 0) = 0
               and coalesce((select sum(e.amount) from public.payout_entries e where e.proposal_id = p.id and e.beneficiary_role = 'originator'
                             and e.source in ('contract', 'receipt') and e.status = 'approved'), 0) = 0 then 'no_payout'
         end,
         coalesce((select sum(e.amount) from public.payout_entries e where e.proposal_id = p.id and e.beneficiary_role = 'originator' and e.source in ('contract', 'receipt') and e.status = 'approved'), 0),
         (select max(y.paid_on) from public.payout_entries e join public.payouts y on y.id = coalesce(e.statement_id, e.payout_id)
          where e.proposal_id = p.id and e.beneficiary_role = 'originator' and y.status in ('paid', 'settled')),
         (select y.payment_reference from public.payout_entries e join public.payouts y on y.id = coalesce(e.statement_id, e.payout_id)
          where e.proposal_id = p.id and e.beneficiary_role = 'originator' and y.status in ('paid', 'settled') order by y.paid_on desc nulls last limit 1)
  from public.proposals_v2 p where p.id = p_proposal
$$;
