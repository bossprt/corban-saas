-- CORBAN OS — Commercial factors V1
-- PREPARED ONLY. Requires explicit Human Gate before LIVE apply.
-- Supports fixed factors and daily factors with immutable/versioned batches and deterministic CRM resolution.

create table public.commercial_factor_profiles (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  tech_key text not null default replace(gen_random_uuid()::text,'-',''),
  name text not null check (length(btrim(name)) between 1 and 120),
  org_bank_id uuid not null,
  org_agreement_id uuid,
  product_table_id uuid,
  contract_type_id uuid references public.contract_types(id) on delete restrict,
  factor_mode text not null check (factor_mode in ('daily','fixed')),
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
create unique index commercial_factor_profiles_scope_key
on public.commercial_factor_profiles(organization_id,org_bank_id,org_agreement_id,product_table_id,contract_type_id,factor_mode) nulls not distinct;
create index commercial_factor_profiles_lookup_idx
on public.commercial_factor_profiles(organization_id,org_bank_id,factor_mode,is_active);

create table public.commercial_factor_batches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  profile_id uuid not null,
  effective_date date not null,
  revision integer not null default 1 check (revision > 0),
  status text not null default 'draft' check (status in ('draft','published')),
  source_kind text not null check (source_kind in ('manual','file','api')),
  import_batch_id uuid references public.import_batches(id) on delete restrict,
  source_note text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  published_at timestamptz,
  unique (organization_id,id),
  unique (profile_id,effective_date,revision),
  foreign key (organization_id,profile_id) references public.commercial_factor_profiles(organization_id,id) on delete restrict
);
create index commercial_factor_batches_resolve_idx
on public.commercial_factor_batches(organization_id,profile_id,effective_date desc,revision desc)
where status='published';

create table public.commercial_factor_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  batch_id uuid not null,
  term_min integer not null check (term_min between 1 and 600),
  term_max integer not null check (term_max between 1 and 600 and term_max>=term_min),
  factor_value numeric(18,12) not null check (factor_value>0),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (organization_id,id),
  unique (batch_id,term_min,term_max),
  foreign key (organization_id,batch_id) references public.commercial_factor_batches(organization_id,id) on delete restrict
);
create index commercial_factor_entries_term_idx on public.commercial_factor_entries(organization_id,batch_id,term_min,term_max);

create or replace function public.guard_factor_profile()
returns trigger language plpgsql set search_path='' as $$
declare v_route record; v_batch_org uuid;
begin
  if tg_op='INSERT' then
    if current_user in ('authenticated','anon') then new.created_by:=auth.uid(); end if;
  else
    if new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.tech_key is distinct from old.tech_key
       or new.created_at is distinct from old.created_at
       or new.created_by is distinct from old.created_by
    then raise exception 'factor_profile_identity_is_immutable'; end if;
    new.updated_at:=now();
  end if;

  if new.product_table_id is not null then
    select r.org_bank_id,r.org_agreement_id
      into v_route
    from public.product_tables t
    join public.organization_product_routes r on r.id=t.route_id and r.organization_id=t.organization_id
    where t.id=new.product_table_id and t.organization_id=new.organization_id;
    if not found then raise exception 'factor_product_table_not_found'; end if;
    if v_route.org_bank_id is distinct from new.org_bank_id then raise exception 'factor_bank_mismatch'; end if;
    if new.org_agreement_id is not null and v_route.org_agreement_id is distinct from new.org_agreement_id then raise exception 'factor_agreement_mismatch'; end if;
  end if;
  return new;
end $$;
create trigger commercial_factor_profiles_00_guard
before insert or update on public.commercial_factor_profiles
for each row execute function public.guard_factor_profile();

create or replace function public.guard_factor_batch()
returns trigger language plpgsql set search_path='' as $$
declare v_org uuid;
begin
  select p.organization_id into v_org from public.commercial_factor_profiles p where p.id=coalesce(new.profile_id,old.profile_id);
  if v_org is distinct from coalesce(new.organization_id,old.organization_id) then raise exception 'factor_profile_cross_tenant'; end if;

  if tg_op='INSERT' then
    if current_user in ('authenticated','anon') and new.status<>'draft' then raise exception 'factor_batch_must_start_draft'; end if;
    if new.import_batch_id is not null then
      select organization_id into v_org from public.import_batches where id=new.import_batch_id;
      if v_org is distinct from new.organization_id then raise exception 'factor_import_batch_cross_tenant'; end if;
    end if;
    if current_user in ('authenticated','anon') then new.created_by:=auth.uid(); end if;
    return new;
  end if;

  if tg_op='DELETE' then
    if old.status='published' then raise exception 'published_factor_batch_is_immutable'; end if;
    return old;
  end if;

  if old.status='published' then raise exception 'published_factor_batch_is_immutable'; end if;
  if new.id is distinct from old.id
     or new.organization_id is distinct from old.organization_id
     or new.profile_id is distinct from old.profile_id
     or new.effective_date is distinct from old.effective_date
     or new.revision is distinct from old.revision
     or new.source_kind is distinct from old.source_kind
     or new.import_batch_id is distinct from old.import_batch_id
     or new.created_by is distinct from old.created_by
     or new.created_at is distinct from old.created_at
  then raise exception 'factor_batch_identity_is_immutable'; end if;
  if old.status='draft' and new.status='published' then
    if current_user in ('authenticated','anon') and current_setting('corban.factor_publish',true) is distinct from 'on' then
      raise exception 'factor_publish_requires_governed_rpc';
    end if;
    new.published_at:=coalesce(new.published_at,now());
  elsif new.status is distinct from old.status then
    raise exception 'invalid_factor_batch_transition';
  end if;
  return new;
end $$;
create trigger commercial_factor_batches_00_guard
before insert or update or delete on public.commercial_factor_batches
for each row execute function public.guard_factor_batch();

create or replace function public.guard_factor_entry()
returns trigger language plpgsql set search_path='' as $$
declare v_status text; v_org uuid;
begin
  select b.status,b.organization_id into v_status,v_org from public.commercial_factor_batches b where b.id=coalesce(new.batch_id,old.batch_id);
  if v_org is distinct from coalesce(new.organization_id,old.organization_id) then raise exception 'factor_batch_cross_tenant'; end if;
  if v_status='published' then raise exception 'published_factor_entries_are_immutable'; end if;
  if tg_op='UPDATE' and (
       new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.batch_id is distinct from old.batch_id
       or new.created_at is distinct from old.created_at
     ) then raise exception 'factor_entry_identity_is_immutable'; end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
create trigger commercial_factor_entries_00_guard
before insert or update or delete on public.commercial_factor_entries
for each row execute function public.guard_factor_entry();

create or replace function public.publish_commercial_factor_batch(p_batch uuid)
returns uuid language plpgsql set search_path='' as $$
declare b public.commercial_factor_batches%rowtype; v_overlap boolean;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into b from public.commercial_factor_batches x where x.id=p_batch for update;
  if not found then raise exception 'factor_batch_not_found'; end if;
  if not public.has_active_organization_role(b.organization_id,array['admin','manager']) then raise exception 'not_authorized'; end if;
  if b.status<>'draft' then raise exception 'factor_batch_not_draft'; end if;
  if not exists(select 1 from public.commercial_factor_entries e where e.batch_id=b.id) then raise exception 'factor_batch_empty'; end if;

  select exists(
    select 1
    from public.commercial_factor_entries a
    join public.commercial_factor_entries c
      on c.batch_id=a.batch_id and c.id<>a.id
     and int4range(a.term_min,a.term_max,'[]') && int4range(c.term_min,c.term_max,'[]')
    where a.batch_id=b.id
  ) into v_overlap;
  if v_overlap then raise exception 'factor_term_ranges_overlap'; end if;

  perform set_config('corban.factor_publish','on',true);
  update public.commercial_factor_batches set status='published',published_at=now() where id=b.id;
  perform set_config('corban.factor_publish','off',true);
  return b.id;
end $$;

-- Resolution rules:
-- 1. Most specific profile wins (table > contract type > agreement).
-- 2. A DAILY factor only resolves for the exact date.
-- 3. FIXED resolves the latest effective date <= requested date.
-- 4. If both exist at equal specificity/date, DAILY wins.
-- 5. Within the selected batch, exactly one term range may match (publish RPC prevents overlap).
create or replace function public.resolve_commercial_factor(
  p_org_bank uuid,
  p_org_agreement uuid,
  p_product_table uuid,
  p_contract_type uuid,
  p_term integer,
  p_on date default current_date
)
returns table(profile_id uuid,batch_id uuid,factor_mode text,effective_date date,factor_value numeric,term_min integer,term_max integer)
language sql stable set search_path='' as $$
with profiles as (
  select p.*,
         (case when p.product_table_id is not null then 8 else 0 end
          + case when p.contract_type_id is not null then 4 else 0 end
          + case when p.org_agreement_id is not null then 2 else 0 end) specificity
  from public.commercial_factor_profiles p
  where p.org_bank_id=p_org_bank
    and p.is_active
    and public.is_active_organization_member(p.organization_id)
    and (p.org_agreement_id is null or p.org_agreement_id=p_org_agreement)
    and (p.product_table_id is null or p.product_table_id=p_product_table)
    and (p.contract_type_id is null or p.contract_type_id=p_contract_type)
), candidates as (
  select p.id profile_id,b.id batch_id,p.factor_mode,b.effective_date,b.revision,p.specificity,
         e.factor_value,e.term_min,e.term_max
  from profiles p
  join lateral (
    select x.*
    from public.commercial_factor_batches x
    where x.profile_id=p.id and x.status='published'
      and ((p.factor_mode='daily' and x.effective_date=p_on)
        or (p.factor_mode='fixed' and x.effective_date<=p_on))
    order by
      case when p.factor_mode='daily' then 1 else 0 end desc,
      x.effective_date desc,x.revision desc
    limit 1
  ) b on true
  join public.commercial_factor_entries e on e.batch_id=b.id
  where p_term between e.term_min and e.term_max
)
select c.profile_id,c.batch_id,c.factor_mode,c.effective_date,c.factor_value,c.term_min,c.term_max
from candidates c
order by c.specificity desc,
         case when c.factor_mode='daily' then 1 else 0 end desc,
         c.effective_date desc,c.revision desc
limit 1
$$;

alter table public.commercial_factor_profiles enable row level security;
alter table public.commercial_factor_batches enable row level security;
alter table public.commercial_factor_entries enable row level security;

revoke all on public.commercial_factor_profiles,public.commercial_factor_batches,public.commercial_factor_entries from public,anon,authenticated;
grant select,insert,update on public.commercial_factor_profiles to authenticated;
grant select,insert,update,delete on public.commercial_factor_batches to authenticated;
grant select,insert,update,delete on public.commercial_factor_entries to authenticated;

-- Factors are pricing inputs used by CRM/simulation, so every active member may read them.
create policy commercial_factor_profiles_select_member on public.commercial_factor_profiles
for select to authenticated using (public.is_active_organization_member(organization_id));
create policy commercial_factor_batches_select_member on public.commercial_factor_batches
for select to authenticated using (public.is_active_organization_member(organization_id));
create policy commercial_factor_entries_select_member on public.commercial_factor_entries
for select to authenticated using (public.is_active_organization_member(organization_id));

create policy commercial_factor_profiles_insert_manager on public.commercial_factor_profiles
for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy commercial_factor_profiles_update_manager on public.commercial_factor_profiles
for update to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager']))
with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy commercial_factor_batches_insert_manager on public.commercial_factor_batches
for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy commercial_factor_batches_update_manager on public.commercial_factor_batches
for update to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager']))
with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy commercial_factor_batches_delete_manager on public.commercial_factor_batches
for delete to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy commercial_factor_entries_insert_manager on public.commercial_factor_entries
for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy commercial_factor_entries_update_manager on public.commercial_factor_entries
for update to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager']))
with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy commercial_factor_entries_delete_manager on public.commercial_factor_entries
for delete to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager']));

revoke all on function public.guard_factor_profile() from public,anon,authenticated;
revoke all on function public.guard_factor_batch() from public,anon,authenticated;
revoke all on function public.guard_factor_entry() from public,anon,authenticated;
revoke all on function public.publish_commercial_factor_batch(uuid) from public,anon;
grant execute on function public.publish_commercial_factor_batch(uuid) to authenticated;
revoke all on function public.resolve_commercial_factor(uuid,uuid,uuid,uuid,integer,date) from public,anon;
grant execute on function public.resolve_commercial_factor(uuid,uuid,uuid,uuid,integer,date) to authenticated;
