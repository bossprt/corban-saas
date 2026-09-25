-- POST-APPLY CONTRACT for 20260918_operational_state_machine_v0.sql
do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='transition_operational_case' and p.prosecdef=false
  ) then raise exception 'transition_operational_case must be SECURITY INVOKER'; end if;

  if has_function_privilege('anon','public.transition_operational_case(uuid,text,text)','EXECUTE') then
    raise exception 'anon must not transition operational cases';
  end if;
  if not has_function_privilege('authenticated','public.transition_operational_case(uuid,text,text)','EXECUTE') then
    raise exception 'authenticated RPC execute missing';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid='public.proposals_v2'::regclass and conname='proposals_v2_status_check'
      and pg_get_constraintdef(oid) like '%rejected%'
  ) then raise exception 'proposal rejected terminal state missing'; end if;
end $$;
