-- Cash flow starts from the bank balance and keeps old overdue entries in sight (owner approval 04/11/2026).
-- Read only: no data changes.
--  opening: what the company bank accounts held at the start of p_from (opening balance plus what was settled in each
--           account from its opening date until the day before). An account opened later counts its opening balance here
--           too, so the year ends on the real balance. Null with a branch filter: the bank balance belongs to the company.
--  overdue_in / overdue_out: entries still open that were due before p_from (they are outside the year's months).
create or replace function public.fin_cash_flow_opening(p_org uuid, p_from date, p_branch uuid default null)
returns table (opening numeric, overdue_in numeric, overdue_out numeric)
language plpgsql
stable
security definer
set search_path to ''
set timezone to 'America/Sao_Paulo'
as $$
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.view') then raise exception 'not_authorized'; end if;
  return query
    select
      case when p_branch is null then
        coalesce((select sum(k.opening_balance) from public.fin_bank_accounts k where k.organization_id = p_org), 0)
        + coalesce((select sum(case when e.direction = 'in' then e.amount + e.interest - e.discount else -(e.amount + e.interest - e.discount) end)
                    from public.fin_entries e join public.fin_bank_accounts k on k.id = e.bank_account_id
                    where e.organization_id = p_org and e.status = 'settled' and e.settled_on >= k.opening_on and e.settled_on < p_from), 0)
      end,
      coalesce(sum(x.amount) filter (where x.direction = 'in'), 0),
      coalesce(sum(x.amount) filter (where x.direction = 'out'), 0)
    from public.fin_entries x join public.fin_chart_accounts a on a.id = x.account_id
    where x.organization_id = p_org and x.status = 'open' and a.kind <> 'transfer' and x.due_on < p_from
      and (p_branch is null or x.branch_id = p_branch);
end
$$;
revoke all on function public.fin_cash_flow_opening(uuid, date, uuid) from public, anon;
grant execute on function public.fin_cash_flow_opening(uuid, date, uuid) to authenticated;
