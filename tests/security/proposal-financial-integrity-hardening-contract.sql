-- Proposal/financial integrity hardening V1 contract.
do $$
declare
  def text;
begin
  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='freeze_proposal_commercial_route';
  if def is null then raise exception 'freeze_route_missing'; end if;
  if position('effective_from' in def)=0
     or position('effective_until' in def)=0
     or position('published_effective_rule_for_channel_table_required' in def)=0 then
    raise exception 'commission_rule_effective_window_not_enforced';
  end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.relnamespace
  where n.nspname='public' and p.proname='publish_expected_commission';
  if def is null or position('refresh_financial_reconciliation' in def)=0 then
    raise exception 'expected_commission_does_not_refresh_reconciliation';
  end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='publish_financial_evidence_event';
  if def is null
     or position('commission_reported' in def)=0
     or position('payment_received' in def)=0
     or position('refresh_financial_reconciliation' in def)=0 then
    raise exception 'evidence_does_not_refresh_reconciliation';
  end if;

  if has_table_privilege('authenticated','public.proposal_commercial_snapshots','UPDATE')
     or has_table_privilege('authenticated','public.proposal_commercial_snapshots','DELETE') then
    raise exception 'commercial_snapshot_mutation_privilege_present';
  end if;

  if has_table_privilege('authenticated','public.proposal_commercial_component_snapshots','UPDATE')
     or has_table_privilege('authenticated','public.proposal_commercial_component_snapshots','DELETE') then
    raise exception 'component_snapshot_mutation_privilege_present';
  end if;

  if has_function_privilege('anon','public.freeze_proposal_commercial_route(uuid,uuid,uuid,uuid)','EXECUTE')
     or has_function_privilege('anon','public.publish_expected_commission(uuid)','EXECUTE')
     or has_function_privilege('anon','public.publish_financial_evidence_event(uuid,text,text,numeric,timestamptz,text,text,uuid,uuid,uuid)','EXECUTE') then
    raise exception 'anon_execute_financial_rpc';
  end if;
end $$;
