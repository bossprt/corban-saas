-- CORBAN OS — Seller commercial profile V1
-- PREPARED ONLY. Requires explicit Human Gate before LIVE apply.
-- Additive: separates Grupo de Vendedor from Grupo de Comissão and models PF/PJ/SUB without rewriting existing commission_groups.

create table public.seller_groups (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  tech_key text not null default replace(gen_random_uuid()::text,'-',''),
  name text not null check (length(btrim(name)) between 1 and 80),
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id,id),
  unique (organization_id,tech_key)
);
create unique index seller_groups_name_key on public.seller_groups(organization_id,lower(btrim(name)));

create table public.commercial_sellers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  tech_key text not null default replace(gen_random_uuid()::text,'-',''),
  name text not null check (length(btrim(name)) between 1 and 160),
  seller_category text not null check (seller_category in ('pf','pj','sub')),
  tax_id text,
  seller_group_id uuid not null,
  commission_group_id uuid not null,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id,id),
  unique (organization_id,tech_key),
  foreign key (organization_id,seller_group_id) references public.seller_groups(organization_id,id) on delete restrict,
  foreign key (organization_id,commission_group_id) references public.commission_groups(organization_id,id) on delete restrict,
  check (tax_id is null or length(regexp_replace(tax_id,'[^0-9]','','g')) between 11 and 14)
);
create unique index commercial_sellers_tax_id_key
  on public.commercial_sellers(organization_id,regexp_replace(tax_id,'[^0-9]','','g'))
  where tax_id is not null;
create index commercial_sellers_seller_group_idx on public.commercial_sellers(organization_id,seller_group_id);
create index commercial_sellers_commission_group_idx on public.commercial_sellers(organization_id,commission_group_id);

-- SUB economics are versioned instead of being a mutable percentage on the seller.
-- sub_share_pct = economic share attributed to the SUB; company share is deterministically 100 - sub_share_pct.
create table public.seller_sub_rule_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  seller_id uuid not null,
  version integer not null check (version > 0),
  component_key text not null default 'all' check (length(btrim(component_key)) between 1 and 80),
  sub_share_pct numeric(9,6) not null check (sub_share_pct between 0 and 100),
  company_share_pct numeric(9,6) generated always as (100 - sub_share_pct) stored,
  effective_from timestamptz not null,
  status text not null default 'draft' check (status in ('draft','published')),
  published_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id,id),
  unique (seller_id,component_key,version),
  unique (seller_id,component_key,effective_from,version),
  foreign key (organization_id,seller_id) references public.commercial_sellers(organization_id,id) on delete restrict
);
create index seller_sub_rule_lookup_idx
  on public.seller_sub_rule_versions(organization_id,seller_id,component_key,effective_from desc,version desc)
  where status='published';

create or replace function public.guard_seller_catalog_row()
returns trigger language plpgsql set search_path='' as $$
begin
  if tg_op='INSERT' then
    if current_user in ('authenticated','anon') then new.created_by:=auth.uid(); end if;
  else
    if new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.tech_key is distinct from old.tech_key
       or new.created_at is distinct from old.created_at
       or new.created_by is distinct from old.created_by
    then raise exception 'seller_identity_is_immutable'; end if;
    new.updated_at:=now();
  end if;
  return new;
end $$;
create trigger seller_groups_00_guard before insert or update on public.seller_groups
for each row execute function public.guard_seller_catalog_row();
create trigger commercial_sellers_00_guard before insert or update on public.commercial_sellers
for each row execute function public.guard_seller_catalog_row();

create or replace function public.guard_seller_sub_rule()
returns trigger language plpgsql set search_path='' as $$
declare v_category text;
begin
  if tg_op='DELETE' then
    if old.status='published' then raise exception 'published_sub_rule_is_immutable'; end if;
    return old;
  end if;

  select s.seller_category into v_category
  from public.commercial_sellers s
  where s.id=new.seller_id and s.organization_id=new.organization_id;

  if v_category is distinct from 'sub' then raise exception 'sub_rule_requires_sub_seller'; end if;

  if tg_op='UPDATE' then
    if old.status='published' then raise exception 'published_sub_rule_is_immutable'; end if;
    if new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.seller_id is distinct from old.seller_id
       or new.version is distinct from old.version
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at
    then raise exception 'sub_rule_identity_is_immutable'; end if;
    if old.status='draft' and new.status='published' then
      if current_user in ('authenticated','anon') and current_setting('corban.seller_sub_publish',true) is distinct from 'on' then
        raise exception 'sub_rule_publish_requires_governed_rpc';
      end if;
      new.published_at:=coalesce(new.published_at,now());
    elsif new.status is distinct from old.status then
      raise exception 'invalid_sub_rule_transition';
    end if;
  elsif current_user in ('authenticated','anon') then
    if new.status<>'draft' then raise exception 'sub_rule_must_start_draft'; end if;
    new.created_by:=auth.uid();
  end if;
  return new;
end $$;
create trigger seller_sub_rule_versions_00_guard
before insert or update or delete on public.seller_sub_rule_versions
for each row execute function public.guard_seller_sub_rule();

create or replace function public.publish_seller_sub_rule(p_rule uuid)
returns uuid language plpgsql set search_path='' as $$
declare r public.seller_sub_rule_versions%rowtype;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into r from public.seller_sub_rule_versions x where x.id=p_rule for update;
  if not found then raise exception 'sub_rule_not_found'; end if;
  if not public.has_active_organization_role(r.organization_id,array['admin','manager']) then raise exception 'not_authorized'; end if;
  if r.status<>'draft' then raise exception 'sub_rule_not_draft'; end if;
  perform set_config('corban.seller_sub_publish','on',true);
  update public.seller_sub_rule_versions set status='published',published_at=now() where id=r.id;
  perform set_config('corban.seller_sub_publish','off',true);
  return r.id;
end $$;

create or replace function public.resolve_seller_sub_rule(p_seller uuid,p_component text default 'all',p_at timestamptz default now())
returns table(rule_version_id uuid,sub_share_pct numeric,company_share_pct numeric)
language sql stable set search_path='' as $$
  select r.id,r.sub_share_pct,r.company_share_pct
  from public.seller_sub_rule_versions r
  join public.commercial_sellers s on s.id=r.seller_id and s.organization_id=r.organization_id
  where r.seller_id=p_seller
    and r.status='published'
    and r.effective_from<=p_at
    and r.component_key in (coalesce(nullif(btrim(p_component),''),'all'),'all')
    and public.is_active_organization_member(r.organization_id)
  order by (r.component_key=coalesce(nullif(btrim(p_component),''),'all')) desc,
           r.effective_from desc,r.version desc
  limit 1
$$;

alter table public.seller_groups enable row level security;
alter table public.commercial_sellers enable row level security;
alter table public.seller_sub_rule_versions enable row level security;

revoke all on public.seller_groups,public.commercial_sellers,public.seller_sub_rule_versions from public,anon,authenticated;
grant select,insert,update on public.seller_groups to authenticated;
grant select,insert,update on public.commercial_sellers to authenticated;
grant select,insert,update,delete on public.seller_sub_rule_versions to authenticated;

create policy seller_groups_select_member on public.seller_groups
for select to authenticated using (public.is_active_organization_member(organization_id));
create policy seller_groups_insert_manager on public.seller_groups
for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy seller_groups_update_manager on public.seller_groups
for update to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager']))
with check (public.has_active_organization_role(organization_id,array['admin','manager']));

-- Seller records can contain CPF/CNPJ: fail closed to supervisor+ for reads.
create policy commercial_sellers_select_supervisor on public.commercial_sellers
for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy commercial_sellers_insert_manager on public.commercial_sellers
for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy commercial_sellers_update_manager on public.commercial_sellers
for update to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager']))
with check (public.has_active_organization_role(organization_id,array['admin','manager']));

create policy seller_sub_rule_versions_select_supervisor on public.seller_sub_rule_versions
for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy seller_sub_rule_versions_insert_manager on public.seller_sub_rule_versions
for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy seller_sub_rule_versions_update_manager on public.seller_sub_rule_versions
for update to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager']))
with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy seller_sub_rule_versions_delete_manager on public.seller_sub_rule_versions
for delete to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager']));

revoke all on function public.guard_seller_catalog_row() from public,anon,authenticated;
revoke all on function public.guard_seller_sub_rule() from public,anon,authenticated;
revoke all on function public.publish_seller_sub_rule(uuid) from public,anon;
grant execute on function public.publish_seller_sub_rule(uuid) to authenticated;
revoke all on function public.resolve_seller_sub_rule(uuid,text,timestamptz) from public,anon;
grant execute on function public.resolve_seller_sub_rule(uuid,text,timestamptz) to authenticated;
