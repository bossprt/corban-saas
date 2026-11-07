-- Audit 06/11/2026 (Financeiro, CRM, Vendedores). Additive only: new read functions, one bulk write that reuses the existing
-- manual receipt RPC inside one transaction, one lookup for duplicate leads, one service-only e-mail lookup and one index.
--
-- 1. public.commission_receivable: every paid contract with no à vista receipt yet (any age), with the expected à vista
--    commission. Feeds Financeiro > "A receber dos bancos" (the home showed only 20 alerts older than 30 days).
-- 2. public.register_manual_receipts_bulk: several à vista receipts at once. Each item runs public.register_manual_receipt
--    (same matching, duplicate and permission rules as one by one); all in one transaction: one failure, nothing recorded.
-- 3. public.commission_reconciliation: Conciliação por contrato computed in the database: period filter on received_on,
--    paging and totals (the screen fetched the latest 5.000 receipts and filtered the period in memory).
-- 4. public.open_lead_with_cpf: before a manual lead is created, the open lead with the same CPF (only its id when the caller
--    can work it).
-- 5. public.member_emails_service: e-mails of several users in one call, for the service role only (the screens called
--    the Auth API once per person, capped at 200).

-- Money leaves these functions as text (exact decimal), never as a JSON number.

-- 1 ----------------------------------------------------------------------------------------------------------------------
create or replace function public.commission_receivable(p_org uuid, p_source uuid default null, p_min_days integer default 0,
                                                        p_limit integer default 50, p_offset integer default 0)
returns table (proposal_id uuid, reference text, client text, source_id uuid, source_name text, paid_at timestamptz,
               expected_amount text, total_count bigint, total_expected text)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or p_org is null or not public.has_permission(p_org, 'financeiro.view') then raise exception 'not_authorized'; end if;
  if coalesce(p_limit, 0) < 1 or p_limit > 200 or coalesce(p_offset, -1) < 0 or coalesce(p_min_days, -1) < 0 or p_min_days > 3650 then
    raise exception 'invalid_page';
  end if;
  return query
  with paid as (
    select p.id, p.external_proposal_id, p.customer_snapshot->>'full_name' as client,
           case when r.production_origin = 'third_party' and r.org_provider_id is not null then r.org_provider_id else r.org_bank_id end as src,
           coalesce((select max(e.evidenced_at) from public.proposal_status_evidence e where e.proposal_id = p.id and e.canonical_status = 'paid'), p.updated_at) as paid_at
    from public.proposals_v2 p
    left join public.product_table_versions v on v.id = p.product_table_version_id
    left join public.product_tables t on t.id = v.product_table_id
    left join public.organization_product_routes r on r.id = t.route_id
    where p.organization_id = p_org and p.status = 'paid'
      and not exists (select 1 from public.commission_receipts x where x.proposal_id = p.id and x.entry_kind = 'receipt' and x.component_key = 'upfront')
  ), rows as (
    select pd.id, coalesce(pd.external_proposal_id, '') as reference, coalesce(pd.client, '') as client, pd.src,
           coalesce((select b.name from public.organization_banks b where b.id = pd.src), (select o.name from public.organization_providers o where o.id = pd.src), '') as src_name,
           pd.paid_at,
           (select sum(l.amount) from public.proposal_commission_calcs c
              join public.proposal_commission_lines l on l.calc_id = c.id
            where c.proposal_id = pd.id and c.status = 'active' and l.part = 'upfront' and l.line_kind = 'received'
              and l.component_key <> 'gratification') as expected
    from paid pd
    where (p_source is null or pd.src = p_source)
      and pd.paid_at < now() - make_interval(days => p_min_days)
  )
  select x.id, x.reference, x.client, x.src, x.src_name, x.paid_at, x.expected::text,
         count(*) over (), coalesce(sum(x.expected) over (), 0)::text
  from rows x
  order by x.paid_at, x.id
  limit p_limit offset p_offset;
end
$$;
revoke all on function public.commission_receivable(uuid, uuid, integer, integer, integer) from public, anon;
grant execute on function public.commission_receivable(uuid, uuid, integer, integer, integer) to authenticated;

-- 2 ----------------------------------------------------------------------------------------------------------------------
-- p_items: [{"proposal_id": uuid, "amount": "600.00"}, ...] (1 to 100, one per contract). Runs as the caller (RLS and the
-- financeiro.approve check of register_manual_receipt apply to every item). Returns how many receipts were recorded.
create or replace function public.register_manual_receipts_bulk(p_org uuid, p_items jsonb, p_received_on date, p_bank_account uuid, p_note text)
returns integer
language plpgsql
set search_path to ''
as $$
declare
  it jsonb;
  v_proposal uuid;
  v_org uuid;
  v_ref text;
  v_receipt uuid;
  v_receipts uuid[] := '{}';
begin
  if auth.uid() is null or p_org is null or not public.has_permission(p_org, 'financeiro.approve') then raise exception 'not_authorized'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 100 then
    raise exception 'bulk_receipt_invalid';
  end if;
  if (select count(distinct e->>'proposal_id') from jsonb_array_elements(p_items) e) <> jsonb_array_length(p_items) then
    raise exception 'bulk_receipt_invalid';
  end if;
  for it in select e from jsonb_array_elements(p_items) e loop
    if coalesce(it->>'proposal_id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      raise exception 'bulk_receipt_invalid';
    end if;
    v_proposal := (it->>'proposal_id')::uuid;
    select x.organization_id, coalesce(nullif(btrim(x.external_proposal_id), ''), left(x.id::text, 8)) into v_org, v_ref
    from public.proposals_v2 x where x.id = v_proposal;
    if v_org is null or v_org <> p_org then raise exception 'proposal_not_found'; end if;
    begin
      v_receipt := public.register_manual_receipt(v_proposal, 'upfront', it->>'amount', p_received_on, null, p_note);
    exception when others then
      -- The contract that failed travels with the reason; the whole call is undone.
      raise exception 'bulk_receipt_item:%:%', v_ref, sqlerrm;
    end;
    v_receipts := v_receipts || v_receipt;
  end loop;
  if p_bank_account is not null then
    perform public.fin_assign_bank_account(p_org, 'commission_receipt', v_receipts, p_bank_account);
  end if;
  return cardinality(v_receipts);
end
$$;
revoke all on function public.register_manual_receipts_bulk(uuid, jsonb, date, uuid, text) from public, anon;
grant execute on function public.register_manual_receipts_bulk(uuid, jsonb, date, uuid, text) to authenticated;

-- 3 ----------------------------------------------------------------------------------------------------------------------
-- One row per contract with receipts in the period (received_on), or, with p_only_open, per contract with a divergence not
-- yet accepted. Totals cover every row of the filter, not only the page.
create or replace function public.commission_reconciliation(p_org uuid, p_from date default null, p_to date default null,
                                                            p_only_open boolean default false, p_limit integer default 50, p_offset integer default 0)
returns table (proposal_id uuid, reference text, client text, term integer, upfront text, deferred text, deferred_count integer,
               gratification text, chargeback text, net text, open_items jsonb, total_count bigint,
               sum_upfront text, sum_deferred text, sum_gratification text, sum_chargeback text, sum_net text)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or p_org is null or not public.has_permission(p_org, 'financeiro.view') then raise exception 'not_authorized'; end if;
  if coalesce(p_limit, 0) < 1 or p_limit > 200 or coalesce(p_offset, -1) < 0 then raise exception 'invalid_page'; end if;
  return query
  with e as (
    select x.* from public.commission_receipts x
    where x.organization_id = p_org
      and (p_from is null or x.received_on >= p_from)
      and (p_to is null or x.received_on <= p_to)
  ), g as (
    select e.proposal_id as pid,
           coalesce(sum(e.amount) filter (where e.entry_kind <> 'chargeback' and e.component_key is distinct from 'deferred' and e.component_key is distinct from 'gratification'), 0) as up,
           coalesce(sum(e.amount) filter (where e.entry_kind <> 'chargeback' and e.component_key = 'deferred'), 0) as df,
           (count(*) filter (where e.entry_kind <> 'chargeback' and e.component_key = 'deferred'))::integer as dfc,
           coalesce(sum(e.amount) filter (where e.entry_kind <> 'chargeback' and e.component_key = 'gratification'), 0) as gr,
           coalesce(sum(e.amount) filter (where e.entry_kind = 'chargeback'), 0) as cb,
           coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'entry_kind', e.entry_kind, 'component_key', e.component_key,
                                                 'installment_number', e.installment_number, 'amount', e.amount::text, 'expected_amount', e.expected_amount::text)
                              order by e.created_at)
                    filter (where e.reconciliation = 'divergent' and not exists (select 1 from public.commission_receipt_resolutions r where r.receipt_id = e.id)),
                    '[]'::jsonb) as open_items,
           max(e.created_at) as last_at
    from e group by e.proposal_id
  ), f as (
    select g.* from g where not coalesce(p_only_open, false) or jsonb_array_length(g.open_items) > 0
  )
  select f.pid, coalesce(p.external_proposal_id, ''), coalesce(p.customer_snapshot->>'full_name', ''), p.term,
         f.up::text, f.df::text, f.dfc, f.gr::text, f.cb::text, (f.up + f.df + f.gr - f.cb)::text, f.open_items,
         count(*) over (), (sum(f.up) over ())::text, (sum(f.df) over ())::text, (sum(f.gr) over ())::text, (sum(f.cb) over ())::text,
         (sum(f.up + f.df + f.gr - f.cb) over ())::text
  from f left join public.proposals_v2 p on p.id = f.pid
  order by f.last_at desc, f.pid
  limit p_limit offset p_offset;
end
$$;
revoke all on function public.commission_reconciliation(uuid, date, date, boolean, integer, integer) from public, anon;
grant execute on function public.commission_reconciliation(uuid, date, date, boolean, integer, integer) to authenticated;

-- 4 ----------------------------------------------------------------------------------------------------------------------
create index if not exists leads_org_cpf_idx on public.leads (organization_id, cpf) where cpf is not null;

create or replace function public.open_lead_with_cpf(p_org uuid, p_cpf text)
returns table (lead_id uuid, workable boolean)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare v_cpf text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g'); l record;
begin
  if auth.uid() is null or p_org is null or not public.has_permission(p_org, 'leads.create') then raise exception 'lead_forbidden'; end if;
  if length(v_cpf) <> 11 then return; end if;
  select x.id, x.owner_user_id, x.created_by into l from public.leads x
  where x.organization_id = p_org and x.cpf = v_cpf and x.status not in ('won', 'lost')
  order by x.created_at desc limit 1;
  if l.id is null then return; end if;
  if private.lead_workable(p_org, l.owner_user_id, l.created_by) then
    return query select l.id, true;
  else
    -- Someone else's lead: the caller learns only that it exists.
    return query select null::uuid, false;
  end if;
end
$$;
revoke all on function public.open_lead_with_cpf(uuid, text) from public, anon;
grant execute on function public.open_lead_with_cpf(uuid, text) to authenticated;

-- 5 ----------------------------------------------------------------------------------------------------------------------
create or replace function public.member_emails_service(p_ids uuid[])
returns table (user_id uuid, email text)
language sql
stable
security definer
set search_path to ''
as $$
  select u.id, u.email::text from auth.users u
  where u.id = any (p_ids[1:1000]) and u.email is not null
$$;
revoke all on function public.member_emails_service(uuid[]) from public, anon, authenticated;
grant execute on function public.member_emails_service(uuid[]) to service_role;
