-- CORBAN OS — Seller full profile + payout readiness V1
-- PREPARED ONLY. Requires explicit Human Gate before LIVE apply.
-- Goal: seller registry equal-or-better than legacy 2Tech, with versioned payout data.

create table public.seller_profiles(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  seller_id uuid not null,
  legal_name text,
  trade_name text,
  email text,
  phone text,
  whatsapp text,
  birth_or_opening_date date,
  identity_or_registration_number text,
  identity_issuer text,
  occupation text,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,id),
  unique(organization_id,seller_id),
  foreign key(organization_id,seller_id)
    references public.commercial_sellers(organization_id,id) on delete restrict
);

create table public.seller_addresses(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  seller_id uuid not null,
  label text not null default 'principal',
  postal_code text,
  street text,
  number text,
  complement text,
  neighborhood text,
  city text,
  state text,
  country_code text not null default 'BR',
  valid_from timestamptz not null default now(),
  valid_until timestamptz,
  is_current boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(organization_id,id),
  foreign key(organization_id,seller_id)
    references public.commercial_sellers(organization_id,id) on delete restrict,
  check(valid_until is null or valid_until>valid_from)
);
create unique index seller_addresses_one_current
  on public.seller_addresses(organization_id,seller_id)
  where is_current;

create table public.seller_payment_accounts(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  seller_id uuid not null,
  bank_id uuid references public.banks(id) on delete restrict,
  bank_code_snapshot text,
  bank_name_snapshot text not null,
  branch text,
  account_number text,
  account_digit text,
  account_type text check(account_type is null or account_type in ('checking','savings','payment','other')),
  holder_name text not null,
  holder_document text not null,
  pix_key_type text check(pix_key_type is null or pix_key_type in ('cpf','cnpj','email','phone','random')),
  pix_key text,
  verification_status text not null default 'unverified' check(verification_status in ('unverified','verified','rejected')),
  payment_enabled boolean not null default true,
  valid_from timestamptz not null default now(),
  valid_until timestamptz,
  is_current boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(organization_id,id),
  foreign key(organization_id,seller_id)
    references public.commercial_sellers(organization_id,id) on delete restrict,
  check(valid_until is null or valid_until>valid_from),
  check(account_number is not null or pix_key is not null)
);
create unique index seller_payment_accounts_one_current
  on public.seller_payment_accounts(organization_id,seller_id)
  where is_current;

create table public.seller_certifications(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  seller_id uuid not null,
  name text not null,
  issuer text,
  certificate_number text,
  issued_at date,
  expires_at date,
  status text not null default 'active' check(status in ('active','expired','revoked','pending')),
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,id),
  foreign key(organization_id,seller_id)
    references public.commercial_sellers(organization_id,id) on delete restrict,
  check(expires_at is null or issued_at is null or expires_at>=issued_at)
);

insert into public.seller_profiles(organization_id,seller_id,legal_name,created_by,updated_by)
select s.organization_id,s.id,s.name,s.created_by,s.created_by
from public.commercial_sellers s
where not exists(
  select 1 from public.seller_profiles p
  where p.organization_id=s.organization_id and p.seller_id=s.id
);

create or replace function public.can_view_seller_profile(p_org uuid,p_seller uuid)
returns boolean
language sql stable security invoker set search_path=''
as $$
  select
    public.has_active_organization_role(p_org,array['admin','manager'])
    or exists(
      select 1 from public.commercial_sellers s
      where s.organization_id=p_org and s.id=p_seller
        and s.user_id=auth.uid() and s.is_active
    )
    or (
      public.has_active_organization_role(p_org,array['supervisor'])
      and exists(
        select 1 from public.seller_supervisions ss
        where ss.organization_id=p_org
          and ss.seller_id=p_seller
          and ss.supervisor_user_id=auth.uid()
          and ss.is_active
      )
    )
$$;

create or replace function public.can_view_seller_payment(p_org uuid,p_seller uuid)
returns boolean
language sql stable security invoker set search_path=''
as $$
  select
    public.has_active_organization_role(p_org,array['admin','manager'])
    or exists(
      select 1 from public.commercial_sellers s
      where s.organization_id=p_org and s.id=p_seller
        and s.user_id=auth.uid() and s.is_active
    )
$$;

create or replace function public.guard_seller_profile_write()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if current_user in ('authenticated','anon')
     and current_setting('corban.seller_profile_rpc',true) is distinct from 'on'
  then raise exception 'seller_profile_write_requires_governed_rpc'; end if;
  if tg_op='DELETE' then raise exception 'seller_profile_delete_forbidden'; end if;
  return new;
end
$$;

create trigger seller_profiles_00_guard
before insert or update or delete on public.seller_profiles
for each row execute function public.guard_seller_profile_write();
create trigger seller_addresses_00_guard
before insert or update or delete on public.seller_addresses
for each row execute function public.guard_seller_profile_write();
create trigger seller_payment_accounts_00_guard
before insert or update or delete on public.seller_payment_accounts
for each row execute function public.guard_seller_profile_write();
create trigger seller_certifications_00_guard
before insert or update or delete on public.seller_certifications
for each row execute function public.guard_seller_profile_write();

create or replace function public.upsert_seller_profile(
  p_seller_id uuid,
  p_legal_name text,
  p_trade_name text,
  p_email text,
  p_phone text,
  p_whatsapp text,
  p_birth_or_opening_date date,
  p_identity_or_registration_number text,
  p_identity_issuer text,
  p_occupation text,
  p_notes text
)
returns uuid
language plpgsql security invoker set search_path=''
as $$
declare v_org uuid; v_id uuid;
begin
  select s.organization_id into v_org
  from public.commercial_sellers s
  where s.id=p_seller_id;
  if v_org is null then raise exception 'seller_not_found'; end if;
  if not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'forbidden'; end if;

  perform set_config('corban.seller_profile_rpc','on',true);
  insert into public.seller_profiles(
    organization_id,seller_id,legal_name,trade_name,email,phone,whatsapp,birth_or_opening_date,
    identity_or_registration_number,identity_issuer,occupation,notes,created_by,updated_by
  ) values(
    v_org,p_seller_id,nullif(btrim(p_legal_name),''),nullif(btrim(p_trade_name),''),
    nullif(lower(btrim(p_email)),''),nullif(btrim(p_phone),''),nullif(btrim(p_whatsapp),''),
    p_birth_or_opening_date,nullif(btrim(p_identity_or_registration_number),''),
    nullif(btrim(p_identity_issuer),''),nullif(btrim(p_occupation),''),nullif(btrim(p_notes),''),
    auth.uid(),auth.uid()
  )
  on conflict(organization_id,seller_id) do update set
    legal_name=excluded.legal_name,
    trade_name=excluded.trade_name,
    email=excluded.email,
    phone=excluded.phone,
    whatsapp=excluded.whatsapp,
    birth_or_opening_date=excluded.birth_or_opening_date,
    identity_or_registration_number=excluded.identity_or_registration_number,
    identity_issuer=excluded.identity_issuer,
    occupation=excluded.occupation,
    notes=excluded.notes,
    updated_by=auth.uid(),
    updated_at=now()
  returning id into v_id;
  perform set_config('corban.seller_profile_rpc','off',true);
  return v_id;
end
$$;

create or replace function public.replace_seller_address(
  p_seller_id uuid,
  p_postal_code text,
  p_street text,
  p_number text,
  p_complement text,
  p_neighborhood text,
  p_city text,
  p_state text
)
returns uuid
language plpgsql security invoker set search_path=''
as $$
declare v_org uuid; v_id uuid;
begin
  select organization_id into v_org from public.commercial_sellers where id=p_seller_id;
  if v_org is null then raise exception 'seller_not_found'; end if;
  if not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'forbidden'; end if;

  perform set_config('corban.seller_profile_rpc','on',true);
  update public.seller_addresses
     set is_current=false,valid_until=now()
   where organization_id=v_org and seller_id=p_seller_id and is_current;

  insert into public.seller_addresses(
    organization_id,seller_id,postal_code,street,number,complement,neighborhood,city,state,created_by
  ) values(
    v_org,p_seller_id,nullif(regexp_replace(coalesce(p_postal_code,''),'[^0-9]','','g'),''),
    nullif(btrim(p_street),''),nullif(btrim(p_number),''),nullif(btrim(p_complement),''),
    nullif(btrim(p_neighborhood),''),nullif(btrim(p_city),''),upper(nullif(btrim(p_state),'')),auth.uid()
  ) returning id into v_id;
  perform set_config('corban.seller_profile_rpc','off',true);
  return v_id;
end
$$;

create or replace function public.set_seller_payment_account(
  p_seller_id uuid,
  p_bank_id uuid,
  p_branch text,
  p_account_number text,
  p_account_digit text,
  p_account_type text,
  p_holder_name text,
  p_holder_document text,
  p_pix_key_type text,
  p_pix_key text
)
returns uuid
language plpgsql security invoker set search_path=''
as $$
declare v_org uuid; v_id uuid; v_bank_code text; v_bank_name text;
begin
  select organization_id into v_org from public.commercial_sellers where id=p_seller_id;
  if v_org is null then raise exception 'seller_not_found'; end if;
  if not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'forbidden'; end if;

  if p_bank_id is not null then
    select code,name into v_bank_code,v_bank_name from public.banks where id=p_bank_id and is_active;
    if v_bank_name is null then raise exception 'active_bank_required'; end if;
  else
    v_bank_name:='PIX';
  end if;

  if nullif(btrim(coalesce(p_account_number,'')),'') is null
     and nullif(btrim(coalesce(p_pix_key,'')),'') is null
  then raise exception 'account_or_pix_required'; end if;

  perform set_config('corban.seller_profile_rpc','on',true);
  update public.seller_payment_accounts
     set is_current=false,valid_until=now()
   where organization_id=v_org and seller_id=p_seller_id and is_current;

  insert into public.seller_payment_accounts(
    organization_id,seller_id,bank_id,bank_code_snapshot,bank_name_snapshot,branch,
    account_number,account_digit,account_type,holder_name,holder_document,pix_key_type,pix_key,created_by
  ) values(
    v_org,p_seller_id,p_bank_id,v_bank_code,v_bank_name,
    nullif(btrim(p_branch),''),nullif(btrim(p_account_number),''),nullif(btrim(p_account_digit),''),
    nullif(btrim(p_account_type),''),btrim(p_holder_name),
    regexp_replace(coalesce(p_holder_document,''),'[^0-9]','','g'),
    nullif(btrim(p_pix_key_type),''),nullif(btrim(p_pix_key),''),auth.uid()
  ) returning id into v_id;
  perform set_config('corban.seller_profile_rpc','off',true);
  return v_id;
end
$$;

create or replace function public.upsert_seller_certification(
  p_id uuid,
  p_seller_id uuid,
  p_name text,
  p_issuer text,
  p_certificate_number text,
  p_issued_at date,
  p_expires_at date,
  p_status text,
  p_notes text
)
returns uuid
language plpgsql security invoker set search_path=''
as $$
declare v_org uuid; v_id uuid;
begin
  select organization_id into v_org from public.commercial_sellers where id=p_seller_id;
  if v_org is null then raise exception 'seller_not_found'; end if;
  if not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'forbidden'; end if;
  if p_status not in ('active','expired','revoked','pending') then raise exception 'invalid_certification_status'; end if;

  perform set_config('corban.seller_profile_rpc','on',true);
  if p_id is null then
    insert into public.seller_certifications(
      organization_id,seller_id,name,issuer,certificate_number,issued_at,expires_at,status,notes,created_by,updated_by
    ) values(
      v_org,p_seller_id,btrim(p_name),nullif(btrim(p_issuer),''),nullif(btrim(p_certificate_number),''),
      p_issued_at,p_expires_at,p_status,nullif(btrim(p_notes),''),auth.uid(),auth.uid()
    ) returning id into v_id;
  else
    update public.seller_certifications
       set name=btrim(p_name),issuer=nullif(btrim(p_issuer),''),
           certificate_number=nullif(btrim(p_certificate_number),''),
           issued_at=p_issued_at,expires_at=p_expires_at,status=p_status,
           notes=nullif(btrim(p_notes),''),updated_by=auth.uid(),updated_at=now()
     where organization_id=v_org and id=p_id and seller_id=p_seller_id
     returning id into v_id;
    if v_id is null then raise exception 'certification_not_found'; end if;
  end if;
  perform set_config('corban.seller_profile_rpc','off',true);
  return v_id;
end
$$;

alter table public.seller_profiles enable row level security;
alter table public.seller_addresses enable row level security;
alter table public.seller_payment_accounts enable row level security;
alter table public.seller_certifications enable row level security;

revoke all on public.seller_profiles,public.seller_addresses,public.seller_payment_accounts,public.seller_certifications
from public,anon,authenticated;
grant select,insert,update on public.seller_profiles,public.seller_addresses,public.seller_certifications to authenticated;
grant select,insert,update on public.seller_payment_accounts to authenticated;

create policy seller_profiles_select_scoped on public.seller_profiles
for select to authenticated using(public.can_view_seller_profile(organization_id,seller_id));
create policy seller_addresses_select_scoped on public.seller_addresses
for select to authenticated using(public.can_view_seller_profile(organization_id,seller_id));
create policy seller_certifications_select_scoped on public.seller_certifications
for select to authenticated using(public.can_view_seller_profile(organization_id,seller_id));
create policy seller_payment_accounts_select_scoped on public.seller_payment_accounts
for select to authenticated using(public.can_view_seller_payment(organization_id,seller_id));

create policy seller_profiles_write_manager on public.seller_profiles
for all to authenticated using(public.has_active_organization_role(organization_id,array['admin','manager']))
with check(public.has_active_organization_role(organization_id,array['admin','manager']));
create policy seller_addresses_write_manager on public.seller_addresses
for all to authenticated using(public.has_active_organization_role(organization_id,array['admin','manager']))
with check(public.has_active_organization_role(organization_id,array['admin','manager']));
create policy seller_certifications_write_manager on public.seller_certifications
for all to authenticated using(public.has_active_organization_role(organization_id,array['admin','manager']))
with check(public.has_active_organization_role(organization_id,array['admin','manager']));
create policy seller_payment_accounts_write_manager on public.seller_payment_accounts
for all to authenticated using(public.has_active_organization_role(organization_id,array['admin','manager']))
with check(public.has_active_organization_role(organization_id,array['admin','manager']));

revoke all on function public.guard_seller_profile_write() from public,anon,authenticated;
revoke all on function public.can_view_seller_profile(uuid,uuid) from public,anon;
grant execute on function public.can_view_seller_profile(uuid,uuid) to authenticated;
revoke all on function public.can_view_seller_payment(uuid,uuid) from public,anon;
grant execute on function public.can_view_seller_payment(uuid,uuid) to authenticated;
revoke all on function public.upsert_seller_profile(uuid,text,text,text,text,text,date,text,text,text,text) from public,anon;
grant execute on function public.upsert_seller_profile(uuid,text,text,text,text,text,date,text,text,text,text) to authenticated;
revoke all on function public.replace_seller_address(uuid,text,text,text,text,text,text,text) from public,anon;
grant execute on function public.replace_seller_address(uuid,text,text,text,text,text,text,text) to authenticated;
revoke all on function public.set_seller_payment_account(uuid,uuid,text,text,text,text,text,text,text,text) from public,anon;
grant execute on function public.set_seller_payment_account(uuid,uuid,text,text,text,text,text,text,text,text) to authenticated;
revoke all on function public.upsert_seller_certification(uuid,uuid,text,text,text,date,date,text,text) from public,anon;
grant execute on function public.upsert_seller_certification(uuid,uuid,text,text,text,date,date,text,text) to authenticated;
