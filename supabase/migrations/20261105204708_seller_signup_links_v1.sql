-- Seller registration link per seller group (owner approval 05/11/2026, ADR-0072).
-- The administrator (or manager) creates one link per group and sends it; whoever opens it fills the same seller form
-- without logging in. The group comes from the link and cannot be chosen. What arrives waits in a queue: nothing becomes
-- a seller until the administrator opens the request, checks it in the seller form and approves (save_seller runs then,
-- with every rule it already has). Approved or refused, the request keeps only name and document; the rest is erased.
-- Anonymous callers reach only seller_signup_link_info and seller_signup_submit, both by the link token.

create table public.seller_signup_links (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  commission_group_id uuid not null,
  token text not null unique check (length(token) between 20 and 64),
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, commission_group_id),
  foreign key (organization_id, commission_group_id) references public.commission_groups(organization_id, id) on delete restrict
);

create table public.seller_signup_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  link_id uuid not null,
  commission_group_id uuid not null,
  name text not null check (length(name) between 1 and 160),
  tax_id text not null check (tax_id ~ '^(\d{11}|\d{14})$'),
  payload jsonb check (payload is null or (jsonb_typeof(payload) = 'object' and pg_column_size(payload) <= 32768)),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  seller_id uuid,
  decided_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, link_id) references public.seller_signup_links(organization_id, id) on delete restrict,
  foreign key (organization_id, commission_group_id) references public.commission_groups(organization_id, id) on delete restrict,
  foreign key (organization_id, seller_id) references public.commercial_sellers(organization_id, id) on delete restrict,
  check ((status = 'pending') = (payload is not null)),
  check ((status = 'approved') = (seller_id is not null)),
  check ((status = 'pending') = (decided_at is null))
);
create index seller_signup_requests_link_recent on public.seller_signup_requests (link_id, created_at desc);
create unique index seller_signup_requests_pending_doc on public.seller_signup_requests (organization_id, tax_id) where status = 'pending';

alter table public.seller_signup_links enable row level security;
alter table public.seller_signup_requests enable row level security;
revoke all on public.seller_signup_links, public.seller_signup_requests from public, anon, authenticated;
grant select on public.seller_signup_links, public.seller_signup_requests to authenticated;
create policy seller_signup_links_select on public.seller_signup_links for select to authenticated
  using (public.has_active_organization_role(organization_id, array['admin', 'manager']));
create policy seller_signup_requests_select on public.seller_signup_requests for select to authenticated
  using (public.has_active_organization_role(organization_id, array['admin', 'manager']));

-- Create the group's link, or a new token for it (the old link stops working at once). Returns the token.
create or replace function public.seller_signup_link_new(p_org uuid, p_group uuid)
returns text language plpgsql security definer set search_path to '' as $$
declare v_token text := translate(encode(extensions.gen_random_bytes(18), 'base64'), '+/=', '-_');
begin
  if auth.uid() is null or p_org is null or not public.has_active_organization_role(p_org, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  if not exists (select 1 from public.commission_groups g where g.id = p_group and g.organization_id = p_org and g.is_active) then raise exception 'seller_group_invalid'; end if;
  insert into public.seller_signup_links (organization_id, commission_group_id, token, created_by)
  values (p_org, p_group, v_token, auth.uid())
  on conflict (organization_id, commission_group_id) do update set token = excluded.token, is_active = true, updated_at = now();
  return v_token;
end $$;

create or replace function public.seller_signup_link_set_active(p_link uuid, p_active boolean)
returns void language plpgsql security definer set search_path to '' as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.seller_signup_links where id = p_link;
  if auth.uid() is null or v_org is null or not public.has_active_organization_role(v_org, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  update public.seller_signup_links set is_active = coalesce(p_active, false), updated_at = now() where id = p_link;
end $$;

-- What the public page shows: company and group names, only while the link is on (and the company and group active).
create or replace function public.seller_signup_link_info(p_token text)
returns table (organization_name text, group_name text) language sql stable security definer set search_path to '' as $$
  select o.name, g.name
  from public.seller_signup_links l
  join public.organizations o on o.id = l.organization_id
  join public.commission_groups g on g.id = l.commission_group_id
  where l.token = p_token and l.is_active and g.is_active and o.is_active
$$;

-- The public form. Checks what a person must type (name, CPF/CNPJ, category, mobile, e-mail) and the size of the rest;
-- the full rules run on approval. The same document still waiting replaces its earlier request instead of piling up.
-- At most 30 requests per link per hour and 200 waiting per company, so a leaked link cannot flood the queue.
create or replace function public.seller_signup_submit(p_token text, p_data jsonb)
returns void language plpgsql security definer set search_path to '' as $$
declare
  l public.seller_signup_links%rowtype;
  p jsonb := coalesce(p_data->'profile', '{}'::jsonb);
  v_name text := btrim(coalesce(p_data->>'name', ''));
  v_tax text := regexp_replace(coalesce(p_data->>'tax_id', ''), '\D', '', 'g');
  v_email text := lower(btrim(coalesce(p->>'email', '')));
begin
  select * into l from public.seller_signup_links where token = p_token;
  if l.id is null or not l.is_active
     or not exists (select 1 from public.commission_groups g where g.id = l.commission_group_id and g.is_active)
     or not exists (select 1 from public.organizations o where o.id = l.organization_id and o.is_active) then
    raise exception 'signup_link_closed';
  end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' or pg_column_size(p_data) > 32768
     or jsonb_typeof(coalesce(p_data->'accounts', '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_data->'accounts', '[]'::jsonb)) > 5
     or jsonb_typeof(coalesce(p_data->'contacts', '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_data->'contacts', '[]'::jsonb)) > 10
     or jsonb_typeof(p) <> 'object' then
    raise exception 'signup_invalid';
  end if;
  if length(v_name) not between 1 and 160 then raise exception 'seller_name_required'; end if;
  if not ((length(v_tax) = 11 and private.is_valid_cpf(v_tax)) or (length(v_tax) = 14 and private.is_valid_cnpj(v_tax))) then raise exception 'seller_tax_id_invalid'; end if;
  if coalesce(p_data->>'category', '') not in ('pf', 'pj', 'sub') then raise exception 'seller_category_invalid'; end if;
  if private.normalize_phone(coalesce(p->>'mobile', '')) is null then raise exception 'seller_mobile_required'; end if;
  if v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' or length(v_email) > 160 then raise exception 'seller_email_required'; end if;
  if (select count(*) from public.seller_signup_requests r where r.link_id = l.id and r.created_at > now() - interval '1 hour') >= 30
     or (select count(*) from public.seller_signup_requests r where r.organization_id = l.organization_id and r.status = 'pending') >= 200 then
    raise exception 'signup_rate_limited';
  end if;
  -- Only the fields of the form travel; group, branch, internal and payment rules are the administrator's.
  p_data := jsonb_build_object('name', v_name, 'tax_id', v_tax, 'category', p_data->>'category', 'profile', p,
    'accounts', coalesce(p_data->'accounts', '[]'::jsonb), 'contacts', coalesce(p_data->'contacts', '[]'::jsonb));
  insert into public.seller_signup_requests (organization_id, link_id, commission_group_id, name, tax_id, payload)
  values (l.organization_id, l.id, l.commission_group_id, v_name, v_tax, p_data)
  on conflict (organization_id, tax_id) where status = 'pending'
  do update set link_id = excluded.link_id, commission_group_id = excluded.commission_group_id, name = excluded.name,
    payload = excluded.payload, created_at = now(), updated_at = now();
end $$;

-- Approval: the administrator saved the request in the seller form. save_seller applies all its rules; the request is
-- closed in the same transaction and its personal data erased (it now lives in the seller record).
create or replace function public.seller_signup_approve(p_request uuid, p_data jsonb)
returns uuid language plpgsql security definer set search_path to '' as $$
declare r public.seller_signup_requests%rowtype; v_seller uuid;
begin
  select * into r from public.seller_signup_requests where id = p_request for update;
  if auth.uid() is null or r.id is null or not public.has_active_organization_role(r.organization_id, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  if r.status <> 'pending' then raise exception 'signup_already_decided'; end if;
  v_seller := public.save_seller(r.organization_id, null, p_data);
  update public.seller_signup_requests set status = 'approved', seller_id = v_seller, payload = null,
    decided_by = auth.uid(), decided_at = now(), updated_at = now() where id = p_request;
  return v_seller;
end $$;

create or replace function public.seller_signup_reject(p_request uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare r public.seller_signup_requests%rowtype;
begin
  select * into r from public.seller_signup_requests where id = p_request for update;
  if auth.uid() is null or r.id is null or not public.has_active_organization_role(r.organization_id, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  if r.status <> 'pending' then raise exception 'signup_already_decided'; end if;
  update public.seller_signup_requests set status = 'rejected', payload = null,
    decided_by = auth.uid(), decided_at = now(), updated_at = now() where id = p_request;
end $$;

revoke all on function public.seller_signup_link_new(uuid, uuid), public.seller_signup_link_set_active(uuid, boolean),
  public.seller_signup_link_info(text), public.seller_signup_submit(text, jsonb),
  public.seller_signup_approve(uuid, jsonb), public.seller_signup_reject(uuid) from public, anon, authenticated;
grant execute on function public.seller_signup_link_new(uuid, uuid), public.seller_signup_link_set_active(uuid, boolean),
  public.seller_signup_approve(uuid, jsonb), public.seller_signup_reject(uuid) to authenticated;
grant execute on function public.seller_signup_link_info(text), public.seller_signup_submit(text, jsonb) to anon, authenticated;

-- Found by the grants hygiene test on 05/11/2026: the receipts table (20261105003843) kept the default privileges.
-- Reads and writes were already blocked by RLS (one select policy, financeiro.view); the grants now match it.
revoke all on public.fin_entry_receipts from anon;
revoke insert, update, delete, truncate, references, trigger on public.fin_entry_receipts from authenticated;
