-- Corban OS V0 domain primitives — STAGED. Apply only after production DDL Human Gate.
create or replace function public.create_customer_with_timeline(
  p_full_name text, p_cpf text, p_phone text default null, p_email text default null, p_original_source text default 'corban_os'
) returns uuid language plpgsql security invoker set search_path=''
as $function$
declare v_org_id uuid; v_customer_id uuid;
begin
  select m.organization_id into v_org_id
  from public.organization_memberships m
  where m.user_id=(select auth.uid()) and m.status='active'
  order by m.created_at asc limit 1;
  if v_org_id is null then raise exception 'active_membership_required'; end if;
  if nullif(btrim(p_full_name),'') is null then raise exception 'full_name_required'; end if;
  if p_cpf !~ '^[0-9]{11}$' then raise exception 'invalid_cpf_format'; end if;

  insert into public.clients(organization_id,full_name,cpf,phone,email,original_source)
  values(v_org_id,btrim(p_full_name),p_cpf,nullif(btrim(p_phone),''),nullif(lower(btrim(p_email)),''),p_original_source)
  returning id into v_customer_id;

  insert into public.customer_timeline_events(organization_id,customer_id,event_type,source,actor_user_id)
  values(v_org_id,v_customer_id,'customer.created','corban_os',(select auth.uid()));
  return v_customer_id;
end;
$function$;
revoke all on function public.create_customer_with_timeline(text,text,text,text,text) from public,anon;
grant execute on function public.create_customer_with_timeline(text,text,text,text,text) to authenticated;
