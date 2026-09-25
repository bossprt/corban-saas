-- Mirror of live migration 20260918212948 provider_agnostic_integration_contract_v1 (already applied).
-- Repository reconciliation only; do not re-apply as new history.
create table public.integration_adapters (
 id uuid primary key default gen_random_uuid(),
 adapter_key text not null unique,
 provider_key text not null,
 transport text not null check (transport in ('file','api','webhook','sftp','manual')),
 name text not null,
 contract_version text not null,
 capabilities jsonb not null default '[]'::jsonb check (jsonb_typeof(capabilities)='array'),
 config_schema jsonb not null default '{}'::jsonb check (jsonb_typeof(config_schema)='object'),
 credential_strategy text not null default 'none' check (credential_strategy in ('none','runtime_secret','oauth','external_vault')),
 status text not null default 'active' check (status in ('active','experimental','disabled')),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
alter table public.integration_adapters enable row level security;
revoke all on table public.integration_adapters from anon, authenticated;
grant select on table public.integration_adapters to authenticated;
create policy integration_adapters_authenticated_read on public.integration_adapters for select to authenticated using (true);

create table public.integration_source_bindings (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id),
 source_id uuid not null references public.import_sources(id),
 adapter_id uuid not null references public.integration_adapters(id),
 external_account_code text,
 settings jsonb not null default '{}'::jsonb check (jsonb_typeof(settings)='object'),
 enabled boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(organization_id,source_id,adapter_id)
);
alter table public.integration_source_bindings enable row level security;
revoke all on table public.integration_source_bindings from anon, authenticated;
grant select on table public.integration_source_bindings to authenticated;
create policy integration_source_bindings_org_read on public.integration_source_bindings for select to authenticated
using (organization_id in (select organization_id from public.organization_memberships where user_id=(select auth.uid()) and status='active'));

alter table public.import_batches
 add column if not exists adapter_id uuid references public.integration_adapters(id),
 add column if not exists adapter_contract_version text,
 add column if not exists external_batch_id text,
 add column if not exists occurred_at timestamptz;

create unique index if not exists import_batches_source_external_batch_uidx
 on public.import_batches(organization_id,source_id,external_batch_id) where external_batch_id is not null;
create index if not exists integration_source_bindings_org_idx on public.integration_source_bindings(organization_id);
create index if not exists integration_source_bindings_source_idx on public.integration_source_bindings(source_id);
create index if not exists integration_source_bindings_adapter_idx on public.integration_source_bindings(adapter_id);
create index if not exists import_batches_adapter_idx on public.import_batches(adapter_id) where adapter_id is not null;

insert into public.integration_adapters(adapter_key,provider_key,transport,name,contract_version,capabilities,config_schema,credential_strategy,status)
values
('2tech/busca_contrato_file','2tech','file','2Tech BuscaContrato - arquivo','1.0.0',
 '["proposal","status","production","commission","commercial_lineage"]'::jsonb,
 '{"accepted_formats":["xlsx","xls","csv","html_excel"],"preserve_raw":true,"financial_truth":"evidence_required"}'::jsonb,'none','active'),
('bevi/webservice_agente','bevi','api','Bevi Webservice AGENTE','1.0.0',
 '["contract_pending_physical","contract_pending_issue","paid_incentives","bank_production","workbank","synthetic_production","adhesion_lookup"]'::jsonb,
 '{"method":"POST","auth":"basic_plus_token","response_formats":["json","xml"],"token_ip_bound":true,"token_ttl_days":3,"secrets_persisted":false}'::jsonb,'runtime_secret','experimental')
on conflict(adapter_key) do update set capabilities=excluded.capabilities,config_schema=excluded.config_schema,contract_version=excluded.contract_version,updated_at=now();

comment on table public.integration_adapters is 'Provider-agnostic adapter catalog. Never store credentials here.';
comment on table public.integration_source_bindings is 'Tenant/source adapter binding. settings must contain non-secret configuration only.';
