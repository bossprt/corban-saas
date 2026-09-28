-- Documents each bank asks for (validation V1, owner 27/09/2026). The checklist already exists per route (bank +
-- convênio + own/partner production) in document_checklist_templates / _items, versioned (draft > published >
-- superseded) and read by prepare_proposal_documents; there was no way to write one. save_route_checklist writes the
-- same list to one or more routes of a bank in one step: for each route a new version is created, filled and published,
-- and the previous published version is superseded (history kept, proposals keep their own snapshot).
create or replace function public.save_route_checklist(p_org uuid, p_route_ids uuid[], p_items jsonb)
returns int language plpgsql security definer set search_path = '' as $$
declare
  v_route uuid; v_template uuid; v_version int; v_bank text; n int := 0; v_bad int;
begin
  if auth.uid() is null or not public.has_active_organization_role(p_org, array['admin', 'manager', 'supervisor']) then raise exception 'not_authorized'; end if;
  if p_route_ids is null or cardinality(p_route_ids) = 0 or cardinality(p_route_ids) > 100 then raise exception 'invalid_routes'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 30 then raise exception 'invalid_checklist_items'; end if;
  -- Each item: an active document type, once, with an optional label (default: the type name) and required flag.
  select count(*) into v_bad from jsonb_array_elements(p_items) i
  where jsonb_typeof(i) <> 'object' or coalesce(i->>'document_type_id', '') !~ '^[0-9a-f-]{36}$'
     or not exists (select 1 from public.document_types d where d.id = (i->>'document_type_id')::uuid and d.is_active)
     or length(coalesce(i->>'label', '')) > 120;
  if v_bad > 0 then raise exception 'invalid_checklist_items'; end if;
  if (select count(distinct i->>'document_type_id') from jsonb_array_elements(p_items) i) <> jsonb_array_length(p_items) then
    raise exception 'duplicate_checklist_items';
  end if;

  foreach v_route in array p_route_ids loop
    select b.name into v_bank from public.organization_product_routes r
    join public.organization_banks b on b.organization_id = r.organization_id and b.id = r.org_bank_id
    where r.organization_id = p_org and r.id = v_route;
    if v_bank is null then raise exception 'route_not_found'; end if;
    perform pg_advisory_xact_lock(hashtext('checklist_route:' || v_route::text));
    select coalesce(max(t.version), 0) + 1 into v_version from public.document_checklist_templates t where t.organization_id = p_org and t.route_id = v_route;
    insert into public.document_checklist_templates (organization_id, route_id, version, status, name)
    values (p_org, v_route, v_version, 'draft', left('Documentos ' || v_bank || ' v' || v_version, 200))
    returning id into v_template;
    insert into public.document_checklist_items (organization_id, template_id, document_type_id, label, is_required, sort_order)
    select p_org, v_template, (i->>'document_type_id')::uuid,
           coalesce(nullif(btrim(i->>'label'), ''), d.name), coalesce((i->>'required')::boolean, true), (o - 1)::int
    from jsonb_array_elements(p_items) with ordinality as x(i, o)
    join public.document_types d on d.id = (i->>'document_type_id')::uuid;
    perform set_config('corban.catalog_rpc', 'on', true);
    update public.document_checklist_templates set status = 'superseded'
    where organization_id = p_org and route_id = v_route and status = 'published';
    update public.document_checklist_templates set status = 'published', published_at = now() where id = v_template;
    perform set_config('corban.catalog_rpc', 'off', true);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.save_route_checklist(uuid, uuid[], jsonb) from public, anon;
grant execute on function public.save_route_checklist(uuid, uuid[], jsonb) to authenticated;
