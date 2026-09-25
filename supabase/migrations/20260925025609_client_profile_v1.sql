-- Client profile (F2 extension, owner-approved 25/09/2026, ADR-0033).
--
-- 1. Personal data on the client: parents, RG (number, issuer, UF, issue date), gender, marital status, birthplace,
--    WhatsApp (also kept in the contact history). All optional; the screen flags an incomplete profile.
-- 2. Bank accounts and registrations (matrículas) written only through RPCs that require clientes.edit and sight of the
--    client. A client may have many registrations: agreement (convênio), agency (órgão, free text), number, status,
--    current margin (value, date of the information, who informed it), portal login and password.
-- 3. The registration password is kept encrypted in Supabase Vault, never in a table column. It is shown only through
--    reveal_registration_password, to whoever may edit clients and sees that client, and every reveal is recorded in
--    sensitive_access_log (readable by administrators only).

-- 1. Personal data ----------------------------------------------------------------------------------------------------------

alter table public.clients
  add column father_name text check (length(father_name) between 3 and 160),
  add column mother_name text check (length(mother_name) between 3 and 160),
  add column rg_number text check (rg_number ~ '^[0-9A-Za-z.\-/ ]{3,20}$'),
  add column rg_issuer text check (length(rg_issuer) between 2 and 20),
  add column rg_state text check (rg_state ~ '^[A-Z]{2}$'),
  add column rg_issued_on date,
  add column gender text check (gender in ('F','M','N')),
  add column marital_status text check (marital_status in ('single','married','stable_union','divorced','separated','widowed')),
  add column birthplace_city text check (length(birthplace_city) between 2 and 120),
  add column birthplace_state text check (birthplace_state ~ '^[A-Z]{2}$'),
  add column whatsapp text check (whatsapp ~ '^55[0-9]{10,11}$');

alter table public.client_contacts drop constraint client_contacts_kind_check;
alter table public.client_contacts add constraint client_contacts_kind_check check (kind in ('phone','email','whatsapp'));

create or replace function private.is_uf(p text)
returns boolean
language sql
immutable
set search_path to ''
as $$
  select p in ('AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO')
$$;

-- The client the caller may edit (clientes.edit and sight of the client), or an error.
create or replace function private.editable_client(p_client uuid)
returns public.clients
language plpgsql
stable
security definer
set search_path to ''
as $$
declare c public.clients%rowtype;
begin
  select * into c from public.clients where id = p_client and deleted_at is null;
  if c.id is null or auth.uid() is null or not public.is_active_organization_member(c.organization_id)
     or not public.has_permission(c.organization_id, 'clientes.edit')
     or not private.can_see_client_row(c.organization_id, c.id, c.owner_user_id) then
    raise exception 'not_authorized';
  end if;
  return c;
end
$$;

revoke all on function private.editable_client(uuid) from public, anon, authenticated;

-- Replaces the personal data of the client (null clears a field). Dates must make sense.
create or replace function public.update_client_profile(p_client uuid, p_birth_date date, p_father_name text, p_mother_name text,
  p_rg_number text, p_rg_issuer text, p_rg_state text, p_rg_issued_on date, p_gender text, p_marital_status text,
  p_birthplace_city text, p_birthplace_state text, p_whatsapp text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  c public.clients%rowtype := private.editable_client(p_client);
  v_wa text := nullif(btrim(coalesce(p_whatsapp, '')), '');
  t text;
begin
  if p_birth_date is not null and (p_birth_date < date '1900-01-01' or p_birth_date > current_date) then raise exception 'invalid_birth_date'; end if;
  if p_rg_issued_on is not null and (p_rg_issued_on > current_date or (p_birth_date is not null and p_rg_issued_on < p_birth_date)) then raise exception 'invalid_rg_issued_on'; end if;
  foreach t in array array[nullif(upper(btrim(coalesce(p_rg_state, ''))), ''), nullif(upper(btrim(coalesce(p_birthplace_state, ''))), '')] loop
    if t is not null and not private.is_uf(t) then raise exception 'invalid_state'; end if;
  end loop;
  if v_wa is not null then
    v_wa := private.normalize_phone(v_wa);
    if v_wa is null then raise exception 'invalid_whatsapp'; end if;
  end if;

  update public.clients set
    birth_date = p_birth_date,
    father_name = nullif(btrim(coalesce(p_father_name, '')), ''),
    mother_name = nullif(btrim(coalesce(p_mother_name, '')), ''),
    rg_number = nullif(btrim(coalesce(p_rg_number, '')), ''),
    rg_issuer = nullif(upper(btrim(coalesce(p_rg_issuer, ''))), ''),
    rg_state = nullif(upper(btrim(coalesce(p_rg_state, ''))), ''),
    rg_issued_on = p_rg_issued_on,
    gender = nullif(p_gender, ''),
    marital_status = nullif(p_marital_status, ''),
    birthplace_city = nullif(btrim(coalesce(p_birthplace_city, '')), ''),
    birthplace_state = nullif(upper(btrim(coalesce(p_birthplace_state, ''))), ''),
    whatsapp = v_wa,
    updated_at = now()
  where id = c.id;
  if v_wa is not null then perform private.record_client_contact(c.organization_id, c.id, 'whatsapp', v_wa, 'manual'); end if;
end
$$;

-- 2. Bank accounts ----------------------------------------------------------------------------------------------------------

create or replace function public.add_client_bank_account(p_client uuid, p_bank_code text, p_bank_name text, p_branch text, p_account_number text,
  p_account_digit text, p_account_type text, p_primary boolean)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  c public.clients%rowtype := private.editable_client(p_client);
  v_id uuid;
  v_primary boolean := coalesce(p_primary, false) or not exists (select 1 from public.customer_bank_accounts b where b.customer_id = c.id);
begin
  if coalesce(p_bank_code, '') !~ '^[0-9]{3}$' then raise exception 'invalid_bank_code'; end if;
  if length(btrim(coalesce(p_bank_name, ''))) not between 2 and 120 then raise exception 'invalid_bank_name'; end if;
  if coalesce(p_branch, '') !~ '^[0-9]{1,6}(-[0-9Xx])?$' then raise exception 'invalid_branch'; end if;
  if coalesce(p_account_number, '') !~ '^[0-9]{1,20}$' then raise exception 'invalid_account'; end if;
  if p_account_digit is not null and p_account_digit <> '' and p_account_digit !~ '^[0-9Xx]{1,2}$' then raise exception 'invalid_account'; end if;
  if p_account_type not in ('checking','savings','salary','payment') then raise exception 'invalid_account_type'; end if;
  if v_primary then
    update public.customer_bank_accounts set is_primary = false, updated_at = now() where customer_id = c.id and is_primary;
  end if;
  insert into public.customer_bank_accounts (organization_id, customer_id, bank_code, bank_name, branch, account_number, account_digit, account_type,
                                             holder_name, holder_document, is_primary)
  values (c.organization_id, c.id, p_bank_code, btrim(p_bank_name), p_branch, p_account_number, nullif(upper(p_account_digit), ''), p_account_type,
          c.full_name, c.cpf, v_primary)
  returning id into v_id;
  return v_id;
end
$$;

create or replace function public.set_client_bank_account(p_account uuid, p_action text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare a public.customer_bank_accounts%rowtype; c public.clients%rowtype;
begin
  select * into a from public.customer_bank_accounts where id = p_account;
  if a.id is null then raise exception 'not_authorized'; end if;
  c := private.editable_client(a.customer_id);
  if p_action = 'primary' then
    update public.customer_bank_accounts set is_primary = false, updated_at = now() where customer_id = c.id and is_primary and id <> a.id;
    update public.customer_bank_accounts set is_primary = true, updated_at = now() where id = a.id;
  elsif p_action = 'remove' then
    if exists (select 1 from public.customer_pix_keys k where k.bank_account_id = a.id) then raise exception 'bank_account_in_use'; end if;
    delete from public.customer_bank_accounts where id = a.id;
  else
    raise exception 'invalid_action';
  end if;
end
$$;

-- 3. Registrations ----------------------------------------------------------------------------------------------------------

create table public.client_registrations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  customer_id uuid not null,
  agreement_id uuid not null,
  agency_name text check (length(agency_name) between 2 and 160),
  registration_number text not null check (registration_number ~ '^[0-9A-Za-z./\-]{1,40}$'),
  status text not null default 'active' check (status in ('active','inactive')),
  margin_amount numeric(15,2) check (margin_amount >= 0),
  margin_as_of date,
  margin_updated_by uuid,
  margin_updated_at timestamptz,
  portal_login text check (length(portal_login) between 1 and 120),
  portal_password_secret uuid,
  has_portal_password boolean generated always as (portal_password_secret is not null) stored,
  notes text check (length(notes) <= 300),
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, agreement_id, registration_number),
  constraint registration_margin_shape check ((margin_amount is null) = (margin_as_of is null)),
  foreign key (organization_id, customer_id) references public.clients (organization_id, id) on delete restrict,
  foreign key (organization_id, agreement_id) references public.organization_agreements (organization_id, id) on delete restrict
);

create index client_registrations_customer_idx on public.client_registrations (customer_id);

create table public.sensitive_access_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  actor_user_id uuid not null,
  customer_id uuid,
  subject_kind text not null check (subject_kind in ('registration_password')),
  subject_id uuid not null,
  accessed_at timestamptz not null default now()
);

create index sensitive_access_log_org_idx on public.sensitive_access_log (organization_id, accessed_at desc);

create or replace function public.guard_client_sensitive_write()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if current_setting('corban.client_rpc', true) is distinct from 'on' then raise exception 'client_write_requires_governed_rpc'; end if;
  if tg_op = 'DELETE' then raise exception 'record_is_not_deletable'; end if;
  if tg_op = 'UPDATE' and tg_table_name = 'sensitive_access_log' then raise exception 'access_log_is_immutable'; end if;
  return new;
end
$$;

revoke all on function public.guard_client_sensitive_write() from public, anon, authenticated;
create trigger client_registrations_00_guard before insert or update or delete on public.client_registrations for each row execute function public.guard_client_sensitive_write();
create trigger sensitive_access_log_00_guard before insert or update or delete on public.sensitive_access_log for each row execute function public.guard_client_sensitive_write();

alter table public.client_registrations enable row level security;
alter table public.sensitive_access_log enable row level security;
revoke all on table public.client_registrations, public.sensitive_access_log from anon, authenticated;
-- Every column except the Vault reference.
grant select (id, organization_id, customer_id, agreement_id, agency_name, registration_number, status, margin_amount, margin_as_of, margin_updated_by,
              margin_updated_at, portal_login, has_portal_password, notes, created_by, created_at, updated_at) on public.client_registrations to authenticated;
grant select on public.sensitive_access_log to authenticated;

create policy client_registrations_select on public.client_registrations for select to authenticated
  using (public.is_active_organization_member(organization_id) and exists (select 1 from public.clients c where c.id = customer_id));
create policy sensitive_access_log_select on public.sensitive_access_log for select to authenticated
  using (private.caller_role_in(organization_id) = 'admin');

-- Creates or updates a registration. p_password: null keeps the current one, text replaces it; p_clear_password removes it.
create or replace function public.save_client_registration(p_client uuid, p_registration uuid, p_agreement uuid, p_agency_name text,
  p_registration_number text, p_status text, p_margin_amount numeric, p_margin_as_of date, p_portal_login text, p_password text,
  p_clear_password boolean, p_notes text)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  c public.clients%rowtype := private.editable_client(p_client);
  r public.client_registrations%rowtype;
  v_id uuid;
  v_secret uuid;
  v_number text := upper(btrim(coalesce(p_registration_number, '')));
begin
  if not exists (select 1 from public.organization_agreements a where a.organization_id = c.organization_id and a.id = p_agreement and a.is_active) then
    raise exception 'agreement_not_found';
  end if;
  if v_number !~ '^[0-9A-Z./\-]{1,40}$' then raise exception 'invalid_registration_number'; end if;
  if coalesce(p_status, 'active') not in ('active','inactive') then raise exception 'invalid_status'; end if;
  if p_margin_amount is not null and (p_margin_amount < 0 or p_margin_amount <> round(p_margin_amount, 2)) then raise exception 'invalid_margin'; end if;
  if p_margin_as_of is not null and p_margin_as_of > current_date then raise exception 'invalid_margin_date'; end if;
  if p_password is not null and length(p_password) > 200 then raise exception 'invalid_password'; end if;

  if p_registration is not null then
    select * into r from public.client_registrations where id = p_registration and customer_id = c.id for update;
    if r.id is null then raise exception 'registration_not_found'; end if;
  end if;
  v_secret := r.portal_password_secret;
  if coalesce(p_clear_password, false) and v_secret is not null then
    delete from vault.secrets where id = v_secret;
    v_secret := null;
  elsif p_password is not null and p_password <> '' then
    if v_secret is null then v_secret := vault.create_secret(p_password, null, 'Corban: senha de matrícula');
    else perform vault.update_secret(v_secret, p_password); end if;
  end if;

  perform set_config('corban.client_rpc', 'on', true);
  begin
    if r.id is null then
      insert into public.client_registrations (organization_id, customer_id, agreement_id, agency_name, registration_number, status, margin_amount, margin_as_of,
                                               margin_updated_by, margin_updated_at, portal_login, portal_password_secret, notes, created_by)
      values (c.organization_id, c.id, p_agreement, nullif(btrim(coalesce(p_agency_name, '')), ''), v_number, coalesce(p_status, 'active'),
              p_margin_amount, case when p_margin_amount is null then null else coalesce(p_margin_as_of, current_date) end,
              case when p_margin_amount is null then null else auth.uid() end, case when p_margin_amount is null then null else now() end,
              nullif(btrim(coalesce(p_portal_login, '')), ''), v_secret, nullif(btrim(coalesce(p_notes, '')), ''), auth.uid())
      returning id into v_id;
    else
      update public.client_registrations set
        agreement_id = p_agreement,
        agency_name = nullif(btrim(coalesce(p_agency_name, '')), ''),
        registration_number = v_number,
        status = coalesce(p_status, 'active'),
        margin_amount = p_margin_amount,
        margin_as_of = case when p_margin_amount is null then null else coalesce(p_margin_as_of, current_date) end,
        margin_updated_by = case when p_margin_amount is distinct from r.margin_amount or p_margin_as_of is distinct from r.margin_as_of then auth.uid() else r.margin_updated_by end,
        margin_updated_at = case when p_margin_amount is distinct from r.margin_amount or p_margin_as_of is distinct from r.margin_as_of then now() else r.margin_updated_at end,
        portal_login = nullif(btrim(coalesce(p_portal_login, '')), ''),
        portal_password_secret = v_secret,
        notes = nullif(btrim(coalesce(p_notes, '')), ''),
        updated_at = now()
      where id = r.id
      returning id into v_id;
    end if;
  exception when unique_violation then
    perform set_config('corban.client_rpc', 'off', true);
    raise exception 'registration_already_exists';
  end;
  perform set_config('corban.client_rpc', 'off', true);
  return v_id;
end
$$;

-- Shows the registration password to whoever may edit the client, and records the access.
create or replace function public.reveal_registration_password(p_registration uuid)
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare r public.client_registrations%rowtype; c public.clients%rowtype; v text;
begin
  select * into r from public.client_registrations where id = p_registration;
  if r.id is null then raise exception 'not_authorized'; end if;
  c := private.editable_client(r.customer_id);
  if r.portal_password_secret is null then return null; end if;
  perform set_config('corban.client_rpc', 'on', true);
  insert into public.sensitive_access_log (organization_id, actor_user_id, customer_id, subject_kind, subject_id)
  values (c.organization_id, auth.uid(), c.id, 'registration_password', r.id);
  perform set_config('corban.client_rpc', 'off', true);
  select s.decrypted_secret into v from vault.decrypted_secrets s where s.id = r.portal_password_secret;
  return v;
end
$$;

revoke all on function private.is_uf(text) from public, anon;
grant execute on function private.is_uf(text) to authenticated;
revoke all on function public.update_client_profile(uuid, date, text, text, text, text, text, date, text, text, text, text, text) from public, anon;
revoke all on function public.add_client_bank_account(uuid, text, text, text, text, text, text, boolean) from public, anon;
revoke all on function public.set_client_bank_account(uuid, text) from public, anon;
revoke all on function public.save_client_registration(uuid, uuid, uuid, text, text, text, numeric, date, text, text, boolean, text) from public, anon;
revoke all on function public.reveal_registration_password(uuid) from public, anon;
grant execute on function public.update_client_profile(uuid, date, text, text, text, text, text, date, text, text, text, text, text) to authenticated;
grant execute on function public.add_client_bank_account(uuid, text, text, text, text, text, text, boolean) to authenticated;
grant execute on function public.set_client_bank_account(uuid, text) to authenticated;
grant execute on function public.save_client_registration(uuid, uuid, uuid, text, text, text, numeric, date, text, text, boolean, text) to authenticated;
grant execute on function public.reveal_registration_password(uuid) to authenticated;
