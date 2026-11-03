-- Bevicred webservice credentials kept per company (owner, 03/11/2026). Replaces the Smart-only partner code and API key
-- in the server environment (ADR-0050): any company's administrator registers its own credentials on screen, several per
-- company (MAIS VALOR has a "Sub" one and its own). The partner code and the API key are stored together in Supabase
-- Vault (encrypted); the table keeps only a masked hint of the partner code and the result of the last connection test.
-- Tenants never read the table or the secret: only the server (service role), after checking the user is the company's
-- administrator, calls these functions; the decrypted secret is read only to ask Bevicred for a token.
-- Contract: tests/security/bevicred-credentials-contract.sql

create table public.bevicred_credentials (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  label text not null check (length(btrim(label)) between 1 and 40),
  partner_hint text not null,
  secret_id uuid not null unique,
  last_test_at timestamptz,
  last_test_ok boolean,
  last_test_message text check (last_test_message is null or length(last_test_message) <= 300),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  unique (organization_id, label)
);

alter table public.bevicred_credentials enable row level security;
revoke all on public.bevicred_credentials from anon, authenticated;

-- Creates a credential (p_id null) or replaces the partner code and key of an existing one of the same company.
create or replace function public.bevicred_save_credential(p_actor uuid, p_org uuid, p_id uuid, p_label text, p_partner text, p_key text)
returns uuid language plpgsql security definer set search_path to '' as $$
declare
  v_partner text := btrim(coalesce(p_partner, ''));
  v_key text := btrim(coalesce(p_key, ''));
  v_label text := btrim(coalesce(p_label, ''));
  v_hint text;
  v_secret uuid;
  v_id uuid;
begin
  if length(v_partner) not between 3 and 60 or length(v_key) not between 8 and 200 then raise exception 'bevicred_invalid_credential'; end if;
  v_hint := left(v_partner, 2) || '••••' || right(v_partner, 2);
  if p_id is null then
    if length(v_label) not between 1 and 40 then raise exception 'bevicred_invalid_label'; end if;
    if exists (select 1 from public.bevicred_credentials where organization_id = p_org and lower(label) = lower(v_label)) then
      raise exception 'bevicred_label_taken';
    end if;
    v_secret := vault.create_secret(jsonb_build_object('partner', v_partner, 'key', v_key)::text);
    insert into public.bevicred_credentials (organization_id, label, partner_hint, secret_id, created_by, updated_by)
    values (p_org, v_label, v_hint, v_secret, p_actor, p_actor) returning id into v_id;
    return v_id;
  end if;
  select secret_id into v_secret from public.bevicred_credentials where id = p_id and organization_id = p_org for update;
  if v_secret is null then raise exception 'bevicred_credential_not_found'; end if;
  perform vault.update_secret(v_secret, jsonb_build_object('partner', v_partner, 'key', v_key)::text);
  update public.bevicred_credentials set partner_hint = v_hint, last_test_at = null, last_test_ok = null, last_test_message = null,
    updated_at = now(), updated_by = p_actor where id = p_id;
  return p_id;
end
$$;

-- The decrypted partner code and key, for the server to ask Bevicred for a token. Null for another company's credential.
create or replace function public.bevicred_credential_secret(p_org uuid, p_id uuid)
returns jsonb language sql stable security definer set search_path to '' as $$
  select s.decrypted_secret::jsonb from public.bevicred_credentials c join vault.decrypted_secrets s on s.id = c.secret_id
  where c.id = p_id and c.organization_id = p_org;
$$;

create or replace function public.bevicred_record_test(p_org uuid, p_id uuid, p_ok boolean, p_message text)
returns void language plpgsql security definer set search_path to '' as $$
begin
  update public.bevicred_credentials set last_test_at = now(), last_test_ok = p_ok, last_test_message = left(p_message, 300)
  where id = p_id and organization_id = p_org;
  if not found then raise exception 'bevicred_credential_not_found'; end if;
end
$$;

revoke all on function public.bevicred_save_credential(uuid, uuid, uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.bevicred_credential_secret(uuid, uuid) from public, anon, authenticated;
revoke all on function public.bevicred_record_test(uuid, uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.bevicred_save_credential(uuid, uuid, uuid, text, text, text) to service_role;
grant execute on function public.bevicred_credential_secret(uuid, uuid) to service_role;
grant execute on function public.bevicred_record_test(uuid, uuid, boolean, text) to service_role;
