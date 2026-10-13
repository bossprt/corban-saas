-- NASP - Prefeitura de Rio Branco: table "Prefeitura Normal - Efetivo / Pensionista" (owner request 13/10/2026: same
-- commission received and paid out as the Governo do Acre "Normal" tables).
--
-- The Governo do Acre has three Normal tables (Normal - Efetivo / Pensionista for new, REFIN - NORMAL, COMPRA NORMAL), all
-- with the same rule. Here one table carries the three contract types (novo, refinanciamento, compra_de_divida), so the
-- NASP name "Prefeitura Normal - Efetivo / Pensionista" finds it through the contracts API for any of them.
-- Rule copied from the Governo do Acre Normal tables: term 24 to 84 months, no rate, no tax, no amount range, commission
-- à vista 10% on the net amount; payout by group: Balcão 5%, Corretor 4%, Parceiro 4%, Call Center 2,5%, Afiliado 1%.
-- Published with vigência from 01/01/2026, on the existing route NASP + Prefeitura de Rio Branco.
-- Runs only in the company that has that route; anywhere else, and when the table already exists, it does nothing.

do $$
declare
  v_org uuid;
  v_admin uuid;
  v_route uuid;
  v_table uuid;
  v_version uuid;
  v_condition uuid;
  v_type uuid;
  v_avista uuid;
  v_groups jsonb;
  v_key text;
begin
  select r.organization_id, r.id into v_org, v_route
  from public.organization_product_routes r
  join public.organization_banks b on b.id = r.org_bank_id and b.name = 'NASP' and b.is_active
  join public.organization_agreements a on a.id = r.org_agreement_id and a.name = 'Prefeitura de Rio Branco' and a.is_active
  where r.status = 'active' and r.production_origin = 'own'
    and exists (select 1 from public.product_tables t where t.route_id = r.id and t.code like 'nasp-rb-%');
  if v_org is null then raise notice 'nasp rio branco normal: company not here, nothing to do'; return; end if;
  if exists (select 1 from public.product_tables t where t.organization_id = v_org and t.code = 'nasp-rb-efetivo-normal') then
    raise notice 'nasp rio branco normal: table already exists'; return;
  end if;

  select m.user_id into v_admin from public.organization_memberships m
  where m.organization_id = v_org and m.role = 'admin' and m.status = 'active' order by m.created_at limit 1;
  select k.id into v_avista from public.commission_component_types k where k.name = 'À Vista' and k.is_active;
  if v_admin is null or v_avista is null then raise exception 'nasp_rio_branco_normal_missing_catalog'; end if;

  select jsonb_agg(jsonb_build_object('group_id', g.id, 'component_type_id', v_avista, 'value_kind', 'percentage', 'value', p.pct, 'source', 'manual'))
  into v_groups
  from (values ('Balcão', '5'), ('Corretor', '4'), ('Parceiro', '4'), ('Call Center', '2.5'), ('Afiliado', '1')) as p(name, pct)
  join public.commission_groups g on g.organization_id = v_org and g.name = p.name and g.is_active;
  if jsonb_array_length(coalesce(v_groups, '[]')) <> 5 then raise exception 'nasp_rio_branco_normal_missing_catalog: groups'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  insert into public.product_tables (organization_id, route_id, code, name, status, formalization)
  values (v_org, v_route, 'nasp-rb-efetivo-normal', 'NASP - Pref. Rio Branco - Prefeitura Normal - Efetivo / Pensionista', 'active', 'digital')
  returning id into v_table;
  insert into public.product_table_versions (organization_id, product_table_id, version, status)
  values (v_org, v_table, 1, 'draft') returning id into v_version;
  foreach v_key in array array['novo', 'refinanciamento', 'compra_de_divida'] loop
    select ct.id into v_type from public.contract_types ct
    where ct.tech_key = v_key and ct.is_active and (ct.organization_id is null or ct.organization_id = v_org)
    order by (ct.organization_id = v_org) desc nulls last limit 1;
    if v_type is null then raise exception 'nasp_rio_branco_normal_missing_catalog: %', v_key; end if;
    insert into public.commercial_conditions (organization_id, product_table_version_id, contract_type_id, term, term_min, term_max, rate, tax_pct, created_by)
    values (v_org, v_version, v_type, 24, 24, 84, null, 0, v_admin) returning id into v_condition;
    perform public.replace_commercial_condition_components(v_condition, jsonb_build_array(jsonb_build_object(
      'component_type_id', v_avista, 'value_kind', 'percentage', 'received_value', '10', 'calculation_base', 'LÍQUIDO', 'source', 'manual')));
    if public.replace_condition_group_values(v_condition, v_groups) <> 5 then raise exception 'nasp_rio_branco_normal_group_values: %', v_key; end if;
  end loop;

  perform public.publish_product_table_version(v_version, date '2026-01-01');
  if not exists (select 1 from public.product_table_versions v where v.id = v_version and v.status = 'published') then
    raise exception 'nasp_rio_branco_normal_not_published';
  end if;

  perform set_config('request.jwt.claims', '', true);
  raise notice 'nasp rio branco normal: table published';
end
$$;
