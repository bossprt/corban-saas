-- Contract for Import Staging & Lineage V0.
do $$
begin
 if to_regclass('public.import_sources') is null then raise exception 'import_sources_missing'; end if;
 if to_regclass('public.import_batches') is null then raise exception 'import_batches_missing'; end if;
 if to_regclass('public.import_raw_rows') is null then raise exception 'import_raw_rows_missing'; end if;
 if to_regclass('public.import_normalized_rows') is null then raise exception 'import_normalized_rows_missing'; end if;
 if to_regclass('public.import_match_candidates') is null then raise exception 'import_match_candidates_missing'; end if;
 if to_regclass('public.import_decisions') is null then raise exception 'import_decisions_missing'; end if;
 if exists(select 1 from information_schema.role_table_grants where table_schema='public' and table_name like 'import_%' and grantee='anon') then raise exception 'anon_import_access'; end if;
end $$;
