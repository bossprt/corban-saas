-- Seller groups as payout rules, part A (owner decision 25/09/2026).
--
-- A seller group (the table commission_groups: Corretor, Parceiro, Balcão...) is the rule for paying that kind of seller,
-- one to one: a seller belongs to one group and follows its rule. Each rule version says, for every commission type the
-- company receives (à vista, diferido, bônus 1-3, plástico, seguro), which table column it reads (the group's own column,
-- the company column or another group's column) and how many % of it is paid out; plus the supervisor and the sales
-- manager: their basis (spread, total production or the payout) and their %. A group can instead be "own production":
-- the company keeps 100% and there is no payout column.
--
-- Rule versions are immutable (a change is a new version), written only through save_seller_group. The calculation keeps
-- using the current engine until part C; part B adds the per-group columns to the tables.
--
-- Also removes the ChatGPT-era second grouping of sellers (seller_groups, one row "Padrão" in production; backup in
-- supabase/backups/20260925_seller_groups.sql) and the unused create_seller_with_access.

create table public.commission_group_rules (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  group_id uuid not null,
  version integer not null check (version >= 1),
  own_production boolean not null default false,
  supervisor_basis text not null check (supervisor_basis in ('spread', 'production', 'payout')),
  supervisor_pct numeric(9,6) not null check (supervisor_pct between 0 and 100),
  manager_basis text not null check (manager_basis in ('spread', 'production', 'payout')),
  manager_pct numeric(9,6) not null check (manager_pct between 0 and 100),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (group_id, version),
  unique (organization_id, id),
  foreign key (organization_id, group_id) references public.commission_groups(organization_id, id) on delete restrict
);

create table public.commission_group_rule_items (
  rule_id uuid not null,
  organization_id uuid not null,
  component_type_id uuid not null references public.commission_component_types(id) on delete restrict,
  reference_kind text not null check (reference_kind in ('own', 'company', 'group')),
  reference_group_id uuid,
  distributed_pct numeric(9,6) not null check (distributed_pct between 0 and 100),
  primary key (rule_id, component_type_id),
  check ((reference_kind = 'group') = (reference_group_id is not null)),
  foreign key (organization_id, rule_id) references public.commission_group_rules(organization_id, id) on delete restrict,
  foreign key (organization_id, reference_group_id) references public.commission_groups(organization_id, id) on delete restrict
);

create index commission_group_rules_group_idx on public.commission_group_rules (organization_id, group_id, version desc);
create index commission_group_rules_created_by_idx on public.commission_group_rules (created_by);
create index commission_group_rule_items_component_idx on public.commission_group_rule_items (component_type_id);
create index commission_group_rule_items_ref_idx on public.commission_group_rule_items (organization_id, reference_group_id);

-- Immutable history: rows are only inserted, and only by save_seller_group.
create or replace function private.guard_commission_group_rule_write()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if tg_op <> 'INSERT' then raise exception 'commission_group_rule_immutable'; end if;
  if current_setting('corban.group_rule_rpc', true) is distinct from 'on' then raise exception 'commission_group_rule_requires_governed_rpc'; end if;
  return new;
end
$$;

revoke all on function private.guard_commission_group_rule_write() from public, anon, authenticated;

create trigger commission_group_rules_00_guard before insert or update or delete on public.commission_group_rules
  for each row execute function private.guard_commission_group_rule_write();
create trigger commission_group_rule_items_00_guard before insert or update or delete on public.commission_group_rule_items
  for each row execute function private.guard_commission_group_rule_write();

alter table public.commission_group_rules enable row level security;
alter table public.commission_group_rule_items enable row level security;
revoke all on public.commission_group_rules, public.commission_group_rule_items from public, anon, authenticated;
grant select on public.commission_group_rules, public.commission_group_rule_items to authenticated;
-- Same audience as the groups themselves: payout rules are commission information.
create policy commission_group_rules_select on public.commission_group_rules for select to authenticated
  using (public.has_active_organization_role(organization_id, array['admin', 'manager', 'supervisor']));
create policy commission_group_rule_items_select on public.commission_group_rule_items for select to authenticated
  using (public.has_active_organization_role(organization_id, array['admin', 'manager', 'supervisor']));

-- Create or change a seller group and write a new version of its rule, atomically.
-- Percentages arrive as decimal text (never floating point): up to 3 integer digits and 6 decimals, from 0 to 100.
-- p_items: [{"component": "<tech_key>", "reference": "own"|"company"|"group", "group": "<uuid>"|null, "pct": "100"}],
-- exactly one per active commission type; empty when the group is own production.
create or replace function public.save_seller_group(
  p_org uuid, p_group uuid, p_name text, p_own_production boolean, p_items jsonb,
  p_supervisor_basis text, p_supervisor_pct text, p_manager_basis text, p_manager_pct text
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
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
    insert into public.commission_groups (organization_id, name, kind, calculation_basis, created_by)
    values (p_org, v_name, 'other', 'percent_of_received_commission', auth.uid())
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
$$;

revoke all on function public.save_seller_group(uuid, uuid, text, boolean, jsonb, text, text, text, text) from public, anon;
grant execute on function public.save_seller_group(uuid, uuid, text, boolean, jsonb, text, text, text, text) to authenticated;

-- One grouping of sellers only: the seller group above. The ChatGPT-era seller_groups goes away.
create or replace function public.assign_proposal_seller(p_proposal_id uuid, p_seller_id uuid)
returns uuid
language plpgsql
set search_path to ''
as $$
declare
  v_org uuid;
  v_seller public.commercial_sellers%rowtype;
  v_attr jsonb;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;

  select p.organization_id, p.attribution_snapshot into v_org, v_attr
  from public.proposals_v2 p
  where p.id = p_proposal_id and p.status = 'draft' and public.is_active_organization_member(p.organization_id)
  for update;

  if v_org is null then raise exception 'draft_proposal_not_found_or_forbidden'; end if;
  if not public.has_active_organization_role(v_org, array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;

  if p_seller_id is not null then
    select * into v_seller from public.commercial_sellers s where s.id = p_seller_id and s.organization_id = v_org and s.is_active;
    if not found then raise exception 'active_seller_not_found'; end if;
    v_attr := coalesce(v_attr, '{}'::jsonb) || jsonb_build_object('seller', jsonb_build_object(
      'id', v_seller.id, 'name', v_seller.name, 'category', v_seller.seller_category, 'commission_group_id', v_seller.commission_group_id, 'assigned_at', now()));
  else
    v_attr := coalesce(v_attr, '{}'::jsonb) - 'seller';
  end if;

  perform set_config('corban.proposal_seller_rpc', 'on', true);
  update public.proposals_v2 set seller_id = p_seller_id, attribution_snapshot = v_attr, updated_at = now()
  where id = p_proposal_id and organization_id = v_org;
  perform set_config('corban.proposal_seller_rpc', 'off', true);

  return p_proposal_id;
end
$$;

drop function public.create_seller_with_access(uuid, text, text, text, uuid, uuid, text);
alter table public.commercial_sellers drop constraint commercial_sellers_organization_id_seller_group_id_fkey;
drop index if exists public.commercial_sellers_seller_group_idx;
alter table public.commercial_sellers drop column seller_group_id;
drop table public.seller_groups;
