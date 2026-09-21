-- CORBAN OS — Component-aware commissions V1
-- PREPARED ONLY. Requires explicit Human Gate before LIVE apply.
-- Additive. Existing simple payout policies remain compatible; this layer is for intelligent imports with À Vista/Diferido/Bônus/Plástico/Seguro.

create table public.commission_component_types(
  id uuid primary key default gen_random_uuid(),
  tech_key text not null unique,
  name text not null unique check (length(btrim(name)) between 1 and 80),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
insert into public.commission_component_types(tech_key,name,sort_order) values
 ('upfront','À Vista',10),
 ('deferred','Diferido',20),
 ('bonus_1','Bônus',30),
 ('bonus_2','Bônus 2',40),
 ('bonus_3','Bônus 3',50),
 ('plastic','Plástico',60),
 ('insurance_fixed','Seguro fixo',70)
on conflict (tech_key) do nothing;

create table public.commercial_condition_components(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  condition_id uuid not null,
  component_type_id uuid not null references public.commission_component_types(id) on delete restrict,
  value_kind text not null check (value_kind in ('percentage','fixed_brl')),
  received_value numeric(18,8) not null check (received_value>=0),
  calculation_base text,
  source text not null default 'manual' check (source in ('manual','import','upstream','adjustment')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (condition_id,component_type_id),
  unique (organization_id,id),
  foreign key (organization_id,condition_id) references public.commercial_conditions(organization_id,id) on delete restrict
);
create index commercial_condition_components_org_condition_idx on public.commercial_condition_components(organization_id,condition_id);
create index commercial_condition_components_type_idx on public.commercial_condition_components(component_type_id);
create index commercial_condition_components_created_by_idx on public.commercial_condition_components(created_by) where created_by is not null;

create table public.component_payout_policies(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  tech_key text not null default replace(gen_random_uuid()::text,'-',''),
  name text not null check (length(btrim(name)) between 1 and 100),
  org_bank_id uuid,
  org_agreement_id uuid,
  product_table_id uuid,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id,id),
  unique (organization_id,tech_key),
  foreign key (organization_id,org_bank_id) references public.organization_banks(organization_id,id) on delete restrict,
  foreign key (organization_id,org_agreement_id) references public.organization_agreements(organization_id,id) on delete restrict,
  foreign key (organization_id,product_table_id) references public.product_tables(organization_id,id) on delete restrict
);
create index component_payout_policies_bank_idx on public.component_payout_policies(organization_id,org_bank_id) where org_bank_id is not null;
create index component_payout_policies_agreement_idx on public.component_payout_policies(organization_id,org_agreement_id) where org_agreement_id is not null;
create index component_payout_policies_table_idx on public.component_payout_policies(organization_id,product_table_id) where product_table_id is not null;
create index component_payout_policies_created_by_idx on public.component_payout_policies(created_by) where created_by is not null;
create unique index component_payout_policies_scope_name_key
on public.component_payout_policies(
  organization_id,lower(btrim(name)),org_bank_id,org_agreement_id,product_table_id
) nulls not distinct;

create table public.component_payout_policy_versions(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  policy_id uuid not null,
  version integer not null check (version>0),
  discount_pct numeric(9,6) not null default 0 check (discount_pct between 0 and 100),
  effective_from timestamptz not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id,id),
  unique (policy_id,version),
  foreign key (organization_id,policy_id) references public.component_payout_policies(organization_id,id) on delete restrict
);
create index component_payout_policy_versions_created_by_idx on public.component_payout_policy_versions(created_by) where created_by is not null;
create index component_payout_policy_versions_lookup_idx
on public.component_payout_policy_versions(organization_id,policy_id,effective_from desc,version desc);

create table public.component_payout_policy_items(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  version_id uuid not null,
  group_id uuid not null,
  component_type_id uuid not null references public.commission_component_types(id) on delete restrict,
  mode text not null check (mode in ('share_of_received','direct','exclude')),
  share_pct numeric(9,6) check (share_pct between 0 and 100),
  direct_value_kind text check (direct_value_kind in ('percentage','fixed_brl')),
  direct_value numeric(18,8) check (direct_value>=0),
  unique (version_id,group_id,component_type_id),
  foreign key (organization_id,version_id) references public.component_payout_policy_versions(organization_id,id) on delete restrict,
  foreign key (organization_id,group_id) references public.commission_groups(organization_id,id) on delete restrict,
  check (
    (mode='share_of_received' and share_pct is not null and direct_value_kind is null and direct_value is null)
    or (mode='direct' and share_pct is null and direct_value_kind is not null and direct_value is not null)
    or (mode='exclude' and share_pct is null and direct_value_kind is null and direct_value is null)
  )
);
create index component_payout_policy_items_group_idx on public.component_payout_policy_items(organization_id,group_id);
create index component_payout_policy_items_component_idx on public.component_payout_policy_items(component_type_id);

create or replace function public.guard_component_commission_write()
returns trigger language plpgsql set search_path='' as $$
declare v_status text;
begin
  if tg_table_name='commercial_condition_components' then
    select v.status into v_status
    from public.commercial_conditions c
    join public.product_table_versions v on v.id=c.product_table_version_id and v.organization_id=c.organization_id
    where c.id=coalesce(new.condition_id,old.condition_id) and c.organization_id=coalesce(new.organization_id,old.organization_id);
    if v_status is distinct from 'draft' then raise exception 'published_version_components_are_immutable'; end if;
    if current_user in ('authenticated','anon') and current_setting('corban.component_condition_rpc',true) is distinct from 'on' then
      raise exception 'component_condition_write_requires_governed_rpc';
    end if;
    if tg_op='DELETE' then return old; end if;
    if tg_op='INSERT' and current_user in ('authenticated','anon') then new.created_by:=auth.uid(); end if;
    if tg_op='UPDATE' then
      if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id or new.condition_id is distinct from old.condition_id or new.component_type_id is distinct from old.component_type_id or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
        raise exception 'component_identity_is_immutable';
      end if;
      new.updated_at:=now();
    end if;
    return new;
  end if;

  if tg_table_name in ('component_payout_policy_versions','component_payout_policy_items') and tg_op in ('UPDATE','DELETE') then
    raise exception 'component_payout_policy_version_is_immutable';
  end if;
  if tg_table_name in ('component_payout_policy_versions','component_payout_policy_items') and current_user in ('authenticated','anon') and current_setting('corban.component_policy_rpc',true) is distinct from 'on' then
    raise exception 'component_policy_write_requires_governed_rpc';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

create trigger commercial_condition_components_00_guard before insert or update or delete on public.commercial_condition_components for each row execute function public.guard_component_commission_write();
create trigger component_payout_policy_versions_00_guard before insert or update or delete on public.component_payout_policy_versions for each row execute function public.guard_component_commission_write();
create trigger component_payout_policy_items_00_guard before insert or update or delete on public.component_payout_policy_items for each row execute function public.guard_component_commission_write();
create trigger component_payout_policies_00_guard before insert or update on public.component_payout_policies for each row execute function public.guard_org_catalog_row();

create or replace function public.guard_component_payout_policy_scope()
returns trigger language plpgsql set search_path='' as $
declare v_bank uuid; v_agreement uuid;
begin
  if new.product_table_id is not null then
    select r.org_bank_id,r.org_agreement_id into v_bank,v_agreement
    from public.product_tables t
    join public.organization_product_routes r on r.id=t.route_id and r.organization_id=t.organization_id
    where t.id=new.product_table_id and t.organization_id=new.organization_id;
    if not found then raise exception 'component_policy_table_not_found'; end if;
    if new.org_bank_id is not null and new.org_bank_id is distinct from v_bank then raise exception 'component_policy_bank_mismatch'; end if;
    if new.org_agreement_id is not null and new.org_agreement_id is distinct from v_agreement then raise exception 'component_policy_agreement_mismatch'; end if;
  end if;
  return new;
end $;
create trigger component_payout_policies_01_scope before insert or update on public.component_payout_policies for each row execute function public.guard_component_payout_policy_scope();

create or replace function public.replace_commercial_condition_components(p_condition uuid,p_components jsonb)
returns void language plpgsql set search_path='' as $$
declare c public.commercial_conditions%rowtype; it jsonb; v_type uuid; v_kind text; v_value numeric; v_source text; v_seen uuid[]:='{}';
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into c from public.commercial_conditions x where x.id=p_condition;
  if not found then raise exception 'condition_not_found'; end if;
  if not public.has_active_organization_role(c.organization_id,array['admin','manager']) then raise exception 'not_authorized'; end if;
  if not exists(select 1 from public.product_table_versions v where v.id=c.product_table_version_id and v.organization_id=c.organization_id and v.status='draft') then raise exception 'version_not_draft'; end if;
  if p_components is null or jsonb_typeof(p_components)<>'array' or jsonb_array_length(p_components)>50 then raise exception 'invalid_components'; end if;

  perform set_config('corban.component_condition_rpc','on',true);
  delete from public.commercial_condition_components where condition_id=c.id;
  for it in select * from jsonb_array_elements(p_components) loop
    begin
      v_type:=(it->>'component_type_id')::uuid;
      v_kind:=it->>'value_kind';
      v_value:=(it->>'received_value')::numeric;
      v_source:=coalesce(nullif(it->>'source',''),'manual');
    exception when others then
      perform set_config('corban.component_condition_rpc','off',true);
      raise exception 'invalid_components';
    end;
    if v_type is null or v_type=any(v_seen) or v_kind not in ('percentage','fixed_brl') or v_value<0 or v_source not in ('manual','import','upstream','adjustment') or not exists(select 1 from public.commission_component_types t where t.id=v_type and t.is_active) then
      perform set_config('corban.component_condition_rpc','off',true);
      raise exception 'invalid_components';
    end if;
    v_seen:=v_seen||v_type;
    insert into public.commercial_condition_components(organization_id,condition_id,component_type_id,value_kind,received_value,calculation_base,source,created_by)
    values(c.organization_id,c.id,v_type,v_kind,v_value,nullif(it->>'calculation_base',''),v_source,auth.uid());
  end loop;
  perform set_config('corban.component_condition_rpc','off',true);
end $$;

create or replace function public.save_component_payout_policy(
 p_organization uuid,p_name text,p_bank uuid,p_agreement uuid,p_table uuid,p_discount numeric,p_effective_from timestamptz,p_items jsonb,p_policy uuid default null
) returns uuid language plpgsql set search_path='' as $$
declare pol public.component_payout_policies%rowtype; v_org uuid; v_version integer; v_vid uuid; it jsonb; v_group uuid; v_type uuid; v_mode text; v_share numeric; v_direct numeric; v_kind text;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if p_policy is null then
    v_org:=p_organization;
    if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'not_authorized'; end if;
    if p_name is null or length(btrim(p_name)) not between 1 and 100 then raise exception 'invalid_component_policy'; end if;
    if p_bank is not null and not exists(select 1 from public.organization_banks b where b.id=p_bank and b.organization_id=v_org and b.is_active) then raise exception 'invalid_component_policy_scope'; end if;
    if p_agreement is not null and not exists(select 1 from public.organization_agreements a where a.id=p_agreement and a.organization_id=v_org and a.is_active) then raise exception 'invalid_component_policy_scope'; end if;
    if p_table is not null and not exists(select 1 from public.product_tables t where t.id=p_table and t.organization_id=v_org and t.status='active') then raise exception 'invalid_component_policy_scope'; end if;
    perform set_config('corban.payout_rpc','on',true);
    insert into public.component_payout_policies(organization_id,name,org_bank_id,org_agreement_id,product_table_id,created_by)
    values(v_org,btrim(p_name),p_bank,p_agreement,p_table,auth.uid()) returning * into pol;
    perform set_config('corban.payout_rpc','off',true);
  else
    select * into pol from public.component_payout_policies x where x.id=p_policy and x.is_active for update;
    if not found then raise exception 'component_policy_not_found'; end if;
    v_org:=pol.organization_id;
    if not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'not_authorized'; end if;
  end if;

  if p_discount is null or p_discount<0 or p_discount>100 or p_effective_from is null then raise exception 'invalid_component_policy'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)>500 then raise exception 'invalid_component_policy'; end if;

  perform set_config('corban.component_policy_rpc','on',true);
  select coalesce(max(v.version),0)+1 into v_version from public.component_payout_policy_versions v where v.policy_id=pol.id;
  insert into public.component_payout_policy_versions(organization_id,policy_id,version,discount_pct,effective_from,created_by)
  values(v_org,pol.id,v_version,p_discount,p_effective_from,auth.uid()) returning id into v_vid;

  for it in select * from jsonb_array_elements(p_items) loop
    begin
      v_group:=(it->>'group_id')::uuid;
      v_type:=(it->>'component_type_id')::uuid;
      v_mode:=it->>'mode';
      v_share:=case when nullif(it->>'share_pct','') is null then null else (it->>'share_pct')::numeric end;
      v_kind:=nullif(it->>'direct_value_kind','');
      v_direct:=case when nullif(it->>'direct_value','') is null then null else (it->>'direct_value')::numeric end;
    exception when others then
      perform set_config('corban.component_policy_rpc','off',true);
      raise exception 'invalid_component_policy';
    end;
    if not exists(select 1 from public.commission_groups g where g.id=v_group and g.organization_id=v_org and g.is_active)
       or not exists(select 1 from public.commission_component_types t where t.id=v_type and t.is_active)
       or v_mode not in ('share_of_received','direct','exclude')
       or (v_mode='share_of_received' and (v_share is null or v_share<0 or v_share>100 or v_kind is not null or v_direct is not null))
       or (v_mode='direct' and (v_share is not null or v_kind not in ('percentage','fixed_brl') or v_direct is null or v_direct<0))
       or (v_mode='exclude' and (v_share is not null or v_kind is not null or v_direct is not null))
    then
      perform set_config('corban.component_policy_rpc','off',true);
      raise exception 'invalid_component_policy';
    end if;
    insert into public.component_payout_policy_items(organization_id,version_id,group_id,component_type_id,mode,share_pct,direct_value_kind,direct_value)
    values(v_org,v_vid,v_group,v_type,v_mode,v_share,v_kind,v_direct);
  end loop;
  perform set_config('corban.component_policy_rpc','off',true);
  return v_vid;
exception when unique_violation then
  perform set_config('corban.component_policy_rpc','off',true);
  perform set_config('corban.payout_rpc','off',true);
  raise exception 'component_policy_duplicate';
end $$;

create or replace function public.resolve_component_payout_policy(p_organization uuid,p_bank uuid,p_agreement uuid,p_table uuid,p_at timestamptz default now())
returns table(policy_id uuid,version_id uuid,discount_pct numeric,effective_from timestamptz)
language sql stable set search_path='' as $$
with candidate as (
  select p.id policy_id,v.id version_id,v.discount_pct,v.effective_from,v.version,
    (case when p.product_table_id is not null then 4 else 0 end
     + case when p.org_agreement_id is not null then 2 else 0 end
     + case when p.org_bank_id is not null then 1 else 0 end) specificity
  from public.component_payout_policies p
  join public.component_payout_policy_versions v on v.policy_id=p.id and v.organization_id=p.organization_id
  where p.organization_id=p_organization and p.is_active
    and public.has_active_organization_role(p.organization_id,array['admin','manager','supervisor'])
    and (p.org_bank_id is null or p.org_bank_id=p_bank)
    and (p.org_agreement_id is null or p.org_agreement_id=p_agreement)
    and (p.product_table_id is null or p.product_table_id=p_table)
    and v.effective_from<=p_at
)
select c.policy_id,c.version_id,c.discount_pct,c.effective_from
from candidate c
order by c.specificity desc,c.effective_from desc,c.version desc
limit 1
$$;

alter table public.commission_component_types enable row level security;
alter table public.commercial_condition_components enable row level security;
alter table public.component_payout_policies enable row level security;
alter table public.component_payout_policy_versions enable row level security;
alter table public.component_payout_policy_items enable row level security;

revoke all on public.commission_component_types,public.commercial_condition_components,public.component_payout_policies,public.component_payout_policy_versions,public.component_payout_policy_items from public,anon,authenticated;
grant select on public.commission_component_types to authenticated;
grant select,insert,update,delete on public.commercial_condition_components to authenticated;
grant select,insert,update on public.component_payout_policies to authenticated;
grant select,insert on public.component_payout_policy_versions,public.component_payout_policy_items to authenticated;

create policy commission_component_types_read on public.commission_component_types for select to authenticated using (true);
create policy commercial_condition_components_select on public.commercial_condition_components for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy commercial_condition_components_insert on public.commercial_condition_components for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy commercial_condition_components_update on public.commercial_condition_components for update to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager'])) with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy commercial_condition_components_delete on public.commercial_condition_components for delete to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager']));

create policy component_payout_policies_select on public.component_payout_policies for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy component_payout_policies_insert on public.component_payout_policies for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy component_payout_policies_update on public.component_payout_policies for update to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager'])) with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy component_payout_policy_versions_select on public.component_payout_policy_versions for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy component_payout_policy_versions_insert on public.component_payout_policy_versions for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy component_payout_policy_items_select on public.component_payout_policy_items for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy component_payout_policy_items_insert on public.component_payout_policy_items for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager']));

revoke all on function public.guard_component_commission_write() from public,anon,authenticated;
revoke all on function public.guard_component_payout_policy_scope() from public,anon,authenticated;
revoke all on function public.replace_commercial_condition_components(uuid,jsonb) from public,anon;
grant execute on function public.replace_commercial_condition_components(uuid,jsonb) to authenticated;
revoke all on function public.save_component_payout_policy(uuid,text,uuid,uuid,uuid,numeric,timestamptz,jsonb,uuid) from public,anon;
grant execute on function public.save_component_payout_policy(uuid,text,uuid,uuid,uuid,numeric,timestamptz,jsonb,uuid) to authenticated;
revoke all on function public.resolve_component_payout_policy(uuid,uuid,uuid,uuid,timestamptz) from public,anon;
grant execute on function public.resolve_component_payout_policy(uuid,uuid,uuid,uuid,timestamptz) to authenticated;
