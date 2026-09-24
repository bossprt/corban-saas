-- F2 step 1: one client per CPF, contact history (approved by the owner, MAPA-OPERACAO §2).
--
-- A client is identified by CPF inside a company. Registering a CPF that already exists never creates a second
-- client and never fails: the existing client is recognized, the new phone and e-mail enter its contact history and
-- become the main ones, and the timeline records who brought it and from where. The original name is kept.
-- The seller who hits an existing client of someone else learns only that it exists, not its data (scope rules apply).

-- Helpers ------------------------------------------------------------------------------------------------------

create or replace function private.is_valid_cpf(p_cpf text)
returns boolean
language plpgsql
immutable
set search_path to ''
as $$
declare s int; d1 int; d2 int; i int;
begin
  if p_cpf is null or p_cpf !~ '^[0-9]{11}$' or p_cpf ~ '^(.)\1{10}$' then return false; end if;
  s := 0;
  for i in 1..9 loop s := s + substr(p_cpf, i, 1)::int * (11 - i); end loop;
  d1 := case when s % 11 < 2 then 0 else 11 - s % 11 end;
  s := 0;
  for i in 1..10 loop s := s + substr(p_cpf, i, 1)::int * (12 - i); end loop;
  d2 := case when s % 11 < 2 then 0 else 11 - s % 11 end;
  return substr(p_cpf, 10, 1)::int = d1 and substr(p_cpf, 11, 1)::int = d2;
end
$$;

-- Brazilian phone to digits with country code (55 + area + number); null when it cannot be a phone.
create or replace function private.normalize_phone(p_phone text)
returns text
language sql
immutable
set search_path to ''
as $$
  select case
    when d ~ '^55[0-9]{10,11}$' then d
    when d ~ '^[0-9]{10,11}$' then '55' || d
    else null end
  from (select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') d) x
$$;

revoke all on function private.is_valid_cpf(text) from public;
revoke all on function private.normalize_phone(text) from public;
grant execute on function private.is_valid_cpf(text) to authenticated;
grant execute on function private.normalize_phone(text) to authenticated;

-- Contact history ------------------------------------------------------------------------------------------------

create table public.client_contacts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  customer_id uuid not null,
  kind text not null check (kind in ('phone','email')),
  value text not null check (length(value) between 3 and 254),
  is_primary boolean not null default false,
  source text not null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  created_by uuid,
  foreign key (organization_id, customer_id) references public.clients (organization_id, id) on delete cascade,
  unique (organization_id, customer_id, kind, value)
);

create index client_contacts_lookup_idx on public.client_contacts (organization_id, kind, value);
create unique index client_contacts_one_primary_idx on public.client_contacts (organization_id, customer_id, kind) where is_primary;

alter table public.client_contacts enable row level security;
revoke all on table public.client_contacts from anon, authenticated;
grant select on table public.client_contacts to authenticated;

create policy client_contacts_select_member on public.client_contacts
  for select to authenticated using (public.is_active_organization_member(organization_id));
create policy client_contacts_scope on public.client_contacts as restrictive for all to authenticated
  using (exists (select 1 from public.clients c where c.id = customer_id))
  with check (exists (select 1 from public.clients c where c.id = customer_id));

-- Existing main phone, secondary phone and e-mail become history.
insert into public.client_contacts (organization_id, customer_id, kind, value, is_primary, source, first_seen_at, last_seen_at)
select c.organization_id, c.id, 'phone', private.normalize_phone(c.phone), true, coalesce(c.original_source, 'legado'), c.created_at, c.created_at
from public.clients c where private.normalize_phone(c.phone) is not null
on conflict do nothing;
insert into public.client_contacts (organization_id, customer_id, kind, value, is_primary, source, first_seen_at, last_seen_at)
select c.organization_id, c.id, 'phone', private.normalize_phone(c.secondary_phone), false, coalesce(c.original_source, 'legado'), c.created_at, c.created_at
from public.clients c where private.normalize_phone(c.secondary_phone) is not null
on conflict do nothing;
insert into public.client_contacts (organization_id, customer_id, kind, value, is_primary, source, first_seen_at, last_seen_at)
select c.organization_id, c.id, 'email', lower(btrim(c.email)), true, coalesce(c.original_source, 'legado'), c.created_at, c.created_at
from public.clients c where nullif(btrim(c.email), '') is not null
on conflict do nothing;

-- Core identity upsert (no authorization: callers check it) ------------------------------------------------------

create or replace function private.record_client_contact(p_org uuid, p_customer uuid, p_kind text, p_value text, p_source text)
returns boolean
language plpgsql
security definer
set search_path to ''
as $$
declare v_new boolean;
begin
  if p_value is null then return false; end if;
  update public.client_contacts set is_primary = false
  where organization_id = p_org and customer_id = p_customer and kind = p_kind and is_primary and value <> p_value;
  insert into public.client_contacts (organization_id, customer_id, kind, value, is_primary, source, created_by)
  values (p_org, p_customer, p_kind, p_value, true, p_source, auth.uid())
  on conflict (organization_id, customer_id, kind, value)
  do update set is_primary = true, last_seen_at = now()
  returning (xmax = 0) into v_new;
  return v_new;
end
$$;

revoke all on function private.record_client_contact(uuid, uuid, text, text, text) from public, anon, authenticated;

create or replace function private.upsert_client_core(
  p_org uuid, p_cpf text, p_full_name text, p_phone text, p_email text, p_source text, p_owner uuid
)
returns table (client_id uuid, created boolean)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_id uuid;
  v_phone text := private.normalize_phone(p_phone);
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_source text := coalesce(nullif(btrim(p_source), ''), 'corban');
  v_phone_new boolean := false;
  v_email_new boolean := false;
begin
  if not private.is_valid_cpf(p_cpf) then raise exception 'invalid_cpf'; end if;
  if v_email is not null and v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'invalid_email'; end if;

  -- Serialize concurrent registrations of the same CPF in the same company.
  perform pg_advisory_xact_lock(hashtext(p_org::text || ':' || p_cpf));
  select c.id into v_id from public.clients c where c.organization_id = p_org and c.cpf = p_cpf and c.deleted_at is null for update;

  perform set_config('corban.timeline_rpc', 'on', true);
  if v_id is null then
    if nullif(btrim(coalesce(p_full_name, '')), '') is null or length(btrim(p_full_name)) < 3 then raise exception 'full_name_required'; end if;
    insert into public.clients (organization_id, full_name, cpf, phone, email, original_source, owner_user_id)
    values (p_org, btrim(p_full_name), p_cpf, v_phone, v_email, v_source, coalesce(p_owner, auth.uid()))
    returning id into v_id;
    perform private.record_client_contact(p_org, v_id, 'phone', v_phone, v_source);
    perform private.record_client_contact(p_org, v_id, 'email', v_email, v_source);
    insert into public.customer_timeline_events (organization_id, customer_id, event_type, source, actor_user_id, metadata)
    values (p_org, v_id, 'customer.created', v_source, auth.uid(), '{}'::jsonb);
    perform set_config('corban.timeline_rpc', 'off', true);
    return query select v_id, true;
    return;
  end if;

  v_phone_new := private.record_client_contact(p_org, v_id, 'phone', v_phone, v_source);
  v_email_new := private.record_client_contact(p_org, v_id, 'email', v_email, v_source);
  update public.clients
  set phone = coalesce(v_phone, phone), email = coalesce(v_email, email), updated_at = now()
  where id = v_id;
  insert into public.customer_timeline_events (organization_id, customer_id, event_type, source, actor_user_id, metadata)
  values (p_org, v_id, 'customer.recognized', v_source, auth.uid(),
          jsonb_build_object('new_phone', v_phone_new, 'new_email', v_email_new, 'name_given', nullif(btrim(coalesce(p_full_name, '')), '')));
  perform set_config('corban.timeline_rpc', 'off', true);
  return query select v_id, false;
end
$$;

revoke all on function private.upsert_client_core(uuid, text, text, text, text, text, uuid) from public, anon, authenticated;

-- Public entry point for signed-in users ---------------------------------------------------------------------------

create or replace function public.upsert_client(p_org uuid, p_cpf text, p_full_name text, p_phone text, p_email text, p_source text default 'manual')
returns table (client_id uuid, created boolean, visible boolean)
language plpgsql
security definer
set search_path to ''
as $$
declare v_id uuid; v_created boolean;
begin
  if auth.uid() is null or not public.is_active_organization_member(p_org) then raise exception 'not_authorized'; end if;
  if not public.has_permission(p_org, 'clientes.create') then raise exception 'not_authorized'; end if;
  select u.client_id, u.created into v_id, v_created from private.upsert_client_core(p_org, p_cpf, p_full_name, p_phone, p_email, p_source, null) u;
  return query select v_id, v_created, private.can_see_client_row(p_org, v_id, (select c.owner_user_id from public.clients c where c.id = v_id));
end
$$;

revoke all on function public.upsert_client(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.upsert_client(uuid, text, text, text, text, text) to authenticated;

-- Lead conversion goes through the same identity rule ---------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.lead_write(p_org uuid, p_lead uuid, p_op text, p_args jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_user uuid:=(select auth.uid());v_role text;l public.leads%rowtype;v_id uuid;v_customer uuid;
begin
 v_role:=private.caller_role_in(p_org);
 if v_user is null or v_role is null then raise exception 'lead_forbidden'; end if;
 if p_op='create' then
  insert into public.leads(organization_id,channel,campaign,external_ref,full_name,phone,email,owner_user_id,metadata,created_by)
  values(p_org,p_args->>'channel',nullif(p_args->>'campaign',''),nullif(p_args->>'external_ref',''),p_args->>'full_name',nullif(p_args->>'phone',''),nullif(lower(p_args->>'email'),''),v_user,coalesce(p_args->'metadata','{}'::jsonb),v_user)
  on conflict (organization_id,channel,external_ref) where external_ref is not null do nothing returning id into v_id;
  if v_id is null then select id into v_id from public.leads where organization_id=p_org and channel=p_args->>'channel' and external_ref=nullif(p_args->>'external_ref',''); return v_id; end if;
  insert into public.lead_events(organization_id,lead_id,event_type,to_status,actor_user_id,detail) values(p_org,v_id,'created','new',v_user,jsonb_build_object('channel',p_args->>'channel','campaign',p_args->>'campaign'));
  return v_id;
 end if;
 select * into l from public.leads where id=p_lead and organization_id=p_org for update;
 if not found then raise exception 'lead_forbidden'; end if;
 if p_op='status' then
  if l.status in ('converted') then raise exception 'lead_already_converted'; end if;
  if p_args->>'status' not in ('new','contacted','qualified','lost') then raise exception 'invalid_lead_status'; end if;
  if p_args->>'status'='lost' and nullif(btrim(p_args->>'lost_reason'),'') is null then raise exception 'lost_reason_required'; end if;
  if l.status='lost' and p_args->>'status'<>'lost' and v_role not in ('admin','manager','supervisor') then raise exception 'lead_reactivation_requires_supervisor'; end if;
  update public.leads set status=p_args->>'status',lost_reason=case when p_args->>'status'='lost' then p_args->>'lost_reason' else null end,updated_at=now() where id=l.id;
  insert into public.lead_events(organization_id,lead_id,event_type,from_status,to_status,actor_user_id,detail) values(p_org,l.id,case when l.status='lost' then 'reactivated' else 'status_changed' end,l.status,p_args->>'status',v_user,jsonb_build_object('lost_reason',p_args->>'lost_reason'));
  return l.id;
 end if;
 if p_op='convert' then
  if l.status='converted' then return l.customer_id; end if;
  if l.status='lost' then raise exception 'lost_lead_must_be_reactivated'; end if;
  if p_args->>'cpf' !~ '^[0-9]{11}$' then raise exception 'invalid_cpf_format'; end if;
  -- Same identity rule as manual registration: an existing CPF is recognized, never duplicated.
  select u.client_id into v_customer from private.upsert_client_core(p_org,p_args->>'cpf',l.full_name,l.phone,l.email,'lead:'||l.channel,coalesce(l.owner_user_id,v_user)) u;
  update public.leads set status='converted',customer_id=v_customer,converted_at=now(),updated_at=now() where id=l.id;
  insert into public.lead_events(organization_id,lead_id,event_type,from_status,to_status,actor_user_id,detail) values(p_org,l.id,'converted',l.status,'converted',v_user,jsonb_build_object('customer_id',v_customer));
  return v_customer;
 end if;
 raise exception 'invalid_lead_operation';
end $function$;
