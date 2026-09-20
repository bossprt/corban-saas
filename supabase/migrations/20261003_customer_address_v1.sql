-- PREPARED, NOT APPLIED. Customer address (CEP autofill, Commercial Model V3 doc section 19.1). Additive, forward-only, SECURITY INVOKER, no rename/drop.
-- The address lives in its own table (clients is untouched, create_customer_with_timeline keeps its signature). One row per customer, written only through
-- save_customer_address (guard token); the tenant is derived from the customer, never from the caller. No secret, no external call in the database:
-- the CEP lookup is done by the application server against a public, key-less source and only the confirmed address is stored.
create table public.client_addresses(
 client_id uuid primary key references public.clients(id) on delete restrict,
 organization_id uuid not null references public.organizations(id) on delete restrict,
 zip text not null check (zip ~ '^[0-9]{8}$'),
 street text check (street is null or length(btrim(street)) between 1 and 160),
 number text check (number is null or length(btrim(number)) between 1 and 20),
 complement text check (complement is null or length(btrim(complement)) between 1 and 80),
 district text check (district is null or length(btrim(district)) between 1 and 120),
 city text check (city is null or length(btrim(city)) between 1 and 120),
 state text check (state is null or state ~ '^[A-Z]{2}$'),
 source text not null default 'manual' check (source in ('manual','cep_lookup','cep_lookup_edited')),
 updated_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index client_addresses_org_idx on public.client_addresses(organization_id);

-- Only the RPC writes; the tenant is forced from the customer row (a forged organization_id is overwritten, a customer of another tenant is invisible under RLS).
create or replace function public.guard_client_address_write() returns trigger language plpgsql set search_path='' as $$
declare v_org uuid;
begin
 if current_user in ('authenticated','anon') and current_setting('corban.address_rpc',true) is distinct from 'on' then raise exception 'address_write_requires_governed_rpc'; end if;
 select c.organization_id into v_org from public.clients c where c.id=new.client_id;
 if v_org is null or v_org<>new.organization_id then raise exception 'address_tenant_mismatch'; end if;
 if tg_op='UPDATE' and (new.client_id is distinct from old.client_id or new.organization_id is distinct from old.organization_id) then raise exception 'address_identity_is_immutable'; end if;
 new.updated_at:=now();
 return new;
end $$;
create trigger client_addresses_00_guard before insert or update on public.client_addresses for each row execute function public.guard_client_address_write();
alter table public.client_addresses enable row level security;
revoke all on public.client_addresses from public,anon,authenticated;
grant select,insert,update on public.client_addresses to authenticated;
create policy client_addresses_select on public.client_addresses for select to authenticated using (public.is_active_organization_member(organization_id));
create policy client_addresses_insert on public.client_addresses for insert to authenticated with check (public.is_active_organization_member(organization_id));
create policy client_addresses_update on public.client_addresses for update to authenticated using (public.is_active_organization_member(organization_id)) with check (public.is_active_organization_member(organization_id));

create or replace function public.save_customer_address(p_client uuid,p_zip text,p_street text,p_number text,p_complement text,p_district text,p_city text,p_state text,p_source text default 'manual')
returns uuid language plpgsql set search_path='' as $$
declare v_org uuid; v_zip text; v_state text;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select c.organization_id into v_org from public.clients c where c.id=p_client and c.deleted_at is null;
 if v_org is null then raise exception 'customer_not_found_or_forbidden'; end if;
 if not public.is_active_organization_member(v_org) then raise exception 'not_authorized'; end if;
 v_zip:=regexp_replace(coalesce(p_zip,''),'[^0-9]','','g');
 if v_zip !~ '^[0-9]{8}$' then raise exception 'invalid_zip'; end if;
 v_state:=nullif(upper(btrim(coalesce(p_state,''))),'');
 if v_state is not null and v_state !~ '^[A-Z]{2}$' then raise exception 'invalid_state'; end if;
 if p_source is null or p_source not in ('manual','cep_lookup','cep_lookup_edited') then raise exception 'invalid_source'; end if;
 perform set_config('corban.address_rpc','on',true);
 insert into public.client_addresses(client_id,organization_id,zip,street,number,complement,district,city,state,source,updated_by)
  values(p_client,v_org,v_zip,nullif(btrim(p_street),''),nullif(btrim(p_number),''),nullif(btrim(p_complement),''),nullif(btrim(p_district),''),nullif(btrim(p_city),''),v_state,p_source,auth.uid())
  on conflict (client_id) do update set zip=excluded.zip,street=excluded.street,number=excluded.number,complement=excluded.complement,district=excluded.district,city=excluded.city,state=excluded.state,source=excluded.source,updated_by=excluded.updated_by;
 perform set_config('corban.address_rpc','off',true);
 return p_client;
end $$;
revoke all on function public.guard_client_address_write() from public,anon,authenticated;
revoke all on function public.save_customer_address(uuid,text,text,text,text,text,text,text,text) from public,anon;
grant execute on function public.save_customer_address(uuid,text,text,text,text,text,text,text,text) to authenticated;
