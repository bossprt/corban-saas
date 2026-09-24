-- F0 test tenant: fictitious company for local and non-production databases only.
--
-- Guard: runs only when the session declares a test environment. Production never sets this,
-- so running the file there by mistake aborts before writing anything:
--   set corban.env = 'test';
--   \i supabase/seed/f0-test-tenant.sql
--
-- Users are not created here. Create them through Supabase Auth (Studio or admin API) and then
-- insert organization_memberships rows for the ids Auth returns.
--
-- Validated on the local Supabase restored from supabase/baseline (F0). Includes a minimal commercial structure
-- (bank, agreement, route, published table version) so proposals can be created in tests.

begin;

do $$
begin
  if current_setting('corban.env', true) is distinct from 'test' then
    raise exception 'f0-test-tenant.sql refused: set corban.env = ''test'' in a non-production database';
  end if;
end $$;

-- Valid CPF check digits for fictitious 9-digit bases.
create or replace function pg_temp.cpf_with_digits(base text) returns text
language plpgsql immutable as $$
declare
  s int; d1 int; d2 int; i int;
begin
  s := 0;
  for i in 1..9 loop s := s + substr(base, i, 1)::int * (11 - i); end loop;
  d1 := case when s % 11 < 2 then 0 else 11 - s % 11 end;
  s := 0;
  for i in 1..9 loop s := s + substr(base, i, 1)::int * (12 - i); end loop;
  s := s + d1 * 2;
  d2 := case when s % 11 < 2 then 0 else 11 - s % 11 end;
  return base || d1::text || d2::text;
end $$;

insert into public.organizations (id, name, document, plan_type, is_active)
values ('00000000-0000-4000-8000-00000000c0b1', 'Corban Teste Ltda', '00000000000191', 'test', true)
on conflict (id) do nothing;

insert into public.organization_branches (organization_id, code, name, branch_type, is_active)
values
  ('00000000-0000-4000-8000-00000000c0b1', 'MTZ', 'Matriz', 'matrix', true),
  ('00000000-0000-4000-8000-00000000c0b1', 'NORTE', 'Filial Norte', 'branch', true)
on conflict (organization_id, code) do nothing;

insert into public.clients (organization_id, full_name, cpf, phone, email, birth_date, original_source)
select '00000000-0000-4000-8000-00000000c0b1', v.full_name, pg_temp.cpf_with_digits(v.base), v.phone, v.email, v.birth_date::date, 'manual'
from (values
  ('Maria Teste Silva',   '100000001', '+5568999000001', 'maria.teste@example.com',   '1958-03-14'),
  ('João Teste Pereira',  '100000002', '+5568999000002', 'joao.teste@example.com',    '1961-07-02'),
  ('Ana Teste Lopes',     '100000003', '+5568999000003', null,                        '1970-11-23'),
  ('Pedro Teste Alves',   '100000004', '+5568999000004', 'pedro.teste@example.com',   '1966-01-30'),
  ('Luiza Teste Rocha',   '100000005', '+5568999000005', null,                        '1955-09-09')
) as v(full_name, base, phone, email, birth_date)
where not exists (
  select 1 from public.clients c
  where c.organization_id = '00000000-0000-4000-8000-00000000c0b1' and c.cpf = pg_temp.cpf_with_digits(v.base)
);

insert into public.leads (organization_id, status, channel, full_name, phone, metadata)
select '00000000-0000-4000-8000-00000000c0b1', v.status, v.channel, v.full_name, v.phone, '{"seed":"f0"}'::jsonb
from (values
  ('new',       'api',      'Otávio Teste Reis',   '+5568999000011'),
  ('contacted', 'whatsapp', 'Helena Teste Costa',  '+5568999000012'),
  ('qualified', 'manual',   'Fábio Teste Torres',  '+5568999000013')
) as v(status, channel, full_name, phone)
where not exists (
  select 1 from public.leads l
  where l.organization_id = '00000000-0000-4000-8000-00000000c0b1' and l.phone = v.phone
);

-- Minimal commercial structure: one bank, one agreement, one route and one published table version.
insert into public.organization_banks (id, organization_id, name, tech_key, is_active)
values ('00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-00000000c0b1', 'Banco Teste', 'banco_teste', true)
on conflict (id) do nothing;
insert into public.organization_agreements (id, organization_id, name)
values ('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-00000000c0b1', 'INSS Teste')
on conflict (id) do nothing;
insert into public.organization_product_routes (id, organization_id, org_bank_id, org_agreement_id, production_origin, status)
values ('00000000-0000-4000-8000-0000000c0101', '00000000-0000-4000-8000-00000000c0b1', '00000000-0000-4000-8000-0000000b0001', '00000000-0000-4000-8000-0000000a0001', 'own', 'active')
on conflict (id) do nothing;
insert into public.product_tables (id, organization_id, route_id, code, name, status)
values ('00000000-0000-4000-8000-0000000c0201', '00000000-0000-4000-8000-00000000c0b1', '00000000-0000-4000-8000-0000000c0101', 'TT1', 'Tabela Teste INSS', 'active')
on conflict (id) do nothing;
insert into public.product_table_versions (id, organization_id, product_table_id, version, status, published_at, term_min, term_max)
values ('00000000-0000-4000-8000-0000000c0301', '00000000-0000-4000-8000-00000000c0b1', '00000000-0000-4000-8000-0000000c0201', 1, 'published', now(), 12, 96)
on conflict (id) do nothing;

commit;
