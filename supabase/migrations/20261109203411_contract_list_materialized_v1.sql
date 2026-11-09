-- Contratos > filtro Banco (dono, 09/11/2026): with a bank filter the planner guessed 1 row and re-ran the payout
-- totals / commission-line CTEs inside a nested loop, so contract_list hit the statement timeout ("Não foi possível
-- carregar os contratos"). Same body as 20261107044229, only po and ln are MATERIALIZED (computed once). No behavior change.

create or replace function public.contract_list(p_org uuid, p_filters jsonb default '{}'::jsonb, p_limit integer default 25, p_page integer default 1)
returns jsonb
language plpgsql
stable security invoker
set search_path = ''
as $$
declare
  v_fin boolean := auth.uid() is not null and public.has_permission(p_org, 'financeiro.view');
  v_f jsonb := coalesce(p_filters, '{}'::jsonb);
  v_q text := nullif(public.fold_text(btrim(coalesce(v_f->>'q', ''))), '');
  v_sit text := nullif(v_f->>'situacao', '');
  v_show_closed boolean := coalesce(v_f->>'encerradas', '') = '1' or coalesce(v_f->>'situacao', '') in ('cancelled', 'rejected');
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 200);
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  return (
    with po as materialized (
      -- Gated: contract_payout_totals refuses callers without financeiro.view, so it only runs for finance.
      select * from public.contract_payout_totals(p_org) where v_fin
    ),
    ln as materialized (
      select k.proposal_id,
             sum(l.amount * l.multiplier) filter (where l.line_kind = 'received') as received,
             sum(l.amount * l.multiplier) filter (where l.line_kind = 'company') as company,
             sum(l.amount * l.multiplier) filter (where l.line_kind = 'originator') as originator
      from public.proposal_commission_lines l
      join public.proposal_commission_calcs k on k.id = l.calc_id
      where v_fin and k.organization_id = p_org and k.status = 'active'
      group by k.proposal_id
    ),
    base as (
      select p.id, p.external_proposal_id, p.status, p.requested_amount, p.released_amount, p.term,
             p.customer_snapshot->>'full_name' as full_name, p.customer_snapshot->>'cpf' as cpf,
             p.customer_id, p.seller_id, p.created_at, p.paid_to_client_on, p.formalization, p.physical_received_at, p.physical_bank_at,
             oc.id as case_id, oc.current_stage_id, oc.canonical_state, oc.pendency_reason,
             case when oc.canonical_state in ('digitization_queue', 'digitizing', 'submitted', 'pending_external', 'approved', 'paid', 'rejected', 'cancelled') then oc.canonical_state
                  when p.status = 'digitization' then 'digitization_queue'
                  when p.status in ('draft', 'documents_pending', 'ready_for_digitization', 'digitization_queue', 'digitizing', 'submitted', 'pending_external', 'approved', 'paid', 'rejected', 'cancelled') then p.status
             end as situation,
             r.org_bank_id as bank_id, r.org_agreement_id as agreement_id, t.name as table_name,
             s.commission_group_id,
             k.id as calc_id, k.seller_id as calc_seller_id, k.group_id as calc_group_id,
             ln.proposal_id is not null as has_calc, ln.received, coalesce(ln.company, 0) as company, ln.originator,
             po.proposal_id is not null as has_po, po.rule_amount, po.payable, coalesce(po.overridden, false) as overridden, po.waiting, po.paid_on,
             coalesce(po.gratification_pending, false) and (po.waiting is null or po.waiting = 'no_payout') as grat_pending
      from public.proposals_v2 p
      left join public.operational_cases oc on oc.proposal_id = p.id
      left join public.product_table_versions v on v.id = p.product_table_version_id
      left join public.product_tables t on t.id = v.product_table_id
      left join public.organization_product_routes r on r.id = t.route_id
      left join public.commercial_sellers s on s.id = p.seller_id
      left join public.proposal_commission_calcs k on v_fin and k.proposal_id = p.id and k.status = 'active'
      left join ln on ln.proposal_id = p.id
      left join po on po.proposal_id = p.id
      where p.organization_id = p_org
    ),
    x as (
      select b.*,
             b.calc_id is not null and (b.calc_seller_id is distinct from b.seller_id
               or b.calc_group_id is distinct from (case when b.seller_id is not null then b.commission_group_id end)) as stale,
             case when not b.has_po then ''
                  when b.grat_pending and (b.paid_on is not null or b.waiting = 'no_payout') then 'aguardando'
                  when b.paid_on is not null then 'pago'
                  when b.waiting = 'no_payout' then 'sem_repasse'
                  when b.waiting is not null then 'aguardando'
                  else 'creditado' end as repasse
      from base b
    ),
    m as (
      select * from x
      where (nullif(v_f->>'de', '') is null or (x.created_at at time zone 'America/Sao_Paulo')::date >= (v_f->>'de')::date)
        and (nullif(v_f->>'ate', '') is null or (x.created_at at time zone 'America/Sao_Paulo')::date <= (v_f->>'ate')::date)
        and (nullif(v_f->>'banco', '') is null or (v_f->>'banco' = 'none' and x.bank_id is null) or x.bank_id::text = v_f->>'banco')
        and (nullif(v_f->>'convenio', '') is null or x.agreement_id::text = v_f->>'convenio')
        and (nullif(v_f->>'vendedor', '') is null or (v_f->>'vendedor' = 'none' and x.seller_id is null) or x.seller_id::text = v_f->>'vendedor')
        and (nullif(v_f->>'grupo', '') is null or x.commission_group_id::text = v_f->>'grupo')
        and (v_sit is null or x.situation = v_sit)
        and (nullif(v_f->>'cliente', '') is null or x.customer_id::text = v_f->>'cliente')
        and (nullif(v_f->>'comissao', '') is null or (v_f->>'comissao' = 'calculada') = x.has_calc)
        and (nullif(v_f->>'alterado', '') is null or x.overridden)
        and (nullif(v_f->>'desatualizado', '') is null or x.stale)
        and (nullif(v_f->>'pago_de', '') is null or x.paid_to_client_on >= (v_f->>'pago_de')::date)
        and (nullif(v_f->>'pago_ate', '') is null or x.paid_to_client_on <= (v_f->>'pago_ate')::date)
        and (nullif(v_f->>'repasse', '') is null or x.repasse = v_f->>'repasse'
             or (v_f->>'repasse' = 'concluido' and x.repasse in ('pago', 'sem_repasse'))
             or (v_f->>'repasse' = 'gratificacao' and x.grat_pending)
             or (v_f->>'repasse' = 'banco' and x.waiting = 'bank')
             or (v_f->>'repasse' = 'divergente' and x.waiting = 'divergent'))
        and (v_q is null or strpos(public.fold_text(x.full_name), v_q) > 0 or strpos(public.fold_text(x.external_proposal_id), v_q) > 0)
    ),
    vis as (select * from m where v_show_closed or m.status not in ('cancelled', 'rejected')),
    cnt as (select count(*)::integer as n from vis),
    pg as (select greatest(1, least(coalesce(p_page, 1), ceil(greatest(cnt.n, 1)::numeric / v_limit)::integer)) as page from cnt),
    rows_page as (
      select vis.* from vis order by vis.created_at desc, vis.id
      offset ((select page from pg) - 1) * v_limit limit v_limit
    )
    select jsonb_build_object(
      'total', (select n from cnt),
      'page', (select page from pg),
      'hidden_closed', (select count(*) from m where not v_show_closed and m.status in ('cancelled', 'rejected')),
      'any', exists (select 1 from public.proposals_v2 a where a.organization_id = p_org),
      'sums', (select jsonb_build_object(
          'requested', coalesce(sum(requested_amount), 0)::text,
          'released', coalesce(sum(released_amount), 0)::text,
          'received', coalesce(sum(received) filter (where has_calc), 0)::text,
          'payable', coalesce(sum(payable) filter (where has_calc and has_po), 0)::text,
          'gain', coalesce(sum(rule_amount - payable) filter (where has_calc and has_po), 0)::text,
          'margin', coalesce(sum(company + rule_amount - payable) filter (where has_calc and has_po), 0)::text
        ) from vis),
      'rows', coalesce((select jsonb_agg(jsonb_build_object(
          'id', r.id, 'external_proposal_id', r.external_proposal_id, 'status', r.status,
          'requested_amount', r.requested_amount::text, 'released_amount', r.released_amount::text, 'term', r.term,
          'full_name', r.full_name, 'cpf', r.cpf, 'customer_id', r.customer_id, 'seller_id', r.seller_id, 'created_at', r.created_at,
          'paid_to_client_on', r.paid_to_client_on, 'formalization', r.formalization, 'physical_received_at', r.physical_received_at, 'physical_bank_at', r.physical_bank_at,
          'case_id', r.case_id, 'current_stage_id', r.current_stage_id, 'canonical_state', r.canonical_state, 'pendency_reason', r.pendency_reason, 'situation', r.situation,
          'bank_id', r.bank_id, 'agreement_id', r.agreement_id, 'table_name', r.table_name, 'commission_group_id', r.commission_group_id,
          'has_calc', r.has_calc, 'received', r.received::text, 'company', r.company::text, 'originator', r.originator::text,
          'has_po', r.has_po, 'rule_amount', r.rule_amount::text, 'payable', r.payable::text, 'overridden', r.overridden, 'waiting', r.waiting,
          'paid_on', r.paid_on, 'grat_pending', r.grat_pending, 'stale', r.stale, 'repasse', r.repasse
        ) order by r.created_at desc, r.id) from rows_page r), '[]'::jsonb)
    )
  );
end
$$;
revoke all on function public.contract_list(uuid, jsonb, integer, integer) from public, anon;
grant execute on function public.contract_list(uuid, jsonb, integer, integer) to authenticated;
