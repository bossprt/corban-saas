-- CORBAN OS — Commission group component limits V1
-- PREPARED ONLY. Requires explicit Human Gate before LIVE apply.
-- A commission group defines, per received component, how much of 100% received may enter payout calculation.

create table public.commission_group_component_limits(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  group_id uuid not null,
  component_type_id uuid not null references public.commission_component_types(id) on delete restrict,
  max_received_share_pct numeric(9,6) not null
    check(max_received_share_pct>=0 and max_received_share_pct<=100),
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,id),
  unique(organization_id,group_id,component_type_id),
  foreign key(organization_id,group_id)
    references public.commission_groups(organization_id,id)
    on delete restrict
);

alter table public.commission_groups
  alter column calculation_basis set default 'percent_of_received_commission';

update public.commission_groups
set calculation_basis='percent_of_received_commission'
where calculation_basis<>'percent_of_received_commission';

create or replace function public.guard_commission_group_received_basis()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if new.calculation_basis is distinct from 'percent_of_received_commission' then
    raise exception 'commission_group_received_basis_required';
  end if;
  return new;
end
$$;

drop trigger if exists commission_groups_20_received_basis_guard on public.commission_groups;
create trigger commission_groups_20_received_basis_guard
before insert or update of calculation_basis on public.commission_groups
for each row execute function public.guard_commission_group_received_basis();

create or replace function public.save_commission_group_configuration(
  p_organization uuid,
  p_group uuid,
  p_name text,
  p_items jsonb
)
returns uuid
language plpgsql
security definer
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

  for v_item in select * from jsonb_array_elements(p_items) loop
    begin
      v_component:=(v_item->>'component_type_id')::uuid;
      v_pct:=(v_item->>'max_received_share_pct')::numeric;
    exception when others then
      raise exception 'invalid_commission_group_components';
    end;

    if v_component is null or v_pct is null or v_pct<0 or v_pct>100 then
      raise exception 'invalid_commission_group_components';
    end if;
    if v_component=any(v_seen) then
      raise exception 'duplicate_commission_group_component';
    end if;
    if not exists(
      select 1 from public.commission_component_types t
      where t.id=v_component and t.is_active
    ) then
      raise exception 'commission_component_not_found';
    end if;

    v_seen:=v_seen||v_component;

    insert into public.commission_group_component_limits(
      organization_id,group_id,component_type_id,max_received_share_pct,created_by,updated_by
    ) values(
      p_organization,v_group,v_component,v_pct,auth.uid(),auth.uid()
    )
    on conflict(organization_id,group_id,component_type_id)
    do update set
      max_received_share_pct=excluded.max_received_share_pct,
      updated_by=auth.uid(),
      updated_at=now();
  end loop;

  return v_group;
exception when unique_violation then
  raise exception 'commission_group_already_exists';
end
$$;

create or replace function public.guard_component_payout_group_limit()
returns trigger
language plpgsql
set search_path=''
as $$
declare
  v_limit numeric;
begin
  if new.mode='direct' then
    raise exception 'commission_group_direct_component_mode_forbidden';
  end if;

  select l.max_received_share_pct into v_limit
  from public.commission_group_component_limits l
  join public.commission_component_types t
    on t.id=l.component_type_id and t.is_active
  where l.organization_id=new.organization_id
    and l.group_id=new.group_id
    and l.component_type_id=new.component_type_id;

  if v_limit is null then
    raise exception 'commission_group_component_not_configured';
  end if;

  if new.mode='exclude' then
    if v_limit<>0 then
      raise exception 'commission_group_component_mode_mismatch';
    end if;
    return new;
  end if;

  if new.mode<>'share_of_received'
     or new.share_pct is null
     or new.share_pct<0
     or new.share_pct>v_limit then
    raise exception 'commission_group_component_share_exceeds_limit';
  end if;

  return new;
end
$$;

drop trigger if exists component_payout_policy_items_15_group_limit
on public.component_payout_policy_items;

create trigger component_payout_policy_items_15_group_limit
before insert or update of group_id,component_type_id,mode,share_pct,direct_value_kind,direct_value
on public.component_payout_policy_items
for each row execute function public.guard_component_payout_group_limit();

alter table public.commission_group_component_limits enable row level security;

revoke all on public.commission_group_component_limits from public,anon,authenticated;
grant select on public.commission_group_component_limits to authenticated;

create policy commission_group_component_limits_select_member
on public.commission_group_component_limits
for select to authenticated
using(public.is_active_organization_member(organization_id));

revoke all on function public.guard_commission_group_received_basis() from public,anon,authenticated;
revoke all on function public.guard_component_payout_group_limit() from public,anon,authenticated;
revoke all on function public.save_commission_group_configuration(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.save_commission_group_configuration(uuid,uuid,text,jsonb) to authenticated;
