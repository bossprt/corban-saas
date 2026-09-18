-- Atomic bootstrap primitive for first tenant membership.
-- SECURITY DEFINER is intentionally NOT executable by authenticated/anon.
create or replace function public.bootstrap_organization_admin(
  p_user_id uuid,
  p_organization_name text,
  p_organization_document text,
  p_plan_type text default 'founder'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
begin
  if p_user_id is null then raise exception 'user_id_required'; end if;
  if nullif(btrim(p_organization_name), '') is null then raise exception 'organization_name_required'; end if;
  if nullif(btrim(p_organization_document), '') is null then raise exception 'organization_document_required'; end if;
  if not exists (select 1 from auth.users u where u.id = p_user_id) then raise exception 'auth_user_not_found'; end if;
  if exists (select 1 from public.organization_memberships m where m.user_id=p_user_id and m.status='active') then
    raise exception 'user_already_has_active_membership';
  end if;

  insert into public.organizations (name, document, plan_type, is_active)
  values (btrim(p_organization_name), btrim(p_organization_document), p_plan_type, true)
  returning id into v_org_id;

  insert into public.organization_memberships (organization_id,user_id,role,status)
  values (v_org_id,p_user_id,'admin','active');

  -- Transitional compatibility while legacy profiles.organization_id remains.
  insert into public.profiles (id,organization_id,full_name,role)
  select p_user_id,v_org_id,coalesce(nullif(btrim(u.raw_user_meta_data->>'full_name'),''),u.email,'Admin'),'admin'
  from auth.users u where u.id=p_user_id
  on conflict (id) do update
    set organization_id=excluded.organization_id, role='admin';

  return v_org_id;
end;
$$;

revoke all on function public.bootstrap_organization_admin(uuid,text,text,text) from public;
revoke all on function public.bootstrap_organization_admin(uuid,text,text,text) from anon;
revoke all on function public.bootstrap_organization_admin(uuid,text,text,text) from authenticated;
grant execute on function public.bootstrap_organization_admin(uuid,text,text,text) to service_role;
