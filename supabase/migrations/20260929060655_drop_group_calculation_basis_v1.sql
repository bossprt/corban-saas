-- Leftover removal, part 1 of 2 (owner approval 29/09/2026): commission_groups.calculation_basis.
--
-- The column said "percent of the received commission", but since 26/09 (20260926010227_commission_group_values_v1) a
-- group's values are points of the operation (value = received x share / 100) and the commission engine reads them as
-- points (base x value / 100). Every row holds the same forced value, a trigger only keeps it that way, and no screen
-- or calculation reads it. Keeping it would mislead whoever reads the schema.
--
-- Backup first: schema backup_c6 (not exposed by the API), removed only with the owner's approval.

create schema backup_c6;
revoke all on schema backup_c6 from public, anon, authenticated;
create table backup_c6.commission_groups_calculation_basis as
  select id, organization_id, name, calculation_basis from public.commission_groups;
revoke all on backup_c6.commission_groups_calculation_basis from public, anon, authenticated;

-- The only writer that names the column: same function, without it.
CREATE OR REPLACE FUNCTION public.save_seller_group(p_org uuid, p_group uuid, p_name text, p_own_production boolean, p_items jsonb, p_supervisor_basis text, p_supervisor_pct text, p_manager_basis text, p_manager_pct text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_group uuid;
  v_name text := btrim(coalesce(p_name, ''));
  v_rule uuid;
  v_version integer;
  v_item jsonb;
  v_component uuid;
  v_ref text;
  v_ref_group uuid;
  v_pct numeric;
  v_seen uuid[] := '{}';
  v_types integer;
  v_pct_re constant text := '^[0-9]{1,3}(\.[0-9]{1,6})?$';
begin
  if auth.uid() is null or p_org is null or not public.has_active_organization_role(p_org, array['admin', 'manager']) then
    raise exception 'not_authorized';
  end if;
  if length(v_name) not between 1 and 80 then raise exception 'invalid_group_name'; end if;
  if coalesce(p_supervisor_basis, '') not in ('spread', 'production', 'payout') or coalesce(p_manager_basis, '') not in ('spread', 'production', 'payout') then
    raise exception 'invalid_hierarchy_basis';
  end if;
  if coalesce(p_supervisor_pct, '') !~ v_pct_re or coalesce(p_manager_pct, '') !~ v_pct_re
     or p_supervisor_pct::numeric > 100 or p_manager_pct::numeric > 100 then
    raise exception 'invalid_hierarchy_pct';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then raise exception 'invalid_rule_items'; end if;
  if coalesce(p_own_production, false) and jsonb_array_length(p_items) > 0 then raise exception 'own_production_has_no_payout'; end if;
  select count(*) into v_types from public.commission_component_types where is_active;
  if not coalesce(p_own_production, false) and jsonb_array_length(p_items) <> v_types then raise exception 'rule_items_incomplete'; end if;

  if p_group is null then
    insert into public.commission_groups (organization_id, name, kind, created_by)
    values (p_org, v_name, 'other', auth.uid())
    returning id into v_group;
  else
    select g.id into v_group from public.commission_groups g where g.id = p_group and g.organization_id = p_org for update;
    if v_group is null then raise exception 'group_not_found'; end if;
    update public.commission_groups set name = v_name, updated_at = now() where id = v_group;
  end if;

  -- A group other rules read from must keep its column.
  if coalesce(p_own_production, false) and exists (
    select 1 from public.commission_group_rule_items i
    join public.commission_group_rules r on r.id = i.rule_id
    where i.organization_id = p_org and i.reference_group_id = v_group and r.group_id <> v_group
      and r.version = (select max(r2.version) from public.commission_group_rules r2 where r2.group_id = r.group_id)
  ) then
    raise exception 'group_column_in_use';
  end if;

  select coalesce(max(version), 0) + 1 into v_version from public.commission_group_rules where group_id = v_group;
  perform set_config('corban.group_rule_rpc', 'on', true);
  insert into public.commission_group_rules (organization_id, group_id, version, own_production, supervisor_basis, supervisor_pct, manager_basis, manager_pct, created_by)
  values (p_org, v_group, v_version, coalesce(p_own_production, false), p_supervisor_basis, p_supervisor_pct::numeric, p_manager_basis, p_manager_pct::numeric, auth.uid())
  returning id into v_rule;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select t.id into v_component from public.commission_component_types t where t.tech_key = v_item->>'component' and t.is_active;
    if v_component is null or v_component = any (v_seen) then raise exception 'invalid_rule_items'; end if;
    v_seen := v_seen || v_component;
    v_ref := v_item->>'reference';
    if coalesce(v_ref, '') not in ('own', 'company', 'group') then raise exception 'invalid_rule_items'; end if;
    v_ref_group := null;
    if v_ref = 'group' then
      begin
        v_ref_group := (v_item->>'group')::uuid;
      exception when others then
        raise exception 'invalid_rule_items';
      end;
      -- The referenced group must belong to the company, be active, not be this group and have a column (not own production).
      if v_ref_group is null or v_ref_group = v_group or not exists (
        select 1 from public.commission_groups g where g.id = v_ref_group and g.organization_id = p_org and g.is_active
      ) or exists (
        select 1 from public.commission_group_rules r where r.group_id = v_ref_group and r.own_production
          and r.version = (select max(r2.version) from public.commission_group_rules r2 where r2.group_id = v_ref_group)
      ) then
        raise exception 'invalid_reference_group';
      end if;
    end if;
    if coalesce(v_item->>'pct', '') !~ v_pct_re then raise exception 'invalid_rule_pct'; end if;
    v_pct := (v_item->>'pct')::numeric;
    if v_pct > 100 then raise exception 'invalid_rule_pct'; end if;
    insert into public.commission_group_rule_items (rule_id, organization_id, component_type_id, reference_kind, reference_group_id, distributed_pct)
    values (v_rule, p_org, v_component, v_ref, v_ref_group, v_pct);
  end loop;
  perform set_config('corban.group_rule_rpc', 'off', true);

  return v_group;
end
$function$;

drop trigger commission_groups_20_received_basis_guard on public.commission_groups;
drop function public.guard_commission_group_received_basis();
alter table public.commission_groups drop column calculation_basis;
