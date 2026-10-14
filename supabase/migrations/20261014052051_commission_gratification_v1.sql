-- New commission component "Gratificação" (owner request 14/10/2026), paid once like the bonuses ("igual ao Bônus").
--
-- 1. Catalog: commission_component_types gets "gratification" after "Seguro fixo". Every screen that lists components
--    (groups, tables, table import, contract calculation) reads the catalog.
-- 2. Seller groups of Smart Promotora (the owner's company; another company's groups are configured only by its own
--    administrators): the seller gets a share of a Gratificação the same way as of the Bônus. Group rules are immutable
--    and versioned, so each group whose latest rule has a Bônus item gets a new version: the same rule and items, plus a
--    Gratificação item equal to its Bônus item (reference column and % distributed). Groups without a Bônus item are not
--    touched (their seller gets no share of either). Contracts already calculated keep the rule version they used.

insert into public.commission_component_types (tech_key, name, sort_order, is_active)
values ('gratification', 'Gratificação', 80, true)
on conflict (tech_key) do nothing;

do $$
declare
  v_org constant uuid := '62405e20-af29-4359-b39c-79c206146b6c';  -- Smart Promotora
  v_grat uuid := (select id from public.commission_component_types where tech_key = 'gratification');
  v_bonus uuid := (select id from public.commission_component_types where tech_key = 'bonus_1');
  r public.commission_group_rules%rowtype;
  v_new uuid;
  n integer := 0;
begin
  perform set_config('corban.group_rule_rpc', 'on', true);
  for r in
    select x.* from (select distinct on (g.group_id) g.* from public.commission_group_rules g where g.organization_id = v_org
                     order by g.group_id, g.version desc) x
    where exists (select 1 from public.commission_group_rule_items i where i.rule_id = x.id and i.component_type_id = v_bonus)
      and not exists (select 1 from public.commission_group_rule_items i where i.rule_id = x.id and i.component_type_id = v_grat)
  loop
    insert into public.commission_group_rules (organization_id, group_id, version, own_production, supervisor_basis, supervisor_pct,
                                               manager_basis, manager_pct, created_by)
    values (r.organization_id, r.group_id, r.version + 1, r.own_production, r.supervisor_basis, r.supervisor_pct,
            r.manager_basis, r.manager_pct, r.created_by)
    returning id into v_new;
    insert into public.commission_group_rule_items (rule_id, organization_id, component_type_id, reference_kind, reference_group_id, distributed_pct)
    select v_new, i.organization_id, i.component_type_id, i.reference_kind, i.reference_group_id, i.distributed_pct
    from public.commission_group_rule_items i where i.rule_id = r.id;
    insert into public.commission_group_rule_items (rule_id, organization_id, component_type_id, reference_kind, reference_group_id, distributed_pct)
    select v_new, i.organization_id, v_grat, i.reference_kind, i.reference_group_id, i.distributed_pct
    from public.commission_group_rule_items i where i.rule_id = r.id and i.component_type_id = v_bonus;
    n := n + 1;
  end loop;
  perform set_config('corban.group_rule_rpc', 'off', true);
  raise notice 'gratification: % group rules got a new version', n;
end
$$;
