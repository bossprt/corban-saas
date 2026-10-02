-- PROSESP - Prefeitura de Rio Branco - Efetivo (owner request 01/10/2026, from the WorkBank sheet).
--
-- One table, one line: Novo, 24 to 36 months, R$ 300,00 to R$ 15.000,00, 7% à vista on the net amount, digital,
-- vigência from 18/06/2026. Owner decisions: the sheet's "Mensalidade" column is ignored, and the whole range
-- 300-15.000 pays 7% (one line instead of one table per range). Payout by group: Balcão 3,5%, Corretor 4%,
-- Parceiro 4%, Call Center 1,75%, Afiliado 0,7%.
--
-- Built like the screens do it: route and table as the catalog insert, the line in a draft version, the components
-- and group values through their RPCs, then publish_product_table_version, all as the company's first administrator
-- (the RPCs check that role). Runs only in the company that has the PROSESP Governo do Acre tables; anywhere else
-- (local, test) and when the table already exists it does nothing.

do $$
declare
  v_org uuid;
  v_admin uuid;
  v_bank uuid;
  v_agreement uuid;
  v_route uuid;
  v_table uuid;
  v_version uuid;
  v_condition uuid;
  v_novo uuid;
  v_avista uuid;
  v_groups jsonb;
  v_name constant text := 'PROSESP - Pref. Rio Branco - Efetivo';
begin
  select t.organization_id, r.org_bank_id into v_org, v_bank
  from public.product_tables t join public.organization_product_routes r on r.id = t.route_id
  where t.code = 'prosesp-ac-efetivo';
  if v_org is null then raise notice 'prosesp rio branco: company not here, nothing to do'; return; end if;
  if exists (select 1 from public.product_tables t where t.organization_id = v_org and t.name = v_name) then
    raise notice 'prosesp rio branco: table already exists'; return;
  end if;

  select m.user_id into v_admin from public.organization_memberships m
  where m.organization_id = v_org and m.role = 'admin' and m.status = 'active' order by m.created_at limit 1;
  select a.id into v_agreement from public.organization_agreements a where a.organization_id = v_org and a.name = 'Prefeitura de Rio Branco' and a.is_active;
  select ct.id into v_novo from public.contract_types ct
  where ct.tech_key = 'novo' and ct.is_active and (ct.organization_id is null or ct.organization_id = v_org)
  order by (ct.organization_id = v_org) desc nulls last limit 1;
  select k.id into v_avista from public.commission_component_types k where k.name = 'À Vista' and k.is_active;
  select jsonb_agg(jsonb_build_object('group_id', g.id, 'component_type_id', v_avista, 'value_kind', 'percentage', 'value', x.pct, 'source', 'manual'))
  into v_groups
  from (values ('Balcão', '3.5'), ('Corretor', '4'), ('Parceiro', '4'), ('Call Center', '1.75'), ('Afiliado', '0.7')) as x(name, pct)
  join public.commission_groups g on g.organization_id = v_org and g.name = x.name and g.is_active;
  if v_admin is null or v_agreement is null or v_novo is null or v_avista is null or jsonb_array_length(coalesce(v_groups, '[]')) <> 5 then
    raise exception 'prosesp_rio_branco_missing_catalog';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  insert into public.organization_product_routes (organization_id, org_bank_id, org_provider_id, org_agreement_id, production_origin, status)
  values (v_org, v_bank, null, v_agreement, 'own', 'active') returning id into v_route;
  insert into public.product_tables (organization_id, route_id, code, name, status, formalization)
  values (v_org, v_route, 'prosesp-rb-efetivo', v_name, 'active', 'digital') returning id into v_table;
  insert into public.product_table_versions (organization_id, product_table_id, version, status)
  values (v_org, v_table, 1, 'draft') returning id into v_version;

  insert into public.commercial_conditions (organization_id, product_table_version_id, contract_type_id, term, term_min, term_max, amount_min, amount_max, tax_pct, created_by)
  values (v_org, v_version, v_novo, 24, 24, 36, 300.00, 15000.00, 0, v_admin) returning id into v_condition;
  perform public.replace_commercial_condition_components(v_condition, jsonb_build_array(jsonb_build_object(
    'component_type_id', v_avista, 'value_kind', 'percentage', 'received_value', '7', 'calculation_base', 'LÍQUIDO', 'source', 'manual')));
  if public.replace_condition_group_values(v_condition, v_groups) <> 5 then raise exception 'prosesp_rio_branco_group_values'; end if;

  perform public.publish_product_table_version(v_version, date '2026-06-18');
  if not exists (select 1 from public.product_table_versions v where v.id = v_version and v.status = 'published') then
    raise exception 'prosesp_rio_branco_not_published';
  end if;
  perform set_config('request.jwt.claims', '', true);
  raise notice 'prosesp rio branco: table published';
end
$$;
