-- MVP closure security/schema contract. Must return zero rows.
select 'rpc_exposure' as failure,p.proname
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in ('generate_import_match_candidates','publish_financial_fact_from_import_decision','freeze_proposal_commercial_route','publish_expected_commission','confirm_proposal_paid_from_import')
and (p.prosecdef or has_function_privilege('anon',p.oid,'EXECUTE') or not has_function_privilege('authenticated',p.oid,'EXECUTE'))
union all
select 'component_snapshot_rls',c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname='proposal_commercial_component_snapshots' and not c.relrowsecurity
union all
select 'missing_route_guard','proposal_commercial_snapshots'
where not exists(select 1 from pg_trigger where tgname='proposal_commercial_route_insert_guard' and tgenabled='O')
union all
select 'missing_component_guard','proposal_commercial_component_snapshots'
where not exists(select 1 from pg_trigger where tgname='proposal_component_route_insert_guard' and tgenabled='O')
union all
select 'missing_paid_evidence_guard','guard_proposal_status_transition'
where position('paid_requires_confirmed_operational_evidence' in coalesce((select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='guard_proposal_status_transition' limit 1),''))=0;