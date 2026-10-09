-- Improvement requests (owner request 08/10/2026): any user of a client company suggests an improvement, reports an
-- error or asks a question from inside the system and gets a protocol (MEL-2026-0001); the platform administrator
-- answers whether it will be done. Each user sees their own requests; the company's administrator sees all of the
-- company; no company ever sees another's. Status changes are made only by a platform administrator (through the
-- service role, after the platform gate) and every change is kept in an immutable history. Nothing is deleted.
-- Contract: tests/security/improvement-requests-contract.sql

create sequence public.improvement_request_seq;
revoke all on sequence public.improvement_request_seq from public, anon, authenticated;

create table public.improvement_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  protocol text not null unique check (protocol ~ '^MEL-[0-9]{4}-[0-9]{4,}$'),
  kind text not null check (kind in ('improvement', 'bug', 'question')),
  title text not null check (length(btrim(title)) between 3 and 120),
  body text not null check (length(btrim(body)) between 10 and 4000),
  page_path text check (page_path is null or page_path ~ '^/[A-Za-z0-9/_-]{0,199}$'),
  status text not null default 'received' check (status in ('received', 'analyzing', 'approved', 'declined', 'delivered')),
  response text check (response is null or length(response) <= 4000),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (status <> 'declined' or length(btrim(coalesce(response, ''))) >= 3)
);
create index improvement_requests_org_idx on public.improvement_requests (organization_id, created_at desc);
create index improvement_requests_status_idx on public.improvement_requests (status, created_at desc);

create table public.improvement_request_events (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.improvement_requests(id) on delete restrict,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  from_status text,
  to_status text not null,
  response text,
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index improvement_request_events_request_idx on public.improvement_request_events (request_id, created_at);

-- Nothing is deleted; history rows never change.
create or replace function private.improvement_requests_guard()
returns trigger language plpgsql set search_path to '' as $$
begin
  if tg_op = 'DELETE' then raise exception 'improvement_records_are_kept'; end if;
  if tg_table_name = 'improvement_request_events' then raise exception 'improvement_records_are_kept'; end if;
  if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id or new.protocol is distinct from old.protocol
     or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at
     or new.title is distinct from old.title or new.body is distinct from old.body or new.kind is distinct from old.kind then
    raise exception 'improvement_request_identity_is_immutable';
  end if;
  return new;
end
$$;
create trigger improvement_requests_guard before update or delete on public.improvement_requests
for each row execute function private.improvement_requests_guard();
create trigger improvement_request_events_guard before update or delete on public.improvement_request_events
for each row execute function private.improvement_requests_guard();

alter table public.improvement_requests enable row level security;
alter table public.improvement_request_events enable row level security;
revoke all on public.improvement_requests, public.improvement_request_events from public, anon, authenticated;
grant select on public.improvement_requests, public.improvement_request_events to authenticated;
create policy improvement_requests_select on public.improvement_requests for select to authenticated
  using (public.is_active_organization_member(organization_id)
         and (created_by = (select auth.uid()) or public.has_active_organization_role(organization_id, array['admin'])));
create policy improvement_request_events_select on public.improvement_request_events for select to authenticated
  using (exists (select 1 from public.improvement_requests r where r.id = request_id));

-- A member sends a request; at most 20 per user per day.
create or replace function public.submit_improvement_request(p_org uuid, p_kind text, p_title text, p_body text, p_page text default null)
returns text language plpgsql security definer set search_path to '' as $$
declare v_protocol text; v_id uuid; v_page text := nullif(btrim(coalesce(p_page, '')), '');
begin
  if auth.uid() is null or p_org is null or not public.is_active_organization_member(p_org) then raise exception 'not_authorized'; end if;
  if p_kind not in ('improvement', 'bug', 'question') then raise exception 'invalid_kind'; end if;
  if length(btrim(coalesce(p_title, ''))) not between 3 and 120 then raise exception 'invalid_title'; end if;
  if length(btrim(coalesce(p_body, ''))) not between 10 and 4000 then raise exception 'invalid_body'; end if;
  if v_page is not null and v_page !~ '^/[A-Za-z0-9/_-]{0,199}$' then v_page := null; end if;
  if (select count(*) from public.improvement_requests r where r.created_by = auth.uid() and r.created_at > now() - interval '1 day') >= 20 then
    raise exception 'too_many_requests';
  end if;
  v_protocol := 'MEL-' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYY') || '-' || lpad(nextval('public.improvement_request_seq')::text, 4, '0');
  insert into public.improvement_requests (organization_id, protocol, kind, title, body, page_path, created_by)
  values (p_org, v_protocol, p_kind, btrim(p_title), btrim(p_body), v_page, auth.uid()) returning id into v_id;
  insert into public.improvement_request_events (request_id, organization_id, from_status, to_status, actor_user_id)
  values (v_id, p_org, null, 'received', auth.uid());
  return v_protocol;
end
$$;
revoke all on function public.submit_improvement_request(uuid, text, text, text, text) from public, anon;
grant execute on function public.submit_improvement_request(uuid, text, text, text, text) to authenticated;

-- The platform administrator answers (called with the service role after the platform gate; the actor is checked here).
create or replace function public.platform_answer_improvement_request(p_request uuid, p_status text, p_response text, p_actor uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare r public.improvement_requests%rowtype; v_response text := nullif(btrim(coalesce(p_response, '')), '');
begin
  if not exists (select 1 from public.platform_administrators a where a.user_id = p_actor and a.status = 'active') then raise exception 'not_authorized'; end if;
  select * into r from public.improvement_requests where id = p_request for update;
  if r.id is null then raise exception 'request_not_found'; end if;
  if p_status not in ('received', 'analyzing', 'approved', 'declined', 'delivered') then raise exception 'invalid_status'; end if;
  if p_status = 'declined' and length(coalesce(v_response, '')) < 3 then raise exception 'response_required'; end if;
  if v_response is not null and length(v_response) > 4000 then raise exception 'invalid_response'; end if;
  if p_status = r.status and v_response is not distinct from r.response then return; end if;
  update public.improvement_requests set status = p_status, response = coalesce(v_response, response), updated_at = now() where id = r.id;
  insert into public.improvement_request_events (request_id, organization_id, from_status, to_status, response, actor_user_id)
  values (r.id, r.organization_id, r.status, p_status, v_response, p_actor);
end
$$;
revoke all on function public.platform_answer_improvement_request(uuid, text, text, uuid) from public, anon, authenticated;
grant execute on function public.platform_answer_improvement_request(uuid, text, text, uuid) to service_role;
