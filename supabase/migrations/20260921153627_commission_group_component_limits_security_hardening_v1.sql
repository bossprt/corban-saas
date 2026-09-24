-- CORBAN OS — Commission group component limits security hardening V1
-- Same authorized commission-group component-limit wave.

alter table public.commission_group_component_limits enable row level security;

grant insert,update on public.commission_group_component_limits to authenticated;

drop policy if exists commission_group_component_limits_write_manager
on public.commission_group_component_limits;

create policy commission_group_component_limits_write_manager
on public.commission_group_component_limits
for all to authenticated
using(public.has_active_organization_role(organization_id,array['admin','manager']))
with check(public.has_active_organization_role(organization_id,array['admin','manager']));

create or replace function public.guard_commission_group_component_limit_write()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if current_user in ('authenticated','anon')
     and current_setting('corban.commission_group_config_rpc',true) is distinct from 'on' then
    raise exception 'commission_group_component_write_requires_governed_rpc';
  end if;
  if tg_op='UPDATE' then
    if new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.group_id is distinct from old.group_id
       or new.component_type_id is distinct from old.component_type_id
       or new.created_at is distinct from old.created_at
       or new.created_by is distinct from old.created_by
    then raise exception 'commission_group_component_identity_immutable'; end if;
    new.updated_at:=now();
    new.updated_by:=auth.uid();
  elsif tg_op='INSERT' then
    new.created_by:=auth.uid();
    new.updated_by:=auth.uid();
  end if;
  return new;
end
$$;

drop trigger if exists commission_group_component_limits_00_guard
on public.commission_group_component_limits;

create trigger commission_group_component_limits_00_guard
before insert or update or delete
on public.commission_group_component_limits
for each row execute function public.guard_commission_group_component_limit_write();

create or replace function public.save_commission_group_configuration(
  p_organization uuid,
  p_group uuid,
  p_name text,
  p_items jsonb
)
returns uuid
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_group uuid;
  v_item jsonb;
  v_component uuid;
  v_pct numeric;
  v_seen uuid[]:='{}';
  v_active_count integer;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if p_organization is null
     or not public.has_active_organization_role(p_organization,array['admin','manager']) then
    raise exception 'not_authorized';
  end if;
  if p_name is null or length(btrim(p_name)) not between 1 and 80 then
    raise exception 'invalid_commission_group';
  end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' then
    raise exception 'invalid_commission_group_components';
  end if;

  select count(*) into v_active_count
  from public.commission_component_types t
  where t.is_active;

  if jsonb_array_length(p_items)<>v_active_count then
    raise exception 'commission_group_components_incomplete';
  end if;

  if p_group is null then
    insert into public.commission_groups(
      organization_id,name,kind,calculation_basis
    ) values(
      p_organization,btrim(p_name),'other','percent_of_received_commission'
    ) returning id into v_group;
  else
    select g.id into v_group
    from public.commission_groups g
    where g.id=p_group
      and g.organization_id=p_organization
    for update;
    if v_group is null then raise exception 'commission_group_not_found'; end if;

    update public.commission_groups
    set name=btrim(p_name),
        calculation_basis='percent_of_received_commission',
        updated_at=now()
    where id=v_group;
  end if;

  perform set_config('corban.commission_group_config_rpc','on',true);

  for v_item in select * from jsonb_array_elements(p_items) loop
    begin
      v_component:=(v_item->>'component_type_id')::uuid;
      v_pct:=(v_item->>'max_received_share_pct')::numeric;
    exception when others then
      perform set_config('corban.commission_group_config_rpc','off',true);
      raise exception 'invalid_commission_group_components';
    end;

    if v_component is null or v_pct is null or v_pct<0 or v_pct>100 then
      perform set_config('corban.commission_group_config_rpc','off',true);
      raise exception 'invalid_commission_group_components';
    end if;
    if v_component=any(v_seen) then
      perform set_config('corban.commission_group_config_rpc','off',true);
      raise exception 'duplicate_commission_group_component';
    end if;
    if not exists(
      select 1 from public.commission_component_types t
      where t.id=v_component and t.is_active
    ) then
      perform set_config('corban.commission_group_config_rpc','off',true);
      raise exception 'commission_component_not_found';
    end if;

    v_seen:=v_seen||v_component;

    insert into public.commission_group_component_limits(
      organization_id,group_id,component_type_id,max_received_share_pct
    ) values(
      p_organization,v_group,v_component,v_pct
    )
    on conflict(organization_id,group_id,component_type_id)
    do update set
      max_received_share_pct=excluded.max_received_share_pct;
  end loop;

  perform set_config('corban.commission_group_config_rpc','off',true);

  return v_group;
end
$$;

revoke all on function public.guard_commission_group_component_limit_write() from public,anon,authenticated;
revoke all on function public.save_commission_group_configuration(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.save_commission_group_configuration(uuid,uuid,text,jsonb) to authenticated;
