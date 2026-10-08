-- Terms of use accepted on screen (owner request 08/10/2026).
--
-- The platform administrator publishes each version of the terms (the text approved by the lawyer). While no version
-- is published nothing changes. Once one is, a company that has not accepted the current version cannot use the
-- system: its administrator reads and accepts it on screen, on behalf of the company; the other users wait. Each
-- acceptance keeps the company, the version, who accepted, when, the IP and browser, and the SHA-256 of the text
-- accepted. Acceptances are never changed or deleted. A new version asks for a new acceptance.
-- Contract: tests/security/terms-acceptance-contract.sql

create table public.terms_versions (
  id uuid primary key default gen_random_uuid(),
  version text not null unique check (length(btrim(version)) between 1 and 40),
  title text not null check (length(btrim(title)) between 3 and 200),
  body text not null check (length(body) between 20 and 200000),
  body_sha256 text not null check (body_sha256 ~ '^[0-9a-f]{64}$'),
  published_at timestamptz not null default now(),
  published_by uuid references auth.users(id) on delete set null
);
alter table public.terms_versions enable row level security;
create policy terms_versions_read on public.terms_versions for select to authenticated using (true);
revoke insert, update, delete on public.terms_versions from anon, authenticated;

create table public.organization_terms_acceptances (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  terms_version_id uuid not null references public.terms_versions(id) on delete restrict,
  accepted_by uuid not null references auth.users(id) on delete restrict,
  accepted_at timestamptz not null default now(),
  body_sha256 text not null check (body_sha256 ~ '^[0-9a-f]{64}$'),
  ip text check (ip is null or length(ip) <= 100),
  user_agent text check (user_agent is null or length(user_agent) <= 500),
  unique (organization_id, terms_version_id)
);
alter table public.organization_terms_acceptances enable row level security;
create policy organization_terms_acceptances_read on public.organization_terms_acceptances for select to authenticated
  using (public.is_active_organization_member(organization_id));
revoke insert, update, delete on public.organization_terms_acceptances from anon, authenticated;

-- The record of an acceptance is the proof: it is never changed or removed, not even by the service.
create or replace function private.guard_terms_immutable()
returns trigger language plpgsql set search_path to '' as $$
begin
  raise exception 'terms_records_are_immutable';
end
$$;
create trigger organization_terms_acceptances_immutable before update or delete on public.organization_terms_acceptances
  for each row execute function private.guard_terms_immutable();
create trigger terms_versions_immutable before update or delete on public.terms_versions
  for each row execute function private.guard_terms_immutable();

-- The version in force: the last one published.
create or replace function private.current_terms()
returns public.terms_versions language sql stable security definer set search_path to '' as $$
  select * from public.terms_versions order by published_at desc, id desc limit 1
$$;

-- Whether the company still has to accept the version in force (false when none is published). Members only.
create or replace function public.terms_pending(p_org uuid)
returns boolean language plpgsql stable security definer set search_path to '' as $$
declare v public.terms_versions%rowtype;
begin
  if auth.uid() is null or not public.is_active_organization_member(p_org) then raise exception 'not_authorized'; end if;
  v := private.current_terms();
  if v.id is null then return false; end if;
  return not exists (select 1 from public.organization_terms_acceptances a where a.organization_id = p_org and a.terms_version_id = v.id);
end
$$;

-- What the acceptance screen shows: the version in force, whether the company accepted it, whether the caller can.
create or replace function public.terms_status(p_org uuid)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v public.terms_versions%rowtype; a public.organization_terms_acceptances%rowtype;
begin
  if auth.uid() is null or not public.is_active_organization_member(p_org) then raise exception 'not_authorized'; end if;
  v := private.current_terms();
  if v.id is null then return jsonb_build_object('required', false); end if;
  select * into a from public.organization_terms_acceptances x where x.organization_id = p_org and x.terms_version_id = v.id;
  return jsonb_build_object(
    'required', true, 'accepted', a.id is not null, 'accepted_at', a.accepted_at,
    'version_id', v.id, 'version', v.version, 'title', v.title, 'body', v.body,
    'can_accept', coalesce(private.caller_role_in(p_org), '') = 'admin');
end
$$;

-- The company's administrator accepts the version in force, on behalf of the company. Idempotent.
create or replace function public.accept_terms(p_org uuid, p_version_id uuid, p_ip text, p_user_agent text)
returns uuid language plpgsql security definer set search_path to '' as $$
declare v public.terms_versions%rowtype; v_id uuid;
begin
  if auth.uid() is null or coalesce(private.caller_role_in(p_org), '') <> 'admin' then raise exception 'not_authorized'; end if;
  v := private.current_terms();
  if v.id is null or v.id is distinct from p_version_id then raise exception 'terms_version_not_current'; end if;
  insert into public.organization_terms_acceptances (organization_id, terms_version_id, accepted_by, body_sha256, ip, user_agent)
  values (p_org, v.id, auth.uid(), v.body_sha256, left(nullif(btrim(coalesce(p_ip, '')), ''), 100), left(nullif(btrim(coalesce(p_user_agent, '')), ''), 500))
  on conflict (organization_id, terms_version_id) do nothing
  returning id into v_id;
  if v_id is null then
    select a.id into v_id from public.organization_terms_acceptances a where a.organization_id = p_org and a.terms_version_id = v.id;
  end if;
  return v_id;
end
$$;

revoke all on function private.current_terms() from public, anon, authenticated;
revoke all on function public.terms_pending(uuid) from public, anon;
revoke all on function public.terms_status(uuid) from public, anon;
revoke all on function public.accept_terms(uuid, uuid, text, text) from public, anon;
grant execute on function public.terms_pending(uuid) to authenticated;
grant execute on function public.terms_status(uuid) to authenticated;
grant execute on function public.accept_terms(uuid, uuid, text, text) to authenticated;
