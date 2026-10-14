-- Gratificação in the seller groups of MAIS VALOR (platform owner's request 14/10/2026: "pode ativar na Mais valor"),
-- the same as 20261014052051_commission_gratification_v1 did for Smart Promotora: each group whose latest rule has a Bônus
-- item gets a new version with a Gratificação item equal to it. Groups without a Bônus item are not touched.

do $$
declare
  v_org constant uuid := '4526e6a9-104e-4bad-9b0c-8deec89ca0d3';  -- MAIS VALOR
  v_grat uuid := (select id from public.commission_component_types where tech_key = 'gratification');
  v_bonus uuid := (select id from public.commission_component_types where tech_key = 'bonus_1');
  r public.commission_group_rules%rowtype;
  v_new uuid;
  n integer := 0;
begin
  if v_grat is null then raise exception 'gratification_missing'; end if;
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
  raise notice 'gratification mais valor: % group rules got a new version', n;
end
$$;
