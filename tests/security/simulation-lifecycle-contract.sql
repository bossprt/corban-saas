-- Simulation lifecycle V1 contract
do $$
declare def text;
begin
  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='close_simulation';
  if def is null then raise exception 'close_simulation_missing'; end if;
  if position('admin' in def)=0 or position('manager' in def)=0 or position('supervisor' in def)=0 then
    raise exception 'close_simulation_rbac_missing';
  end if;
  if position('simulation_not_closable' in def)=0
     or position('simulation_has_proposal' in def)=0
     or position('calculated' in def)=0 then
    raise exception 'close_simulation_guards_missing';
  end if;
  if has_function_privilege('anon','public.close_simulation(uuid,text)','EXECUTE') then
    raise exception 'anon_can_close_simulation';
  end if;
  if not has_function_privilege('authenticated','public.close_simulation(uuid,text)','EXECUTE') then
    raise exception 'authenticated_cannot_call_close_simulation';
  end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='guard_simulation_selected_immutable';
  if def is null or position('selected_simulation_is_terminal' in def)=0 then
    raise exception 'selected_terminal_guard_missing';
  end if;
end $$;
