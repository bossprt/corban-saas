-- CORBAN OS V2 — corrective fail-closed patch for authorized workflow migration.
-- A proposal must never become ready for digitization without a published checklist snapshot.

create or replace function public.prepare_proposal_documents(p_proposal_id uuid)
returns integer
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  v_org uuid;
  v_status text;
  v_template uuid;
  v_count integer := 0;
  v_requirement_count integer := 0;
begin
  select p.organization_id, p.status
    into v_org, v_status
  from public.proposals_v2 p
  where p.id = p_proposal_id
    and public.is_active_organization_member(p.organization_id)
  for update;

  if v_org is null then raise exception 'proposal_not_found_or_forbidden'; end if;
  if v_status not in ('draft','documents_pending') then raise exception 'proposal_not_preparable'; end if;

  select t.id into v_template
  from public.proposals_v2 p
  join public.product_table_versions v
    on v.organization_id=p.organization_id and v.id=p.product_table_version_id
  join public.product_tables pt
    on pt.organization_id=v.organization_id and pt.id=v.product_table_id
  join public.document_checklist_templates t
    on t.organization_id=pt.organization_id and t.route_id=pt.route_id
  where p.organization_id=v_org and p.id=p_proposal_id and t.status='published'
  order by t.version desc
  limit 1;

  if v_template is null then
    raise exception 'published_checklist_required';
  end if;

  if not exists (
    select 1 from public.document_checklist_items i
    where i.organization_id=v_org and i.template_id=v_template
  ) then
    raise exception 'published_checklist_requirements_not_instantiated';
  end if;

  insert into public.proposal_document_requirements (
    organization_id, proposal_id, checklist_item_id, document_type_id,
    label_snapshot, required_snapshot
  )
  select v_org, p_proposal_id, i.id, i.document_type_id, i.label, i.is_required
  from public.document_checklist_items i
  where i.organization_id=v_org and i.template_id=v_template
    and not exists (
      select 1 from public.proposal_document_requirements r
      where r.organization_id=v_org and r.proposal_id=p_proposal_id
        and r.checklist_item_id=i.id
    );
  get diagnostics v_count = row_count;

  select count(*) into v_requirement_count
  from public.proposal_document_requirements r
  where r.organization_id=v_org and r.proposal_id=p_proposal_id;

  if v_requirement_count = 0 then
    raise exception 'proposal_requirements_snapshot_empty';
  end if;

  if exists (
    select 1 from public.proposal_document_requirements r
    where r.organization_id=v_org and r.proposal_id=p_proposal_id
      and r.required_snapshot=true and r.status not in ('validated','waived')
  ) then
    update public.proposals_v2 set status='documents_pending', updated_at=now()
    where organization_id=v_org and id=p_proposal_id and status in ('draft','documents_pending');
  else
    update public.proposals_v2 set status='ready_for_digitization', updated_at=now()
    where organization_id=v_org and id=p_proposal_id and status in ('draft','documents_pending');
  end if;

  return v_count;
end;
$function$;

revoke all on function public.prepare_proposal_documents(uuid) from public, anon;
grant execute on function public.prepare_proposal_documents(uuid) to authenticated;
