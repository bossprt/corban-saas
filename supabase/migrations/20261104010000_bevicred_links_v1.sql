-- What the owner taught the Bevicred contract import (03/11/2026): the Corban table for a Bevicred table ("operação")
-- and the Corban seller for a Bevicred partner code. The first time a line has no known table or seller the owner picks
-- one; the choice is saved here at import and used on every later search. The company's administrator sees the list
-- in Configuração > Bevicred and can forget a wrong one. Tenants never touch the table: only the server (service role),
-- after checking the user's permission in the company, reads and writes it, always filtered by the company.
-- Contract: tests/security/bevicred-links-contract.sql

create table public.bevicred_links (
  organization_id uuid not null references public.organizations(id) on delete restrict,
  kind text not null check (kind in ('table', 'seller')),
  external_key text not null check (length(external_key) between 1 and 200),
  external_label text not null check (length(external_label) between 1 and 200),
  target_id uuid not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  primary key (organization_id, kind, external_key)
);

alter table public.bevicred_links enable row level security;
revoke all on public.bevicred_links from anon, authenticated;

-- A link must point to a table or seller of the same company.
create or replace function private.guard_bevicred_link_target()
returns trigger language plpgsql set search_path to '' as $$
begin
  if new.kind = 'table' and not exists (select 1 from public.product_tables t where t.id = new.target_id and t.organization_id = new.organization_id) then
    raise exception 'bevicred_link_target_not_in_company';
  end if;
  if new.kind = 'seller' and not exists (select 1 from public.commercial_sellers s where s.id = new.target_id and s.organization_id = new.organization_id) then
    raise exception 'bevicred_link_target_not_in_company';
  end if;
  return new;
end
$$;
revoke all on function private.guard_bevicred_link_target() from public, anon, authenticated;
create trigger bevicred_links_target before insert or update on public.bevicred_links
  for each row execute function private.guard_bevicred_link_target();
