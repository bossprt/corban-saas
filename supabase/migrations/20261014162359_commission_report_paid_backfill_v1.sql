-- Owner (14/10/2026): the contracts whose bank commission was already received through a confirmed commission report
-- before 20261014140000_commission_report_marks_paid_v1, and that are still not "Paga", move to "Paga" now with the same
-- rule (seller and active calculation required). On 14/10 these were 2 PROSESP contracts. Data only; idempotent.

do $$
declare
  r record;
  v_moved int := 0;
begin
  for r in
    select distinct on (l.proposal_id) l.proposal_id, l.report_id,
           (select min(x.paid_on) from public.receipt_lines x where x.report_id = l.report_id and x.proposal_id = l.proposal_id and x.status in ('ok','divergent')) as paid_on
    from public.receipt_lines l
    join public.receipt_reports rep on rep.id = l.report_id and rep.status = 'confirmed' and rep.report_kind <> 'chargeback'
    join public.commission_receipts cr on cr.line_id = l.id and cr.entry_kind = 'receipt'
    join public.proposals_v2 p on p.id = l.proposal_id and p.status not in ('paid', 'cancelled', 'rejected')
    where l.status in ('ok','divergent')
    order by l.proposal_id, rep.confirmed_at desc
  loop
    if private.mark_paid_by_commission_report(r.proposal_id, r.report_id, r.paid_on) then v_moved := v_moved + 1; end if;
  end loop;
  raise notice 'commission_report_paid_backfill moved % contract(s)', v_moved;
end $$;
