-- Full seller registration, stage 1 (owner decision 25/09/2026).
--
-- A seller gets an automatic code per company (001, 002...), personal and contact data, home and business address,
-- bank accounts for the commission payment (PIX or TED, one primary, an optional payee when the money goes to someone
-- else) and the contacts of the seller's company. Name, CPF/CNPJ, mobile and e-mail are required; the rest is optional.
--
-- Everything is written by one governed function, save_seller (admin or manager). Bank data is read only by admin,
-- manager and finance, and every bank account change is kept in seller_bank_account_events. The seller_profiles table
-- (one production row) is reused; the ChatGPT-era upsert_seller_profile and can_view_seller_payment (unused) go away.

-- CNPJ check digits (CPF has private.is_valid_cpf).
create or replace function private.is_valid_cnpj(p text)
returns boolean
language plpgsql
immutable
set search_path to ''
as $$
declare
  d text := regexp_replace(coalesce(p, ''), '\D', '', 'g');
  w1 int[] := array[5,4,3,2,9,8,7,6,5,4,3,2];
  w2 int[] := array[6,5,4,3,2,9,8,7,6,5,4,3,2];
  s int; r int; i int;
begin
  if length(d) <> 14 or d ~ '^(\d)\1{13}$' then return false; end if;
  s := 0; for i in 1..12 loop s := s + substr(d, i, 1)::int * w1[i]; end loop;
  r := s % 11; r := case when r < 2 then 0 else 11 - r end;
  if r <> substr(d, 13, 1)::int then return false; end if;
  s := 0; for i in 1..13 loop s := s + substr(d, i, 1)::int * w2[i]; end loop;
  r := s % 11; r := case when r < 2 then 0 else 11 - r end;
  return r = substr(d, 14, 1)::int;
end
$$;
revoke all on function private.is_valid_cnpj(text) from public, anon;

-- 1. Seller code: automatic, sequential per company, never changes.
alter table public.commercial_sellers add column code integer;
with n as (select id, row_number() over (partition by organization_id order by created_at, id) as rn from public.commercial_sellers)
update public.commercial_sellers s set code = n.rn from n where n.id = s.id;
alter table public.commercial_sellers alter column code set not null;
alter table public.commercial_sellers add constraint commercial_sellers_code_key unique (organization_id, code);

create or replace function private.assign_seller_code()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if tg_op = 'INSERT' then
    perform pg_advisory_xact_lock(hashtextextended('seller_code:' || new.organization_id::text, 0));
    select coalesce(max(code), 0) + 1 into new.code from public.commercial_sellers where organization_id = new.organization_id;
  elsif new.code is distinct from old.code then
    raise exception 'seller_code_immutable';
  end if;
  return new;
end
$$;
revoke all on function private.assign_seller_code() from public, anon, authenticated;
create trigger commercial_sellers_05_code before insert or update on public.commercial_sellers
  for each row execute function private.assign_seller_code();

-- 2. Profile: personal data, contact, home and business address.
alter table public.seller_profiles
  add column other_phones text check (other_phones is null or length(other_phones) <= 160),
  add column rg_issued_on date,
  add column mother_name text check (mother_name is null or length(mother_name) <= 160),
  add column father_name text check (father_name is null or length(father_name) <= 160),
  add column zip text check (zip is null or zip ~ '^[0-9]{8}$'),
  add column street text check (street is null or length(street) <= 160),
  add column number text check (number is null or length(number) <= 20),
  add column complement text check (complement is null or length(complement) <= 80),
  add column district text check (district is null or length(district) <= 120),
  add column city text check (city is null or length(city) <= 120),
  add column state text check (state is null or private.is_uf(state)),
  add column business_zip text check (business_zip is null or business_zip ~ '^[0-9]{8}$'),
  add column business_street text check (business_street is null or length(business_street) <= 160),
  add column business_number text check (business_number is null or length(business_number) <= 20),
  add column business_complement text check (business_complement is null or length(business_complement) <= 80),
  add column business_district text check (business_district is null or length(business_district) <= 120),
  add column business_city text check (business_city is null or length(business_city) <= 120),
  add column business_state text check (business_state is null or private.is_uf(business_state));

-- 3. Bank accounts for the commission payment.
create table public.seller_bank_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  seller_id uuid not null,
  transfer_method text not null check (transfer_method in ('pix', 'ted')),
  account_type text check (account_type in ('checking', 'savings', 'salary', 'payment')),
  bank_code text check (bank_code ~ '^[0-9]{3}$'),
  bank_name text check (length(btrim(bank_name)) between 2 and 120),
  branch text check (branch ~ '^[0-9]{1,6}(-[0-9Xx])?$'),
  account_number text check (account_number ~ '^[0-9]{1,20}$'),
  account_digit text check (account_digit ~ '^[0-9X]{1,2}$'),
  pix_key_type text check (pix_key_type in ('cpf_cnpj', 'phone', 'email', 'random')),
  pix_key text check (length(pix_key) between 1 and 77),
  holder_name text check (length(btrim(holder_name)) between 2 and 160),
  holder_document text check (holder_document ~ '^([0-9]{11}|[0-9]{14})$'),
  note text check (length(note) <= 800),
  is_primary boolean not null default false,
  removed_at timestamptz,
  removed_by uuid references auth.users(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, seller_id) references public.commercial_sellers(organization_id, id) on delete restrict,
  -- TED needs the full account; PIX needs the key.
  check (transfer_method <> 'ted' or (account_type is not null and bank_code is not null and bank_name is not null and branch is not null and account_number is not null)),
  check (transfer_method <> 'pix' or (pix_key_type is not null and pix_key is not null)),
  -- A payee other than the seller comes with name and document together.
  check ((holder_name is null) = (holder_document is null))
);
create index seller_bank_accounts_seller_idx on public.seller_bank_accounts (organization_id, seller_id);
create unique index seller_bank_accounts_primary_key on public.seller_bank_accounts (seller_id) where is_primary and removed_at is null;
create index seller_bank_accounts_removed_by_idx on public.seller_bank_accounts (removed_by);
create index seller_bank_accounts_created_by_idx on public.seller_bank_accounts (created_by);

create table public.seller_bank_account_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  seller_id uuid not null,
  account_id uuid not null,
  action text not null check (action in ('added', 'changed', 'removed')),
  before jsonb,
  after jsonb,
  actor uuid references auth.users(id) on delete set null,
  occurred_at timestamptz not null default now(),
  foreign key (organization_id, seller_id) references public.commercial_sellers(organization_id, id) on delete restrict,
  foreign key (organization_id, account_id) references public.seller_bank_accounts(organization_id, id) on delete restrict
);
create index seller_bank_account_events_seller_idx on public.seller_bank_account_events (organization_id, seller_id, occurred_at desc);
create index seller_bank_account_events_account_idx on public.seller_bank_account_events (organization_id, account_id);
create index seller_bank_account_events_actor_idx on public.seller_bank_account_events (actor);

-- 4. Contacts of the seller's company (partners, office staff).
create table public.seller_contacts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  seller_id uuid not null,
  name text not null check (length(btrim(name)) between 2 and 160),
  cpf text check (cpf ~ '^[0-9]{11}$'),
  role text check (length(role) <= 80),
  mobile text check (mobile ~ '^[0-9]{10,13}$'),
  email text check (length(email) <= 160),
  created_at timestamptz not null default now(),
  foreign key (organization_id, seller_id) references public.commercial_sellers(organization_id, id) on delete restrict
);
create index seller_contacts_seller_idx on public.seller_contacts (organization_id, seller_id);

-- Writes only through save_seller; bank rows and their history are never deleted.
create or replace function private.guard_seller_registration_write()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if current_setting('corban.seller_rpc', true) is distinct from 'on' then raise exception 'seller_write_requires_governed_rpc'; end if;
  if tg_op = 'DELETE' and tg_table_name <> 'seller_contacts' then raise exception 'seller_history_immutable'; end if;
  if tg_table_name = 'seller_bank_account_events' and tg_op <> 'INSERT' then raise exception 'seller_history_immutable'; end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end
$$;
revoke all on function private.guard_seller_registration_write() from public, anon, authenticated;
create trigger seller_bank_accounts_00_guard before insert or update or delete on public.seller_bank_accounts
  for each row execute function private.guard_seller_registration_write();
create trigger seller_bank_account_events_00_guard before insert or update or delete on public.seller_bank_account_events
  for each row execute function private.guard_seller_registration_write();
create trigger seller_contacts_00_guard before insert or update or delete on public.seller_contacts
  for each row execute function private.guard_seller_registration_write();

alter table public.seller_bank_accounts enable row level security;
alter table public.seller_bank_account_events enable row level security;
alter table public.seller_contacts enable row level security;
revoke all on public.seller_bank_accounts, public.seller_bank_account_events, public.seller_contacts from public, anon, authenticated;
grant select on public.seller_bank_accounts, public.seller_bank_account_events, public.seller_contacts to authenticated;
-- Bank data: admin, manager and finance only.
create policy seller_bank_accounts_select on public.seller_bank_accounts for select to authenticated
  using (public.has_active_organization_role(organization_id, array['admin', 'manager']) or public.has_permission(organization_id, 'financeiro.view'));
create policy seller_bank_account_events_select on public.seller_bank_account_events for select to authenticated
  using (public.has_active_organization_role(organization_id, array['admin', 'manager']) or public.has_permission(organization_id, 'financeiro.view'));
create policy seller_contacts_select on public.seller_contacts for select to authenticated
  using (public.can_view_seller_profile(organization_id, seller_id));

-- 5. One governed write for the whole registration.
-- p_data: {"name","tax_id","category","group_id","branch_id"?,
--   "profile": {"trade_name","birth_date","rg","rg_issuer","rg_issued_on","mother_name","father_name","mobile","whatsapp",
--               "other_phones","email","zip","street","number","complement","district","city","state",
--               "business_zip",...,"business_state"},
--   "accounts": [{"id"?, "remove"?, "primary"?, "transfer_method","account_type","bank_code","bank_name","branch",
--                 "account_number","account_digit","pix_key_type","pix_key","holder_name","holder_document","note"}],
--   "contacts": [{"name","cpf","role","mobile","email"}]}
create or replace function public.save_seller(p_org uuid, p_seller uuid, p_data jsonb)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_seller uuid;
  v_name text := btrim(coalesce(p_data->>'name', ''));
  v_tax text := regexp_replace(coalesce(p_data->>'tax_id', ''), '\D', '', 'g');
  v_cat text := p_data->>'category';
  v_group uuid;
  v_branch uuid;
  p jsonb := coalesce(p_data->'profile', '{}'::jsonb);
  v_mobile text;
  v_whats text;
  v_email text := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
  a jsonb;
  c jsonb;
  v_acc public.seller_bank_accounts%rowtype;
  v_new public.seller_bank_accounts%rowtype;
  v_id uuid;
  v_primary uuid;
  v_key text;
  v_doc text;
  v_email_re constant text := '^[^\s@]+@[^\s@]+\.[^\s@]+$';
begin
  if auth.uid() is null or p_org is null or not public.has_active_organization_role(p_org, array['admin', 'manager']) then
    raise exception 'not_authorized';
  end if;

  -- Required: name, CPF/CNPJ, mobile, e-mail.
  if length(v_name) not between 1 and 160 then raise exception 'seller_name_required'; end if;
  if not ((length(v_tax) = 11 and private.is_valid_cpf(v_tax)) or (length(v_tax) = 14 and private.is_valid_cnpj(v_tax))) then raise exception 'seller_tax_id_invalid'; end if;
  if coalesce(v_cat, '') not in ('pf', 'pj', 'sub') then raise exception 'seller_category_invalid'; end if;
  v_mobile := private.normalize_phone(coalesce(p->>'mobile', ''));
  if v_mobile is null then raise exception 'seller_mobile_required'; end if;
  if v_email is null or v_email !~ v_email_re then raise exception 'seller_email_required'; end if;
  if nullif(btrim(coalesce(p->>'whatsapp', '')), '') is not null then
    v_whats := private.normalize_phone(p->>'whatsapp');
    if v_whats is null then raise exception 'seller_phone_invalid'; end if;
  end if;
  begin
    v_group := (p_data->>'group_id')::uuid;
    v_branch := nullif(p_data->>'branch_id', '')::uuid;
  exception when others then
    raise exception 'seller_group_invalid';
  end;
  if v_group is null or not exists (select 1 from public.commission_groups g where g.id = v_group and g.organization_id = p_org and g.is_active) then
    raise exception 'seller_group_invalid';
  end if;
  if v_branch is not null and not exists (select 1 from public.organization_branches b where b.id = v_branch and b.organization_id = p_org and b.is_active) then
    raise exception 'seller_branch_invalid';
  end if;
  if exists (select 1 from public.commercial_sellers s where s.organization_id = p_org and regexp_replace(s.tax_id, '[^0-9]', '', 'g') = v_tax and s.id is distinct from p_seller) then
    raise exception 'seller_tax_id_exists';
  end if;

  if p_seller is null then
    insert into public.commercial_sellers (organization_id, name, seller_category, tax_id, commission_group_id, branch_id, created_by)
    values (p_org, v_name, v_cat, v_tax, v_group, v_branch, auth.uid())
    returning id into v_seller;
  else
    select s.id into v_seller from public.commercial_sellers s where s.id = p_seller and s.organization_id = p_org for update;
    if v_seller is null then raise exception 'seller_not_found'; end if;
    update public.commercial_sellers
    set name = v_name, seller_category = v_cat, tax_id = v_tax, commission_group_id = v_group,
        branch_id = coalesce(v_branch, branch_id), updated_at = now()
    where id = v_seller;
  end if;

  perform set_config('corban.seller_profile_rpc', 'on', true);
  insert into public.seller_profiles (organization_id, seller_id, legal_name, trade_name, email, phone, whatsapp, other_phones,
    birth_or_opening_date, identity_or_registration_number, identity_issuer, rg_issued_on, mother_name, father_name,
    zip, street, number, complement, district, city, state,
    business_zip, business_street, business_number, business_complement, business_district, business_city, business_state,
    created_by, updated_by)
  values (p_org, v_seller, v_name, nullif(btrim(p->>'trade_name'), ''), v_email, v_mobile, v_whats, nullif(btrim(p->>'other_phones'), ''),
    nullif(p->>'birth_date', '')::date, nullif(btrim(p->>'rg'), ''), nullif(upper(btrim(p->>'rg_issuer')), ''), nullif(p->>'rg_issued_on', '')::date,
    nullif(btrim(p->>'mother_name'), ''), nullif(btrim(p->>'father_name'), ''),
    nullif(regexp_replace(coalesce(p->>'zip', ''), '\D', '', 'g'), ''), nullif(btrim(p->>'street'), ''), nullif(btrim(p->>'number'), ''),
    nullif(btrim(p->>'complement'), ''), nullif(btrim(p->>'district'), ''), nullif(btrim(p->>'city'), ''), nullif(upper(btrim(p->>'state')), ''),
    nullif(regexp_replace(coalesce(p->>'business_zip', ''), '\D', '', 'g'), ''), nullif(btrim(p->>'business_street'), ''), nullif(btrim(p->>'business_number'), ''),
    nullif(btrim(p->>'business_complement'), ''), nullif(btrim(p->>'business_district'), ''), nullif(btrim(p->>'business_city'), ''),
    nullif(upper(btrim(p->>'business_state')), ''),
    auth.uid(), auth.uid())
  on conflict (organization_id, seller_id) do update set
    legal_name = excluded.legal_name, trade_name = excluded.trade_name, email = excluded.email, phone = excluded.phone,
    whatsapp = excluded.whatsapp, other_phones = excluded.other_phones, birth_or_opening_date = excluded.birth_or_opening_date,
    identity_or_registration_number = excluded.identity_or_registration_number, identity_issuer = excluded.identity_issuer,
    rg_issued_on = excluded.rg_issued_on, mother_name = excluded.mother_name, father_name = excluded.father_name,
    zip = excluded.zip, street = excluded.street, number = excluded.number, complement = excluded.complement,
    district = excluded.district, city = excluded.city, state = excluded.state,
    business_zip = excluded.business_zip, business_street = excluded.business_street, business_number = excluded.business_number,
    business_complement = excluded.business_complement, business_district = excluded.business_district,
    business_city = excluded.business_city, business_state = excluded.business_state,
    updated_by = auth.uid(), updated_at = now();

  perform set_config('corban.seller_rpc', 'on', true);

  -- Bank accounts: existing rows are changed or removed (kept with removed_at); new rows are added. Every change is logged.
  if jsonb_typeof(coalesce(p_data->'accounts', '[]'::jsonb)) <> 'array' then raise exception 'seller_account_invalid'; end if;
  update public.seller_bank_accounts set is_primary = false, updated_at = now() where seller_id = v_seller and is_primary and removed_at is null;
  for a in select * from jsonb_array_elements(coalesce(p_data->'accounts', '[]'::jsonb)) loop
    v_id := nullif(a->>'id', '')::uuid;
    if v_id is not null then
      select * into v_acc from public.seller_bank_accounts x where x.id = v_id and x.seller_id = v_seller and x.removed_at is null;
      if v_acc.id is null then raise exception 'seller_account_not_found'; end if;
      if coalesce((a->>'remove')::boolean, false) then
        update public.seller_bank_accounts set removed_at = now(), removed_by = auth.uid(), is_primary = false, updated_at = now() where id = v_id;
        insert into public.seller_bank_account_events (organization_id, seller_id, account_id, action, before, actor)
        values (p_org, v_seller, v_id, 'removed', to_jsonb(v_acc) - 'is_primary' - 'updated_at', auth.uid());
        continue;
      end if;
    end if;

    v_key := nullif(btrim(coalesce(a->>'pix_key', '')), '');
    if a->>'transfer_method' = 'pix' then
      case a->>'pix_key_type'
        when 'cpf_cnpj' then
          v_key := regexp_replace(coalesce(v_key, ''), '\D', '', 'g');
          if not ((length(v_key) = 11 and private.is_valid_cpf(v_key)) or (length(v_key) = 14 and private.is_valid_cnpj(v_key))) then raise exception 'seller_pix_key_invalid'; end if;
        when 'phone' then
          v_key := private.normalize_phone(coalesce(v_key, ''));
          if v_key is null then raise exception 'seller_pix_key_invalid'; end if;
          v_key := '+' || v_key;
        when 'email' then
          v_key := lower(coalesce(v_key, ''));
          if v_key !~ v_email_re then raise exception 'seller_pix_key_invalid'; end if;
        when 'random' then
          v_key := lower(coalesce(v_key, ''));
          if v_key !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'seller_pix_key_invalid'; end if;
        else raise exception 'seller_pix_key_invalid';
      end case;
    elsif a->>'transfer_method' = 'ted' then
      v_key := null;
    else
      raise exception 'seller_account_invalid';
    end if;
    v_doc := nullif(regexp_replace(coalesce(a->>'holder_document', ''), '\D', '', 'g'), '');
    if v_doc is not null and not ((length(v_doc) = 11 and private.is_valid_cpf(v_doc)) or (length(v_doc) = 14 and private.is_valid_cnpj(v_doc))) then
      raise exception 'seller_holder_invalid';
    end if;

    begin
      if v_id is null then
        insert into public.seller_bank_accounts (organization_id, seller_id, transfer_method, account_type, bank_code, bank_name, branch,
          account_number, account_digit, pix_key_type, pix_key, holder_name, holder_document, note, created_by)
        values (p_org, v_seller, a->>'transfer_method', nullif(a->>'account_type', ''), nullif(btrim(a->>'bank_code'), ''), nullif(btrim(a->>'bank_name'), ''),
          nullif(btrim(a->>'branch'), ''), nullif(btrim(a->>'account_number'), ''), nullif(upper(btrim(a->>'account_digit')), ''),
          case when a->>'transfer_method' = 'pix' then a->>'pix_key_type' end, v_key,
          nullif(btrim(a->>'holder_name'), ''), v_doc, nullif(btrim(a->>'note'), ''), auth.uid())
        returning * into v_new;
        insert into public.seller_bank_account_events (organization_id, seller_id, account_id, action, after, actor)
        values (p_org, v_seller, v_new.id, 'added', to_jsonb(v_new) - 'is_primary' - 'updated_at', auth.uid());
      else
        update public.seller_bank_accounts set
          transfer_method = a->>'transfer_method', account_type = nullif(a->>'account_type', ''), bank_code = nullif(btrim(a->>'bank_code'), ''),
          bank_name = nullif(btrim(a->>'bank_name'), ''), branch = nullif(btrim(a->>'branch'), ''), account_number = nullif(btrim(a->>'account_number'), ''),
          account_digit = nullif(upper(btrim(a->>'account_digit')), ''), pix_key_type = case when a->>'transfer_method' = 'pix' then a->>'pix_key_type' end,
          pix_key = v_key, holder_name = nullif(btrim(a->>'holder_name'), ''), holder_document = v_doc, note = nullif(btrim(a->>'note'), ''), updated_at = now()
        where id = v_id
        returning * into v_new;
        if (to_jsonb(v_new) - 'is_primary' - 'updated_at') is distinct from (to_jsonb(v_acc) - 'is_primary' - 'updated_at') then
          insert into public.seller_bank_account_events (organization_id, seller_id, account_id, action, before, after, actor)
          values (p_org, v_seller, v_id, 'changed', to_jsonb(v_acc) - 'is_primary' - 'updated_at', to_jsonb(v_new) - 'is_primary' - 'updated_at', auth.uid());
        end if;
      end if;
    exception when check_violation then
      raise exception 'seller_account_invalid';
    end;
    if coalesce((a->>'primary')::boolean, false) and v_primary is null then v_primary := v_new.id; end if;
  end loop;
  -- Exactly one primary among the active accounts: the one marked, else the oldest.
  if v_primary is null then
    select x.id into v_primary from public.seller_bank_accounts x where x.seller_id = v_seller and x.removed_at is null order by x.created_at, x.id limit 1;
  end if;
  if v_primary is not null then update public.seller_bank_accounts set is_primary = true where id = v_primary; end if;

  -- Contacts: the list sent replaces the previous one.
  if jsonb_typeof(coalesce(p_data->'contacts', '[]'::jsonb)) <> 'array' then raise exception 'seller_contact_invalid'; end if;
  delete from public.seller_contacts where seller_id = v_seller;
  for c in select * from jsonb_array_elements(coalesce(p_data->'contacts', '[]'::jsonb)) loop
    v_doc := nullif(regexp_replace(coalesce(c->>'cpf', ''), '\D', '', 'g'), '');
    if v_doc is not null and not private.is_valid_cpf(v_doc) then raise exception 'seller_contact_invalid'; end if;
    if nullif(btrim(coalesce(c->>'email', '')), '') is not null and lower(btrim(c->>'email')) !~ v_email_re then raise exception 'seller_contact_invalid'; end if;
    begin
      insert into public.seller_contacts (organization_id, seller_id, name, cpf, role, mobile, email)
      values (p_org, v_seller, btrim(coalesce(c->>'name', '')), v_doc, nullif(btrim(c->>'role'), ''),
        case when nullif(btrim(coalesce(c->>'mobile', '')), '') is null then null else coalesce(private.normalize_phone(c->>'mobile'), 'x') end,
        nullif(lower(btrim(c->>'email')), ''));
    exception when check_violation then
      raise exception 'seller_contact_invalid';
    end;
  end loop;
  perform set_config('corban.seller_rpc', 'off', true);
  perform set_config('corban.seller_profile_rpc', 'off', true);

  return v_seller;
end
$$;

revoke all on function public.save_seller(uuid, uuid, jsonb) from public, anon;
grant execute on function public.save_seller(uuid, uuid, jsonb) to authenticated;

drop function if exists public.upsert_seller_profile(uuid, text, text, text, text, text, date, text, text, text, text);
drop function if exists public.can_view_seller_payment(uuid, uuid);
