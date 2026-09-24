-- F2 step 2: public API v1, first endpoint POST /api/v1/leads (approved by the owner, MAPA-OPERACAO §10).
--
-- Keys belong to one company, carry scopes and are stored only as a SHA-256 hash; the plain key is shown once.
-- The API route calls public.api_ingest_lead with the service role; the function authenticates the key itself,
-- so the route never decides which company a request belongs to.
-- Also fixes leads_customer_uidx: a client who comes back through a new lead must be convertible again.

-- A returning client may have many leads over time.
drop index if exists public.leads_customer_uidx;
create index if not exists leads_customer_idx on public.leads (organization_id, customer_id) where customer_id is not null;

-- Keys -----------------------------------------------------------------------------------------------------------

create table public.api_keys (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  name text not null check (length(btrim(name)) between 2 and 60),
  prefix text not null,
  key_hash text not null unique,
  scopes text[] not null check (array_length(scopes, 1) >= 1 and scopes <@ array['leads.write']),
  rate_limit_per_minute int not null default 60 check (rate_limit_per_minute between 1 and 600),
  created_by uuid,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz,
  revoked_by uuid
);

create index api_keys_org_idx on public.api_keys (organization_id);

alter table public.api_keys enable row level security;
revoke all on table public.api_keys from anon, authenticated;
-- Administrators see their company's keys, never the hash.
grant select (id, organization_id, name, prefix, scopes, rate_limit_per_minute, created_by, created_at, last_used_at, revoked_at, revoked_by) on public.api_keys to authenticated;

create policy api_keys_select_admin on public.api_keys for select to authenticated
  using (private.caller_role_in(organization_id) = 'admin');

-- One row per API call, for rate limiting and audit. No payload and no personal data.
create table public.api_request_log (
  id bigint generated always as identity primary key,
  api_key_id uuid not null references public.api_keys(id) on delete restrict,
  organization_id uuid not null,
  endpoint text not null,
  outcome text not null,
  occurred_at timestamptz not null default now()
);

create index api_request_log_rate_idx on public.api_request_log (api_key_id, occurred_at desc);

alter table public.api_request_log enable row level security;
revoke all on table public.api_request_log from anon, authenticated;
grant select on public.api_request_log to authenticated;
create policy api_request_log_select_admin on public.api_request_log for select to authenticated
  using (private.caller_role_in(organization_id) = 'admin');

alter table public.organization_admin_events drop constraint if exists organization_admin_events_event_type_check;
alter table public.organization_admin_events add constraint organization_admin_events_event_type_check check (event_type = any (array[
  'invite_created','invite_revoked','invite_accepted','member_role_changed','member_deactivated','member_reactivated',
  'seller_created','seller_user_binding_updated','seller_supervision_updated','role_created','role_updated','member_access_role_changed',
  'member_hierarchy_changed','api_key_created','api_key_revoked'
]));

-- Creates a key and returns it in clear text exactly once. Administrators only.
create or replace function public.create_api_key(p_org uuid, p_name text, p_scopes text[])
returns table (id uuid, api_key text, prefix text)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_key text;
  v_id uuid;
begin
  if auth.uid() is null or private.caller_role_in(p_org) is distinct from 'admin' then raise exception 'not_authorized'; end if;
  if p_name is null or length(btrim(p_name)) not between 2 and 60 then raise exception 'invalid_api_key_name'; end if;
  if p_scopes is null or array_length(p_scopes, 1) is null or not p_scopes <@ array['leads.write'] then raise exception 'invalid_api_key_scopes'; end if;
  v_key := 'ck_live_' || translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
  insert into public.api_keys (organization_id, name, prefix, key_hash, scopes, created_by)
  values (p_org, btrim(p_name), left(v_key, 16), encode(extensions.digest(v_key, 'sha256'), 'hex'), p_scopes, auth.uid())
  returning api_keys.id into v_id;
  perform set_config('corban.membership_rpc', 'on', true);
  insert into public.organization_admin_events (organization_id, actor_user_id, event_type, details)
  values (p_org, auth.uid(), 'api_key_created', jsonb_build_object('api_key_id', v_id, 'name', btrim(p_name), 'scopes', p_scopes));
  perform set_config('corban.membership_rpc', 'off', true);
  return query select v_id, v_key, left(v_key, 16);
end
$$;

revoke all on function public.create_api_key(uuid, text, text[]) from public, anon;
grant execute on function public.create_api_key(uuid, text, text[]) to authenticated;

create or replace function public.revoke_api_key(p_key_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare v_org uuid;
begin
  select k.organization_id into v_org from public.api_keys k where k.id = p_key_id and k.revoked_at is null for update;
  if v_org is null then raise exception 'api_key_not_found'; end if;
  if auth.uid() is null or private.caller_role_in(v_org) is distinct from 'admin' then raise exception 'not_authorized'; end if;
  update public.api_keys set revoked_at = now(), revoked_by = auth.uid() where id = p_key_id;
  perform set_config('corban.membership_rpc', 'on', true);
  insert into public.organization_admin_events (organization_id, actor_user_id, event_type, details)
  values (v_org, auth.uid(), 'api_key_revoked', jsonb_build_object('api_key_id', p_key_id));
  perform set_config('corban.membership_rpc', 'off', true);
end
$$;

revoke all on function public.revoke_api_key(uuid) from public, anon;
grant execute on function public.revoke_api_key(uuid) to authenticated;

-- Ingestion ---------------------------------------------------------------------------------------------------------

-- Authenticates the key, applies scope, modules and rate limit, then creates (or returns) the lead.
-- Returns a JSON object; the error field is a stable code the route maps to an HTTP status.
create or replace function public.api_ingest_lead(p_key text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  k public.api_keys%rowtype;
  v_recent int;
  v_name text := btrim(coalesce(p_payload->>'full_name', ''));
  v_phone text := private.normalize_phone(p_payload->>'phone');
  v_email text := nullif(lower(btrim(coalesce(p_payload->>'email', ''))), '');
  v_cpf text := nullif(regexp_replace(coalesce(p_payload->>'cpf', ''), '\D', '', 'g'), '');
  v_ref text := nullif(btrim(coalesce(p_payload->>'external_ref', '')), '');
  v_campaign text := nullif(btrim(coalesce(p_payload->>'campaign', '')), '');
  v_meta jsonb := coalesce(p_payload->'metadata', '{}'::jsonb);
  v_client uuid;
  v_lead uuid;
  v_status text;
  v_duplicate boolean := false;
begin
  select * into k from public.api_keys where key_hash = encode(extensions.digest(coalesce(p_key, ''), 'sha256'), 'hex');
  if not found or k.revoked_at is not null then return jsonb_build_object('error', 'invalid_api_key'); end if;

  select count(*) into v_recent from public.api_request_log l where l.api_key_id = k.id and l.occurred_at > now() - interval '1 minute';
  if v_recent >= k.rate_limit_per_minute then
    insert into public.api_request_log (api_key_id, organization_id, endpoint, outcome) values (k.id, k.organization_id, 'leads.create', 'rate_limited');
    return jsonb_build_object('error', 'rate_limited');
  end if;
  update public.api_keys set last_used_at = now() where id = k.id;

  if not ('leads.write' = any (k.scopes)) then
    insert into public.api_request_log (api_key_id, organization_id, endpoint, outcome) values (k.id, k.organization_id, 'leads.create', 'forbidden');
    return jsonb_build_object('error', 'insufficient_scope');
  end if;
  if not exists (select 1 from public.organization_modules m where m.organization_id = k.organization_id and m.module_key = 'api' and m.enabled)
     or not exists (select 1 from public.organization_modules m where m.organization_id = k.organization_id and m.module_key = 'leads' and m.enabled)
     or not exists (select 1 from public.organizations o where o.id = k.organization_id and coalesce(o.is_active, true)) then
    insert into public.api_request_log (api_key_id, organization_id, endpoint, outcome) values (k.id, k.organization_id, 'leads.create', 'module_disabled');
    return jsonb_build_object('error', 'module_disabled');
  end if;

  if length(v_name) not between 2 and 200 then return jsonb_build_object('error', 'invalid_full_name'); end if;
  if v_phone is null and v_email is null then return jsonb_build_object('error', 'phone_or_email_required'); end if;
  if v_email is not null and v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then return jsonb_build_object('error', 'invalid_email'); end if;
  if v_cpf is not null and not private.is_valid_cpf(v_cpf) then return jsonb_build_object('error', 'invalid_cpf'); end if;
  if v_ref is not null and length(v_ref) > 120 then return jsonb_build_object('error', 'invalid_external_ref'); end if;
  if jsonb_typeof(v_meta) <> 'object' or octet_length(v_meta::text) > 6000 then return jsonb_build_object('error', 'invalid_metadata'); end if;

  -- Same external reference: the lead already exists (idempotent retry).
  if v_ref is not null then
    select l.id, l.status into v_lead, v_status from public.leads l where l.organization_id = k.organization_id and l.channel = 'api' and l.external_ref = v_ref;
    if v_lead is not null then
      insert into public.api_request_log (api_key_id, organization_id, endpoint, outcome) values (k.id, k.organization_id, 'leads.create', 'duplicate');
      return jsonb_build_object('id', v_lead, 'status', v_status, 'duplicate', true);
    end if;
  end if;

  -- An open lead with the same phone: return it and note the new contact.
  if v_phone is not null then
    select l.id, l.status into v_lead, v_status from public.leads l
    where l.organization_id = k.organization_id and l.status in ('new','contacted','qualified') and private.normalize_phone(l.phone) = v_phone
    order by l.created_at limit 1;
    if v_lead is not null then
      insert into public.lead_events (organization_id, lead_id, event_type, actor_user_id, detail)
      values (k.organization_id, v_lead, 'note', null, jsonb_build_object('kind', 'api_contact_again', 'campaign', v_campaign, 'external_ref', v_ref));
      insert into public.api_request_log (api_key_id, organization_id, endpoint, outcome) values (k.id, k.organization_id, 'leads.create', 'duplicate');
      return jsonb_build_object('id', v_lead, 'status', v_status, 'duplicate', true);
    end if;
  end if;

  -- Existing client by CPF, else by phone: link for the operator; the client record is not changed here.
  if v_cpf is not null then
    select c.id into v_client from public.clients c where c.organization_id = k.organization_id and c.cpf = v_cpf and c.deleted_at is null;
  end if;
  if v_client is null and v_phone is not null then
    select x.customer_id into v_client from public.client_contacts x
    where x.organization_id = k.organization_id and x.kind = 'phone' and x.value = v_phone
    order by x.last_seen_at desc limit 1;
  end if;

  insert into public.leads (organization_id, status, channel, campaign, external_ref, full_name, phone, email, metadata)
  values (k.organization_id, 'new', 'api', v_campaign, v_ref, v_name, v_phone, v_email,
          v_meta || jsonb_build_object('api_key_id', k.id) || case when v_cpf is not null then jsonb_build_object('cpf', v_cpf) else '{}'::jsonb end
                 || case when v_client is not null then jsonb_build_object('matched_client_id', v_client) else '{}'::jsonb end)
  returning id into v_lead;
  insert into public.lead_events (organization_id, lead_id, event_type, to_status, actor_user_id, detail)
  values (k.organization_id, v_lead, 'created', 'new', null, jsonb_build_object('channel', 'api', 'campaign', v_campaign, 'api_key_id', k.id));
  insert into public.api_request_log (api_key_id, organization_id, endpoint, outcome) values (k.id, k.organization_id, 'leads.create', 'created');
  return jsonb_build_object('id', v_lead, 'status', 'new', 'duplicate', false, 'matched_client', v_client is not null);
end
$$;

revoke all on function public.api_ingest_lead(text, jsonb) from public, anon, authenticated;
grant execute on function public.api_ingest_lead(text, jsonb) to service_role;
