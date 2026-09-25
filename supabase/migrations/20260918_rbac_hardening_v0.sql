-- CORBAN OS V2 — RBAC hardening V0
-- PREPARED ONLY. Requires explicit live DDL Human Gate.
-- Read remains tenant-scoped. Configuration writes are role-scoped.

create or replace function public.has_active_organization_role(p_organization_id uuid, p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1 from public.organization_memberships m
    where m.organization_id=p_organization_id
      and m.user_id=(select auth.uid())
      and m.status='active'
      and m.role=any(p_roles)
  );
$function$;

revoke all on function public.has_active_organization_role(uuid,text[]) from public,anon;
grant execute on function public.has_active_organization_role(uuid,text[]) to authenticated;

-- Catalog configuration: admin/manager.
drop policy if exists organization_product_routes_insert_member on public.organization_product_routes;
drop policy if exists organization_product_routes_update_member on public.organization_product_routes;
create policy organization_product_routes_insert_manager on public.organization_product_routes
for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy organization_product_routes_update_manager on public.organization_product_routes
for update to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager']))
with check (public.has_active_organization_role(organization_id,array['admin','manager']));

drop policy if exists product_tables_insert_member on public.product_tables;
drop policy if exists product_tables_update_member on public.product_tables;
create policy product_tables_insert_manager on public.product_tables
for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy product_tables_update_manager on public.product_tables
for update to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager']))
with check (public.has_active_organization_role(organization_id,array['admin','manager']));

drop policy if exists product_table_versions_insert_member on public.product_table_versions;
drop policy if exists product_table_versions_update_draft_member on public.product_table_versions;
create policy product_table_versions_insert_manager on public.product_table_versions
for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy product_table_versions_update_draft_manager on public.product_table_versions
for update to authenticated
using (status='draft' and public.has_active_organization_role(organization_id,array['admin','manager']))
with check (status='draft' and public.has_active_organization_role(organization_id,array['admin','manager']));

-- Checklist configuration: supervisor or above.
drop policy if exists document_checklist_templates_insert_member on public.document_checklist_templates;
drop policy if exists document_checklist_templates_update_draft_member on public.document_checklist_templates;
create policy document_checklist_templates_insert_supervisor on public.document_checklist_templates
for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy document_checklist_templates_update_draft_supervisor on public.document_checklist_templates
for update to authenticated
using (status='draft' and public.has_active_organization_role(organization_id,array['admin','manager','supervisor']))
with check (status='draft' and public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));

drop policy if exists document_checklist_items_insert_draft_member on public.document_checklist_items;
drop policy if exists document_checklist_items_update_draft_member on public.document_checklist_items;
create policy document_checklist_items_insert_draft_supervisor on public.document_checklist_items
for insert to authenticated with check (
  public.has_active_organization_role(organization_id,array['admin','manager','supervisor'])
  and exists (
    select 1 from public.document_checklist_templates t
    where t.organization_id=document_checklist_items.organization_id
      and t.id=document_checklist_items.template_id and t.status='draft'
  )
);
create policy document_checklist_items_update_draft_supervisor on public.document_checklist_items
for update to authenticated
using (
  public.has_active_organization_role(organization_id,array['admin','manager','supervisor'])
  and exists (
    select 1 from public.document_checklist_templates t
    where t.organization_id=document_checklist_items.organization_id
      and t.id=document_checklist_items.template_id and t.status='draft'
  )
)
with check (
  public.has_active_organization_role(organization_id,array['admin','manager','supervisor'])
  and exists (
    select 1 from public.document_checklist_templates t
    where t.organization_id=document_checklist_items.organization_id
      and t.id=document_checklist_items.template_id and t.status='draft'
  )
);

-- Operational stage configuration: admin/manager.
drop policy if exists operational_stages_insert_member on public.operational_stages;
drop policy if exists operational_stages_update_member on public.operational_stages;
create policy operational_stages_insert_manager on public.operational_stages
for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy operational_stages_update_manager on public.operational_stages
for update to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager']))
with check (public.has_active_organization_role(organization_id,array['admin','manager']));

-- Evidence lifecycle changes are supervisor+; creation remains available to active tenant users.
drop policy if exists customer_documents_update_member on public.customer_documents;
create policy customer_documents_update_supervisor on public.customer_documents
for update to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']))
with check (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));

-- Harden requirement workflow against direct REST updates bypassing application checks.
create or replace function public.guard_proposal_document_requirement_workflow()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  v_role text;
begin
  if new.status is distinct from old.status then
    select m.role into v_role
    from public.organization_memberships m
    where m.organization_id=new.organization_id and m.user_id=auth.uid() and m.status='active';

    if old.status='missing' and new.status not in ('attached','waived') then
      raise exception 'invalid_document_requirement_transition';
    elsif old.status='attached' and new.status not in ('validated','rejected','waived') then
      raise exception 'invalid_document_requirement_transition';
    elsif old.status='rejected' and new.status not in ('attached','waived') then
      raise exception 'invalid_document_requirement_transition';
    elsif old.status in ('validated','waived') then
      raise exception 'terminal_document_requirement_status';
    end if;

    if new.status in ('validated','rejected','waived')
       and v_role not in ('admin','manager','supervisor') then
      raise exception 'document_decision_requires_privileged_role';
    end if;
  end if;

  if new.status='validated' and old.status is distinct from 'validated' then
    if not exists (
      select 1 from public.proposal_document_links l
      join public.customer_documents d
        on d.organization_id=l.organization_id and d.id=l.customer_document_id
      where l.organization_id=new.organization_id
        and l.requirement_id=new.id
        and d.document_type_id=new.document_type_id
        and d.status='active'
    ) then raise exception 'validated_requirement_requires_active_matching_document'; end if;
  end if;

  if new.status='waived' and old.status is distinct from 'waived' then
    if auth.uid() is null or new.exception_approved_by is distinct from auth.uid() then
      raise exception 'waiver_approver_must_be_current_user';
    end if;
    if v_role not in ('admin','manager','supervisor') then
      raise exception 'waiver_requires_privileged_role';
    end if;
  end if;
  return new;
end;
$function$;

revoke all on function public.guard_proposal_document_requirement_workflow() from public,anon,authenticated;
