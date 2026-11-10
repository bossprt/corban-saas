-- Contratos (dono, 10/11/2026): contract 2756344 was zeroed (the company receives R$ 0) and then showed "aguardando
-- comissão do banco" forever: the bank step waited for a receipt that will never come. Now, when the active calculation
-- receives nothing (no "received" line above R$ 0), the bank step is skipped and the contract goes on to the next steps
-- ("concluído · sem repasse" when the seller gets R$ 0). A contract that receives anything still waits for the bank.
-- Same body as 20261006162112; only the 'bank' line gains that condition. Display only: no table or data changes.

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
              when private.contract_bank_receipt(p.id) is null
               and exists (select 1 from public.proposal_commission_lines l join public.proposal_commission_calcs c on c.id = l.calc_id
                           where c.proposal_id = p.id and c.status = 'active' and l.line_kind = 'received' and l.amount > 0) then 'bank'
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
