-- Monthly fee charged by the platform to each company, paid by static Pix (owner, 02/11/2026).
-- Spec: docs/superpowers/specs/2026-11-02-cobranca-mais-valor-design.md
--
-- The platform owner sets the Pix receiver (key, name, city) and, per company, a subscription (amount, due day, grace
-- days, first month). Each month's charge is created on demand, from its due day on, the first time the company opens
-- the system (no scheduler). Its amount, due day and grace are copied from the subscription when it is created.
-- The owner confirms the payment by hand ("paid" event); a mistake is undone with a "reversal" event with a reason.
-- Charges and events are never changed or deleted. A company with an active subscription and a charge not paid after
-- its due day plus the grace days is blocked by the application (every screen, every server action and the public API);
-- the RLS of the existing tables does not change. Days follow Brasília (set timezone), like the rest of the system.
-- The receiver's data is personal: it is written only in the production database, never in this file.
-- Contract: tests/security/billing-contract.sql

create table public.platform_billing_settings (
  id boolean primary key default true check (id),
  pix_key text not null check (length(btrim(pix_key)) between 1 and 77),
  pix_key_type text not null check (pix_key_type in ('cpf','cnpj','email','phone','random')),
  merchant_name text not null check (length(btrim(merchant_name)) between 1 and 25),
  merchant_city text not null check (length(btrim(merchant_city)) between 1 and 15),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

create table public.organization_subscriptions (
  organization_id uuid primary key references public.organizations(id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  due_day smallint not null check (due_day between 1 and 28),
  grace_days smallint not null check (grace_days between 0 and 30),
  starts_on date not null check (extract(day from starts_on) = 1),
  is_active boolean not null default true,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

create table public.organization_charges (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  period date not null check (extract(day from period) = 1),
  amount numeric(14,2) not null check (amount > 0),
  due_on date not null,
  grace_days smallint not null check (grace_days between 0 and 30),
  txid text not null check (txid ~ '^[A-Za-z0-9]{1,25}$'),
  created_at timestamptz not null default now(),
  unique (organization_id, period)
);

create table public.organization_charge_events (
  id uuid primary key default gen_random_uuid(),
  seq bigint generated always as identity unique,
  charge_id uuid not null references public.organization_charges(id) on delete restrict,
  kind text not null check (kind in ('paid','reversal')),
  paid_on date,
  note text check (note is null or length(note) <= 500),
  source text not null default 'manual' check (source in ('manual')),
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check ((kind = 'paid' and paid_on is not null) or (kind = 'reversal' and paid_on is null and length(btrim(coalesce(note, ''))) >= 3))
);
create index organization_charge_events_charge on public.organization_charge_events (charge_id, seq desc);

alter table public.platform_billing_settings enable row level security;
alter table public.organization_subscriptions enable row level security;
alter table public.organization_charges enable row level security;
alter table public.organization_charge_events enable row level security;
revoke all on public.platform_billing_settings, public.organization_subscriptions, public.organization_charges,
  public.organization_charge_events from anon, authenticated;

create or replace function private.guard_billing_immutable()
returns trigger language plpgsql set search_path to '' as $$
begin
  raise exception 'billing_records_are_immutable';
end
$$;
create trigger organization_charges_immutable before update or delete on public.organization_charges
  for each row execute function private.guard_billing_immutable();
create trigger organization_charge_events_immutable before update or delete on public.organization_charge_events
  for each row execute function private.guard_billing_immutable();

-- Creates the charges whose due day has come (idempotent). Nothing for a company without an active subscription.
create or replace function private.ensure_organization_charges(p_org uuid)
returns void language plpgsql security definer set search_path to '' set timezone to 'America/Sao_Paulo' as $$
declare s public.organization_subscriptions%rowtype; p date; v_tag text;
begin
  select * into s from public.organization_subscriptions where organization_id = p_org and is_active;
  if s.organization_id is null then return; end if;
  select left(upper(regexp_replace(translate(upper(o.name), 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ', 'AAAAAEEEEIIIIOOOOOUUUUCN'), '[^A-Za-z0-9]', '', 'g')), 19) into v_tag from public.organizations o where o.id = p_org;
  p := s.starts_on;
  while p <= date_trunc('month', current_date)::date loop
    if current_date >= p + (s.due_day - 1) then
      insert into public.organization_charges (organization_id, period, amount, due_on, grace_days, txid)
      values (p_org, p, s.amount, p + (s.due_day - 1), s.grace_days, coalesce(nullif(v_tag, ''), 'CORBAN') || to_char(p, 'YYYYMM'))
      on conflict (organization_id, period) do nothing;
    end if;
    p := (p + interval '1 month')::date;
  end loop;
end
$$;

-- Paid on (null when not paid): the last event (by seq, never by time) decides.
create or replace function private.charge_paid_on(p_charge uuid)
returns date language sql stable security definer set search_path to '' as $$
  select case when e.kind = 'paid' then e.paid_on end
  from public.organization_charge_events e where e.charge_id = p_charge order by e.seq desc limit 1
$$;

-- 'paid', 'open' (until the due day), 'overdue' (grace) or 'blocking' (after the grace).
create or replace function private.charge_state(c public.organization_charges)
returns text language sql stable security definer set search_path to '' set timezone to 'America/Sao_Paulo' as $$
  select case
    when private.charge_paid_on(c.id) is not null then 'paid'
    when current_date <= c.due_on then 'open'
    when current_date <= c.due_on + c.grace_days then 'overdue'
    else 'blocking' end
$$;

create or replace function private.billing_summary(p_org uuid)
returns jsonb language plpgsql security definer set search_path to '' set timezone to 'America/Sao_Paulo' as $$
declare c public.organization_charges%rowtype; v_state text; v_blocked boolean := false;
begin
  perform private.ensure_organization_charges(p_org);
  if not exists (select 1 from public.organization_subscriptions s where s.organization_id = p_org and s.is_active) then
    return jsonb_build_object('blocked', false, 'overdue', false);
  end if;
  -- the oldest unpaid charge is the one the notice talks about
  for c in select * from public.organization_charges x where x.organization_id = p_org order by x.period loop
    v_state := private.charge_state(c);
    if v_state <> 'paid' then
      v_blocked := v_state = 'blocking'
        or exists (select 1 from public.organization_charges y where y.organization_id = p_org and y.period > c.period and private.charge_state(y) = 'blocking');
      return jsonb_build_object('blocked', v_blocked, 'overdue', v_state <> 'open', 'period', c.period, 'due_on', c.due_on,
        'block_on', c.due_on + c.grace_days + 1, 'amount', c.amount::text);
    end if;
  end loop;
  return jsonb_build_object('blocked', false, 'overdue', false);
end
$$;

-- For every screen of the company: whether it is blocked and what the notice says. Members only.
create or replace function public.billing_status(p_org uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  if auth.uid() is null or not public.is_active_organization_member(p_org) then raise exception 'not_authorized'; end if;
  return private.billing_summary(p_org);
end
$$;

-- The payment screen: the company's charges and the Pix receiver. The company's administrator only.
create or replace function public.my_billing(p_org uuid)
returns jsonb language plpgsql security definer set search_path to '' set timezone to 'America/Sao_Paulo' as $$
declare r public.platform_billing_settings%rowtype;
begin
  if auth.uid() is null or coalesce(private.caller_role_in(p_org), '') <> 'admin' then raise exception 'not_authorized'; end if;
  perform private.ensure_organization_charges(p_org);
  select * into r from public.platform_billing_settings where id;
  return jsonb_build_object(
    'receiver', case when r.id then jsonb_build_object('key', r.pix_key, 'name', r.merchant_name, 'city', r.merchant_city) end,
    'charges', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'period', c.period, 'amount', c.amount::text, 'due_on', c.due_on,
        'block_on', c.due_on + c.grace_days + 1, 'txid', c.txid, 'state', private.charge_state(c), 'paid_on', private.charge_paid_on(c.id)) order by c.period desc)
      from public.organization_charges c where c.organization_id = p_org), '[]'::jsonb));
end
$$;

-- Public API (/api/v1): whether the company of this key is blocked. False for an unknown key (the API refuses it anyway).
create or replace function public.api_billing_blocked(p_key text)
returns boolean language plpgsql security definer set search_path to '' as $$
declare v_org uuid;
begin
  select k.organization_id into v_org from public.api_keys k where k.key_hash = encode(extensions.digest(coalesce(p_key, ''), 'sha256'), 'hex');
  if v_org is null then return false; end if;
  return coalesce((private.billing_summary(v_org) ->> 'blocked')::boolean, false);
end
$$;

-- Platform owner (/platform, service role; the server checked platform_administrators and audits each call).
create or replace function public.platform_set_billing_settings(p_actor uuid, p_key text, p_key_type text, p_name text, p_city text)
returns void language plpgsql security definer set search_path to '' as $$
begin
  insert into public.platform_billing_settings (id, pix_key, pix_key_type, merchant_name, merchant_city, updated_at, updated_by)
  values (true, btrim(p_key), p_key_type, upper(btrim(p_name)), upper(btrim(p_city)), now(), p_actor)
  on conflict (id) do update set pix_key = excluded.pix_key, pix_key_type = excluded.pix_key_type, merchant_name = excluded.merchant_name,
    merchant_city = excluded.merchant_city, updated_at = now(), updated_by = p_actor;
end
$$;

create or replace function public.platform_set_subscription(p_actor uuid, p_org uuid, p_amount numeric, p_due_day integer, p_grace_days integer, p_starts_on date, p_active boolean)
returns void language plpgsql security definer set search_path to '' set timezone to 'America/Sao_Paulo' as $$
begin
  if p_amount is null or p_amount <> round(p_amount, 2) then raise exception 'billing_invalid_amount'; end if;
  insert into public.organization_subscriptions (organization_id, amount, due_day, grace_days, starts_on, is_active, updated_at, updated_by)
  values (p_org, p_amount, p_due_day, p_grace_days, date_trunc('month', p_starts_on)::date, p_active, now(), p_actor)
  on conflict (organization_id) do update set amount = excluded.amount, due_day = excluded.due_day, grace_days = excluded.grace_days,
    starts_on = excluded.starts_on, is_active = excluded.is_active, updated_at = now(), updated_by = p_actor;
end
$$;

create or replace function public.platform_mark_charge_paid(p_actor uuid, p_charge uuid, p_paid_on date)
returns void language plpgsql security definer set search_path to '' set timezone to 'America/Sao_Paulo' as $$
declare c public.organization_charges%rowtype;
begin
  select * into c from public.organization_charges where id = p_charge for update;
  if c.id is null then raise exception 'billing_charge_not_found'; end if;
  if private.charge_paid_on(c.id) is not null then raise exception 'billing_charge_already_paid'; end if;
  if p_paid_on is null or p_paid_on > current_date then raise exception 'billing_invalid_paid_on'; end if;
  insert into public.organization_charge_events (charge_id, kind, paid_on, actor_user_id) values (c.id, 'paid', p_paid_on, p_actor);
end
$$;

create or replace function public.platform_reverse_charge(p_actor uuid, p_charge uuid, p_note text)
returns void language plpgsql security definer set search_path to '' as $$
declare c public.organization_charges%rowtype;
begin
  select * into c from public.organization_charges where id = p_charge for update;
  if c.id is null then raise exception 'billing_charge_not_found'; end if;
  if private.charge_paid_on(c.id) is null then raise exception 'billing_charge_not_paid'; end if;
  if length(btrim(coalesce(p_note, ''))) < 3 then raise exception 'billing_reversal_note_required'; end if;
  insert into public.organization_charge_events (charge_id, kind, note, actor_user_id) values (c.id, 'reversal', left(btrim(p_note), 500), p_actor);
end
$$;

-- Every company's charges for /platform (creates the due ones first).
create or replace function public.platform_billing_overview()
returns jsonb language plpgsql security definer set search_path to '' set timezone to 'America/Sao_Paulo' as $$
declare v_org uuid;
begin
  for v_org in select organization_id from public.organization_subscriptions where is_active loop
    perform private.ensure_organization_charges(v_org);
  end loop;
  return coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'organization_id', c.organization_id, 'period', c.period, 'amount', c.amount::text,
      'due_on', c.due_on, 'block_on', c.due_on + c.grace_days + 1, 'state', private.charge_state(c), 'paid_on', private.charge_paid_on(c.id)) order by c.period desc, c.organization_id)
    from public.organization_charges c), '[]'::jsonb);
end
$$;

revoke all on function private.guard_billing_immutable() from public, anon, authenticated;
revoke all on function private.ensure_organization_charges(uuid) from public, anon, authenticated;
revoke all on function private.charge_paid_on(uuid) from public, anon, authenticated;
revoke all on function private.charge_state(public.organization_charges) from public, anon, authenticated;
revoke all on function private.billing_summary(uuid) from public, anon, authenticated;
revoke all on function public.billing_status(uuid) from public, anon;
revoke all on function public.my_billing(uuid) from public, anon;
revoke all on function public.api_billing_blocked(text) from public, anon, authenticated;
revoke all on function public.platform_set_billing_settings(uuid, text, text, text, text) from public, anon, authenticated;
revoke all on function public.platform_set_subscription(uuid, uuid, numeric, integer, integer, date, boolean) from public, anon, authenticated;
revoke all on function public.platform_mark_charge_paid(uuid, uuid, date) from public, anon, authenticated;
revoke all on function public.platform_reverse_charge(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.platform_billing_overview() from public, anon, authenticated;
grant execute on function public.billing_status(uuid) to authenticated;
grant execute on function public.my_billing(uuid) to authenticated;
grant execute on function public.api_billing_blocked(text) to service_role;
grant execute on function public.platform_set_billing_settings(uuid, text, text, text, text) to service_role;
grant execute on function public.platform_set_subscription(uuid, uuid, numeric, integer, integer, date, boolean) to service_role;
grant execute on function public.platform_mark_charge_paid(uuid, uuid, date) to service_role;
grant execute on function public.platform_reverse_charge(uuid, uuid, text) to service_role;
grant execute on function public.platform_billing_overview() to service_role;
