-- Organization direct-write privilege hardening V1 contract
do $$
begin
  if has_table_privilege('authenticated','public.organizations','INSERT')
     or has_table_privilege('authenticated','public.organizations','UPDATE')
     or has_table_privilege('authenticated','public.organizations','DELETE') then
    raise exception 'authenticated_can_mutate_organizations';
  end if;

  if has_table_privilege('anon','public.organizations','INSERT')
     or has_table_privilege('anon','public.organizations','UPDATE')
     or has_table_privilege('anon','public.organizations','DELETE') then
    raise exception 'anon_can_mutate_organizations';
  end if;

  if not has_table_privilege('authenticated','public.organizations','SELECT') then
    raise exception 'authenticated_lost_organization_read';
  end if;

  if has_function_privilege('authenticated','public.bootstrap_organization_admin(uuid,uuid,text,text,text)','EXECUTE') then
    raise exception 'tenant_can_bootstrap_organization';
  end if;
end $$;
