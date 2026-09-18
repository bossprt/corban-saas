-- Integration contract V1 structural contract (live objects mirrored in repository migrations).
do $$
declare t text;
begin
 foreach t in array array['integration_adapters','integration_source_bindings','integration_runs','integration_run_artifacts','integration_field_mappings'] loop
  if to_regclass('public.'||t) is null then raise exception 'missing_table_%',t; end if;
  if not (select relrowsecurity from pg_class where oid=('public.'||t)::regclass) then raise exception 'rls_disabled_%',t; end if;
  if has_table_privilege('anon','public.'||t,'SELECT') then raise exception 'anon_select_%',t; end if;
  if has_table_privilege('authenticated','public.'||t,'INSERT') or has_table_privilege('authenticated','public.'||t,'UPDATE') or has_table_privilege('authenticated','public.'||t,'DELETE') then raise exception 'authenticated_write_%',t; end if;
 end loop;
 foreach t in array array['trg_integration_binding_no_secrets','trg_import_batch_adapter_contract','trg_integration_run_consistency','trg_integration_artifact_consistency','trg_import_raw_row_immutable','trg_import_normalized_row_consistency'] loop
  if not exists(select 1 from pg_trigger where tgname=t and not tgisinternal) then raise exception 'missing_trigger_%',t; end if;
 end loop;
 if not exists(select 1 from public.integration_adapters where adapter_key='2tech/busca_contrato_file' and provider_key='2tech' and transport='file') then raise exception 'twotech_adapter_missing'; end if;
 if (select count(*) from public.integration_field_mappings m join public.integration_adapters a on a.id=m.adapter_id where a.adapter_key='2tech/busca_contrato_file' and m.source_field in ('StatusBancoCliente','StatusEmpresaVendedor','StatusProposta','ComissaoRepasseValor'))<4 then raise exception 'twotech_mappings_incomplete'; end if;
 if exists(select 1 from public.integration_adapters where credential_strategy='none' and config_schema::text ~* '(password|senha|api_key|secret)"\s*:\s*"[^"]') then raise exception 'credential_material_in_catalog'; end if;
 -- Bevicred stays experimental (live API deferred).
 if exists(select 1 from public.integration_adapters where provider_key='bevi' and status='active') then raise exception 'bevi_must_remain_experimental'; end if;
end $$;
