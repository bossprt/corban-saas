-- Customer 360 migration contract tests (static/pre-apply + post-apply assertions)
-- These queries are designed for CI/controlled DB verification.

-- Post-apply structural assertions should all return true.
select
  to_regclass('public.customer_addresses') is not null as has_addresses,
  to_regclass('public.customer_bank_accounts') is not null as has_bank_accounts,
  to_regclass('public.customer_pix_keys') is not null as has_pix_keys,
  to_regclass('public.customer_timeline_events') is not null as has_timeline;

select
  exists (
    select 1 from pg_indexes
    where schemaname='public'
      and tablename='clients'
      and indexname='clients_org_cpf_active_uniq'
      and indexdef ilike '%WHERE (deleted_at IS NULL)%'
  ) as cpf_partial_unique_present;

select c.relname as table_name, c.relrowsecurity as rls_enabled
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public'
  and c.relname in ('customer_addresses','customer_bank_accounts','customer_pix_keys','customer_timeline_events')
order by c.relname;

-- authenticated must not have DELETE on any Customer 360 child table.
select table_name, bool_or(privilege_type='DELETE') as authenticated_has_delete
from information_schema.role_table_grants
where table_schema='public'
  and grantee='authenticated'
  and table_name in ('customer_addresses','customer_bank_accounts','customer_pix_keys','customer_timeline_events')
group by table_name
order by table_name;

-- Timeline must expose only SELECT/INSERT to authenticated.
select privilege_type
from information_schema.role_table_grants
where table_schema='public'
  and table_name='customer_timeline_events'
  and grantee='authenticated'
order by privilege_type;

-- Composite tenant FKs must exist.
select conname, pg_get_constraintdef(oid) definition
from pg_constraint
where connamespace='public'::regnamespace
  and conname in (
    'customer_addresses_customer_tenant_fk',
    'customer_bank_accounts_customer_tenant_fk',
    'customer_pix_keys_customer_tenant_fk',
    'customer_pix_keys_bank_account_customer_fk',
    'customer_timeline_customer_tenant_fk'
  )
order by conname;


select indexname,indexdef from pg_indexes
where schemaname='public' and indexname in (
 'customer_bank_accounts_one_primary_per_customer',
 'customer_pix_keys_one_primary_per_customer',
 'customer_bank_accounts_org_customer_id_key'
) order by indexname;
