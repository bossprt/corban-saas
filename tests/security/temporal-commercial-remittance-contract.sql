do $$
declare def text;
begin
  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='create_simulation_for_condition';
  if def is null
     or position('effective_until' in def)=0
     or position('v_now<x.effective_until' in def)=0
  then raise exception 'simulation_not_temporally_guarded'; end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='create_proposal_from_simulation';
  if def is null
     or position('pricing_effective_at' in def)=0
     or position('v.status in (''published'',''superseded'')' in def)=0
  then raise exception 'proposal_does_not_preserve_original_pricing'; end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='apply_smart_commercial_remittance';
  if def is null
     or position('partial' in def)=0
     or position('complete' in def)=0
     or position('retired_absent_versions' in def)=0
  then raise exception 'remittance_semantics_missing'; end if;
end $$;