-- PREPARED, NOT APPLIED. Forward-only; no data touched; no SECURITY DEFINER.
-- Finding (proved against the LIVE schema): a tenant admin/manager can create routes, tables and DRAFT versions in the browser, but can NEVER publish them:
--   * product_table_versions / document_checklist_templates UPDATE policies require `status='draft'` in USING *and* WITH CHECK, so the update draft -> published is refused;
--   * there is no publish RPC.
-- Without a published table version nobody can simulate; without a published checklist nobody can prepare proposal documents. The pilot would need SQL.
-- The opposite hole also exists: INSERT policies do not constrain `status`, so a manager could insert a version already 'published' (bypassing every publication rule).
-- Fix (INVOKER RPCs + guard tokens, no policy weakening beyond the single allowed transition):
--   * UPDATE policies now allow the row to LEAVE draft (WITH CHECK admits 'draft' and 'published'); a guard trigger (GUC corban.catalog_rpc) makes the
--     draft -> published transition possible ONLY inside the RPCs below, and forces every INSERT by authenticated to be a draft;
--   * publish_product_table_version(p_version_id): manager+ (admin, manager); draft only; at least a rate or a coefficient; publishes and supersedes the previous
--     published version of the same table in the same transaction (published versions stay immutable, existing guard);
--   * publish_document_checklist_template(p_template_id): supervisor+ (as the existing policies); draft only; at least one item; supersedes the previous published
--     template of the same route.
-- Nothing here invents commercial data: rates, coefficients, terms and documents are entered by the organization.

create or replace function public.guard_catalog_publication() returns trigger language plpgsql set search_path='' as $$
begin
 if current_user in ('authenticated','anon') then
  if tg_op='INSERT' and new.status is distinct from 'draft' then raise exception 'catalog_insert_must_be_draft'; end if;
  if tg_op='UPDATE' and old.status='draft' and new.status is distinct from 'draft' and current_setting('corban.catalog_rpc',true) is distinct from 'on' then raise exception 'catalog_publication_requires_governed_rpc'; end if;
  if tg_op='UPDATE' and old.status<>'draft' and new.status is distinct from old.status and current_setting('corban.catalog_rpc',true) is distinct from 'on' then raise exception 'catalog_status_requires_governed_rpc'; end if;
 end if;
 return new;
end $$;
create trigger product_table_versions_00_catalog_guard before insert or update on public.product_table_versions for each row execute function public.guard_catalog_publication();
create trigger document_checklist_templates_00_catalog_guard before insert or update on public.document_checklist_templates for each row execute function public.guard_catalog_publication();

drop policy product_table_versions_update_draft_manager on public.product_table_versions;
create policy product_table_versions_update_draft_manager on public.product_table_versions for update to authenticated
 using (status='draft' and public.has_active_organization_role(organization_id,array['admin','manager']))
 with check (status in ('draft','published') and public.has_active_organization_role(organization_id,array['admin','manager']));
-- superseding the previous published version happens inside the RPC: the row is published (not draft), so it needs its own narrow policy
create policy product_table_versions_supersede_manager on public.product_table_versions for update to authenticated
 using (status='published' and public.has_active_organization_role(organization_id,array['admin','manager']))
 with check (status='superseded' and public.has_active_organization_role(organization_id,array['admin','manager']));

drop policy document_checklist_templates_update_draft_supervisor on public.document_checklist_templates;
create policy document_checklist_templates_update_draft_supervisor on public.document_checklist_templates for update to authenticated
 using (status='draft' and public.has_active_organization_role(organization_id,array['admin','manager','supervisor']))
 with check (status in ('draft','published') and public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy document_checklist_templates_supersede_supervisor on public.document_checklist_templates for update to authenticated
 using (status='published' and public.has_active_organization_role(organization_id,array['admin','manager','supervisor']))
 with check (status='superseded' and public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));

create or replace function public.publish_product_table_version(p_version_id uuid) returns uuid language plpgsql set search_path='' as $$
declare v public.product_table_versions%rowtype;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into v from public.product_table_versions x where x.id=p_version_id for update;
 if not found then raise exception 'version_not_found'; end if;
 if not public.has_active_organization_role(v.organization_id,array['admin','manager']) then raise exception 'not_authorized'; end if;
 if v.status<>'draft' then raise exception 'version_not_draft'; end if;
 if v.rate is null and v.coefficient is null then raise exception 'rate_or_coefficient_required'; end if;
 perform set_config('corban.catalog_rpc','on',true);
 update public.product_table_versions set status='superseded' where organization_id=v.organization_id and product_table_id=v.product_table_id and status='published';
 update public.product_table_versions set status='published',published_at=now(),effective_from=coalesce(effective_from,now()) where id=v.id;
 perform set_config('corban.catalog_rpc','off',true);
 return v.id;
end $$;

create or replace function public.publish_document_checklist_template(p_template_id uuid) returns uuid language plpgsql set search_path='' as $$
declare t public.document_checklist_templates%rowtype;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into t from public.document_checklist_templates x where x.id=p_template_id for update;
 if not found then raise exception 'template_not_found'; end if;
 if not public.has_active_organization_role(t.organization_id,array['admin','manager','supervisor']) then raise exception 'not_authorized'; end if;
 if t.status<>'draft' then raise exception 'template_not_draft'; end if;
 if not exists(select 1 from public.document_checklist_items i where i.organization_id=t.organization_id and i.template_id=t.id) then raise exception 'template_has_no_items'; end if;
 perform set_config('corban.catalog_rpc','on',true);
 update public.document_checklist_templates set status='superseded' where organization_id=t.organization_id and route_id=t.route_id and status='published';
 update public.document_checklist_templates set status='published',published_at=now() where id=t.id;
 perform set_config('corban.catalog_rpc','off',true);
 return t.id;
end $$;

revoke all on function public.guard_catalog_publication() from public,anon,authenticated;
revoke all on function public.publish_product_table_version(uuid) from public,anon;
revoke all on function public.publish_document_checklist_template(uuid) from public,anon;
grant execute on function public.publish_product_table_version(uuid) to authenticated;
grant execute on function public.publish_document_checklist_template(uuid) to authenticated;
