-- Mirror of live migration 20260918215026 canonical_mapping_and_raw_immutability_v1 (already applied).
-- Repository reconciliation only; do not re-apply as new history.
create table public.integration_field_mappings (
 id uuid primary key default gen_random_uuid(),
 adapter_id uuid not null references public.integration_adapters(id),
 contract_version text not null,
 source_field text not null,
 canonical_field text not null,
 transform_key text not null default 'identity',
 semantic_class text not null default 'descriptive' check (semantic_class in ('identity','descriptive','status','commercial','financial','sensitive')),
 required boolean not null default false,
 notes text,
 created_at timestamptz not null default now(),
 unique(adapter_id,contract_version,source_field,canonical_field)
);
alter table public.integration_field_mappings enable row level security;
revoke all on public.integration_field_mappings from anon,authenticated;
grant select on public.integration_field_mappings to authenticated;
create policy integration_field_mappings_read on public.integration_field_mappings for select to authenticated using(true);
create index integration_field_mappings_adapter_idx on public.integration_field_mappings(adapter_id,contract_version);

insert into public.integration_field_mappings(adapter_id,contract_version,source_field,canonical_field,transform_key,semantic_class,required,notes)
select a.id,'1.0.0',v.source_field,v.canonical_field,v.transform_key,v.semantic_class,v.required,v.notes
from public.integration_adapters a
cross join (values
 ('StatusBancoCliente','normalized_payload.source_status.bank_client','trim_text','status',false,'Preserve independently; never collapse into proposal or vendor payment status.'),
 ('StatusEmpresaVendedor','normalized_payload.source_status.company_vendor','trim_text','status',false,'Preserve independently; not financial truth by itself.'),
 ('StatusProposta','normalized_payload.source_status.proposal','trim_text','status',false,'Source proposal status; canonical state transition still requires policy/evidence.'),
 ('ComissaoRepasseValor','normalized_payload.source_commission.repasse_value','decimal_br','financial',false,'Observed source value only; zero/blank must not be inferred as no revenue.')
) v(source_field,canonical_field,transform_key,semantic_class,required,notes)
where a.adapter_key='2tech/busca_contrato_file'
on conflict do nothing;

create or replace function public.guard_import_raw_row_immutable()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin raise exception 'import_raw_rows are immutable; append a new batch/row instead'; end $$;
revoke all on function public.guard_import_raw_row_immutable() from public,anon,authenticated;
drop trigger if exists trg_import_raw_row_immutable on public.import_raw_rows;
create trigger trg_import_raw_row_immutable before update or delete on public.import_raw_rows
for each row execute function public.guard_import_raw_row_immutable();

create or replace function public.guard_import_normalized_row_consistency()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare raw_org uuid;
begin
 select organization_id into raw_org from public.import_raw_rows where id=new.raw_row_id;
 if raw_org is null or raw_org<>new.organization_id then raise exception 'normalized row organization mismatch'; end if;
 if jsonb_typeof(new.normalized_payload)<>'object' then raise exception 'normalized_payload must be object'; end if;
 if new.record_kind in ('proposal','commission','payment','status') and coalesce(btrim(new.external_proposal_number),'')='' then
   raise exception 'external proposal number required for record kind %',new.record_kind;
 end if;
 return new;
end $$;
revoke all on function public.guard_import_normalized_row_consistency() from public,anon,authenticated;
drop trigger if exists trg_import_normalized_row_consistency on public.import_normalized_rows;
create trigger trg_import_normalized_row_consistency before insert or update on public.import_normalized_rows
for each row execute function public.guard_import_normalized_row_consistency();

comment on table public.integration_field_mappings is 'Versioned adapter-to-canonical mapping contract. Source-specific semantics remain explicit and do not become financial truth automatically.';
