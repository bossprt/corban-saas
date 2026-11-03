-- "Aguardando Gratificação" (owner request 03/11/2026): a contract whose Gratificação was not received yet is not
-- concluded. Display only: amounts and credits do not change.
--
-- * private.contract_gratification_pending(proposal): the calculation in force has a Gratificação received by the
--   company, the contract is not one credited the old way (ADR-0063), and no Gratificação receipt is reconciled
--   (matched or accepted).
-- * contract_payout_totals and contract_credit return it as gratification_pending (return type changes, so they are
--   dropped and created again with the same grants).

create or replace function private.contract_gratification_pending(p_proposal uuid)
returns boolean
language sql
stable security definer
set search_path to ''
as $function$
  select coalesce((select sum(l.amount * l.multiplier) from public.proposal_commission_lines l
                   join public.proposal_commission_calcs c on c.id = l.calc_id
                   where c.proposal_id = p_proposal and c.status = 'active' and l.component_key = 'gratification' and l.line_kind = 'received'), 0) > 0
     and not exists (select 1 from private.gratification_credit_legacy g where g.proposal_id = p_proposal)
     and not exists (select 1 from public.commission_receipts x
                     where x.proposal_id = p_proposal and x.entry_kind = 'receipt' and x.component_key = 'gratification'
                       and (x.reconciliation = 'matched' or exists (select 1 from public.commission_receipt_resolutions z where z.receipt_id = x.id)))
$function$;
revoke all on function private.contract_gratification_pending(uuid) from public, anon, authenticated;

drop function public.contract_payout_totals(uuid);
create function public.contract_payout_totals(p_org uuid)
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
    cross join lateral private.contract_credit_state(c.proposal_id) s
    where c.organization_id = p_org and c.status = 'active'
    group by c.proposal_id, s.waiting, s.credited, s.paid_on;
end
$function$;
revoke all on function public.contract_payout_totals(uuid) from public, anon;
grant execute on function public.contract_payout_totals(uuid) to authenticated, service_role;

drop function public.contract_credit(uuid);
create function public.contract_credit(p_proposal uuid)
returns table(waiting text, credited numeric, paid_on date, reference text, gratification_pending boolean)
language plpgsql
stable security definer
set search_path to ''
as $function$
declare p public.proposals_v2%rowtype;
begin
  select * into p from public.proposals_v2 where id = p_proposal;
  if p.id is null or auth.uid() is null or not public.has_permission(p.organization_id, 'financeiro.view')
     or not private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by) then raise exception 'not_authorized'; end if;
  return query select s.*, private.contract_gratification_pending(p.id) from private.contract_credit_state(p.id) s;
end
$function$;
revoke all on function public.contract_credit(uuid) from public, anon;
grant execute on function public.contract_credit(uuid) to authenticated, service_role;
