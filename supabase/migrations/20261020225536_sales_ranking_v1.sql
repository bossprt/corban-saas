-- Sales ranking and board (owner, 20/10/2026, plan phase 2; option 1: the whole team sees the ranking).
-- One call per screen: per seller, the contracts paid to the client in the period (count and released amount, the same
-- "produção paga" as the owner's dashboard) and the contracts typed in the period (created, not cancelled), the month goal
-- of the seller's user, the team totals, the funnel (leads, contracts typed, contracts paid) and the last contracts paid.
-- Only production: no commission, payout or rule amount of anyone is returned. Seen by the company's internal team
-- (leads.view, relatorios.view or financeiro.view); an external broker (portal) does not see it.

create or replace function public.sales_ranking(p_org uuid, p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
set timezone to 'America/Sao_Paulo'
as $$
declare v jsonb;
begin
  if auth.uid() is null or not public.is_active_organization_member(p_org)
     or not (public.has_permission(p_org, 'leads.view') or public.has_permission(p_org, 'relatorios.view') or public.has_permission(p_org, 'financeiro.view')) then
    raise exception 'not_authorized';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 400 then raise exception 'invalid_period'; end if;

  with paid as (
    select p.seller_id, coalesce(p.released_amount, p.requested_amount, 0) as amount, p.paid_to_client_on, p.updated_at
    from public.proposals_v2 p
    where p.organization_id = p_org and p.status = 'paid' and p.paid_to_client_on between p_from and p_to
  ),
  typed as (
    select p.seller_id, coalesce(p.released_amount, p.requested_amount, 0) as amount
    from public.proposals_v2 p
    where p.organization_id = p_org and p.status not in ('cancelled', 'rejected')
      and (p.created_at at time zone 'America/Sao_Paulo')::date between p_from and p_to
  ),
  goals as (
    select s.id as seller_id, g.target_amount
    from public.commercial_sellers s
    join public.seller_goals g on g.organization_id = s.organization_id and g.user_id = s.user_id
     and g.month = date_trunc('month', p_to)::date
    where s.organization_id = p_org and s.user_id is not null
  ),
  people as (
    select s.id, s.name,
           (select count(*) from paid x where x.seller_id = s.id) as paid_count,
           (select coalesce(sum(x.amount), 0) from paid x where x.seller_id = s.id) as paid_amount,
           (select count(*) from typed x where x.seller_id = s.id) as typed_count,
           (select coalesce(sum(x.amount), 0) from typed x where x.seller_id = s.id) as typed_amount,
           (select g.target_amount from goals g where g.seller_id = s.id) as goal
    from public.commercial_sellers s
    where s.organization_id = p_org
  )
  select jsonb_build_object(
    'sellers', coalesce((select jsonb_agg(jsonb_build_object('seller_id', id, 'name', name, 'paid_count', paid_count, 'paid_amount', paid_amount::text,
                                                             'typed_count', typed_count, 'typed_amount', typed_amount::text, 'goal', goal::text)
                                          order by paid_amount desc, typed_amount desc, name)
                         from people where paid_count > 0 or typed_count > 0 or goal is not null), '[]'::jsonb),
    'totals', jsonb_build_object(
      'paid_count', (select count(*) from paid), 'paid_amount', (select coalesce(sum(amount), 0) from paid)::text,
      'typed_count', (select count(*) from typed), 'typed_amount', (select coalesce(sum(amount), 0) from typed)::text,
      'no_seller_paid', (select count(*) from paid where seller_id is null),
      'goal', (select coalesce(sum(target_amount), 0) from goals)::text),
    'funnel', jsonb_build_object(
      'leads', (select count(*) from public.leads l where l.organization_id = p_org and (l.created_at at time zone 'America/Sao_Paulo')::date between p_from and p_to),
      'typed', (select count(*) from typed),
      'paid', (select count(*) from paid)),
    'last_paid', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(s.name, 'Sem vendedor'), 'amount', x.amount::text, 'paid_on', x.paid_to_client_on) order by x.paid_to_client_on desc, x.updated_at desc)
                           from (select * from paid order by paid_to_client_on desc, updated_at desc limit 5) x
                           left join public.commercial_sellers s on s.id = x.seller_id), '[]'::jsonb)
  ) into v;
  return v;
end
$$;
revoke all on function public.sales_ranking(uuid, date, date) from public, anon;
grant execute on function public.sales_ranking(uuid, date, date) to authenticated;
