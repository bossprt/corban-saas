-- Publish the three PROSESP tables (Governo do Acre: Comissionado, Efetivo, Temporário) with vigência from 01/01/2026.
--
-- They were imported on 21/09/2026 as drafts without a start date, so they never reached simulation or proposals.
-- Owner decision 29/09/2026: vigência starts 01/01/2026 (midnight in Brasília).
--
-- Same rules as public.publish_product_table_version (which needs a signed-in user, so it cannot run in a migration):
-- only a draft, only with commission lines, through the governed catalog flag. These tables have no other version,
-- so nothing is superseded; the migration refuses to run if that is no longer true. Databases without these tables
-- (local, test) are left untouched.

do $$
declare
  v_start constant timestamptz := '2026-01-01 00:00:00-03';
  v_codes constant text[] := array['prosesp-ac-comissionado', 'prosesp-ac-efetivo', 'prosesp-ac-temporario'];
  v_targets uuid[];
  v_published integer;
begin
  select coalesce(array_agg(v.id), '{}') into v_targets
  from public.product_table_versions v
  join public.product_tables t on t.id = v.product_table_id and t.organization_id = v.organization_id
  where t.code = any (v_codes) and t.status = 'active' and v.status = 'draft';

  if cardinality(v_targets) = 0 then
    raise notice 'prosesp tables: nothing to publish';
    return;
  end if;
  if cardinality(v_targets) <> 3 then raise exception 'prosesp_tables_unexpected_draft_count: %', cardinality(v_targets); end if;

  if exists (select 1 from public.product_table_versions v where v.id = any (v_targets)
             and not exists (select 1 from public.commercial_conditions c where c.product_table_version_id = v.id and c.organization_id = v.organization_id)) then
    raise exception 'prosesp_tables_without_lines';
  end if;
  if exists (select 1 from public.product_table_versions o
             join public.product_table_versions v on v.product_table_id = o.product_table_id and v.id = any (v_targets)
             where o.id <> v.id) then
    raise exception 'prosesp_tables_have_other_versions';
  end if;

  perform set_config('corban.catalog_rpc', 'on', true);
  update public.product_table_versions set effective_from = v_start where id = any (v_targets);
  update public.product_table_versions set status = 'published', published_at = now() where id = any (v_targets);
  get diagnostics v_published = row_count;
  perform set_config('corban.catalog_rpc', 'off', true);

  if v_published <> 3 then raise exception 'prosesp_tables_publish_failed'; end if;
  raise notice 'prosesp tables published: %', v_published;
end
$$;
