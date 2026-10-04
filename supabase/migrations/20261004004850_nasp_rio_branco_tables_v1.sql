-- NASP - Prefeitura de Rio Branco: four commission tables (owner request 03/10/2026).
--
-- Same shape as the NASP - Governo do Acre tables (20261002122145): one route (bank NASP, agreement Prefeitura de Rio
-- Branco, own production), one table per row, two lines (contract types Novo and Refinanciamento, owner decision) for the
-- whole term range, monthly interest 0%, no amount range, commission à vista on the net amount, published with vigência
-- from 01/01/2026. Commission and payout by group as the Governo do Acre tables
-- (owner decision):
--   tables paying 10%: Balcão 5%, Call Center 2,5%, Afiliado 1%, Corretor 4%, Parceiro 4%
--   tables paying 6%:  Balcão 3%, Call Center 1,5%, Afiliado 0,6%, Corretor 2%, Parceiro 2%
-- Table names keep the owner's "Prefeitura ..." names, so a contract sheet tells them apart from the Governo do Acre ones.
-- Runs only in the company that has the bank NASP and the agreement Prefeitura de Rio Branco; anywhere else, and when
-- these tables already exist, it does nothing.

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
  v_type uuid;
  v_avista uuid;
  v_groups jsonb;
  v_key text;
  r record;
begin
  select b.organization_id, b.id, a.id into v_org, v_bank, v_agreement
  from public.organization_banks b
  join public.organization_agreements a on a.organization_id = b.organization_id and a.name = 'Prefeitura de Rio Branco' and a.is_active
  where b.name = 'NASP' and b.is_active;
  if v_org is null then raise notice 'nasp rio branco: company not here, nothing to do'; return; end if;
  if exists (select 1 from public.product_tables t where t.organization_id = v_org and t.code like 'nasp-rb-%') then
    raise notice 'nasp rio branco: tables already exist'; return;
  end if;

  select m.user_id into v_admin from public.organization_memberships m
  where m.organization_id = v_org and m.role = 'admin' and m.status = 'active' order by m.created_at limit 1;
  select k.id into v_avista from public.commission_component_types k where k.name = 'À Vista' and k.is_active;
  if v_admin is null or v_avista is null then raise exception 'nasp_rio_branco_missing_catalog'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  insert into public.organization_product_routes (organization_id, org_bank_id, org_provider_id, org_agreement_id, production_origin, status)
  values (v_org, v_bank, null, v_agreement, 'own', 'active') returning id into v_route;

  for r in
    select * from (values
      ('nasp-rb-temporario-4-7',   'NASP - Pref. Rio Branco - Prefeitura Temporário (4 a 7 meses)', 4,  7, 0::numeric, '6',  '3', '1.5', '0.6', '2'),
      ('nasp-rb-temporario-8-18',  'NASP - Pref. Rio Branco - Prefeitura Temporário (8 a 18 meses)', 8, 18, 0::numeric, '10', '5', '2.5', '1',   '4'),
      ('nasp-rb-comissionado-4-7', 'NASP - Pref. Rio Branco - Prefeitura Comissionado (4 a 7 meses)', 4,  7, 0::numeric, '6',  '3', '1.5', '0.6', '2'),
      ('nasp-rb-comissionado-8-24','NASP - Pref. Rio Branco - Prefeitura Comissionado (8 a 24 meses)', 8, 24, 0::numeric, '10', '5', '2.5', '1',   '4')
    ) as x(code, name, term_min, term_max, rate, received, balcao, call_center, afiliado, corretor)
  loop
    select jsonb_agg(jsonb_build_object('group_id', g.id, 'component_type_id', v_avista, 'value_kind', 'percentage', 'value', p.pct, 'source', 'manual'))
    into v_groups
    from (values ('Balcão', r.balcao), ('Corretor', r.corretor), ('Parceiro', r.corretor), ('Call Center', r.call_center), ('Afiliado', r.afiliado)) as p(name, pct)
    join public.commission_groups g on g.organization_id = v_org and g.name = p.name and g.is_active;
    if jsonb_array_length(coalesce(v_groups, '[]')) <> 5 then
      raise exception 'nasp_rio_branco_missing_catalog: %', r.code;
    end if;

    insert into public.product_tables (organization_id, route_id, code, name, status, formalization)
    values (v_org, v_route, r.code, r.name, 'active', 'digital') returning id into v_table;
    insert into public.product_table_versions (organization_id, product_table_id, version, status)
    values (v_org, v_table, 1, 'draft') returning id into v_version;
    foreach v_key in array array['novo', 'refinanciamento'] loop
      select ct.id into v_type from public.contract_types ct
      where ct.tech_key = v_key and ct.is_active and (ct.organization_id is null or ct.organization_id = v_org)
      order by (ct.organization_id = v_org) desc nulls last limit 1;
      if v_type is null then raise exception 'nasp_rio_branco_missing_catalog: %', v_key; end if;
      insert into public.commercial_conditions (organization_id, product_table_version_id, contract_type_id, term, term_min, term_max, rate, tax_pct, created_by)
      values (v_org, v_version, v_type, r.term_min, r.term_min, r.term_max, r.rate, 0, v_admin) returning id into v_condition;
      perform public.replace_commercial_condition_components(v_condition, jsonb_build_array(jsonb_build_object(
        'component_type_id', v_avista, 'value_kind', 'percentage', 'received_value', r.received, 'calculation_base', 'LÍQUIDO', 'source', 'manual')));
      if public.replace_condition_group_values(v_condition, v_groups) <> 5 then raise exception 'nasp_rio_branco_group_values: %', r.code; end if;
    end loop;

    perform public.publish_product_table_version(v_version, date '2026-01-01');
    if not exists (select 1 from public.product_table_versions v where v.id = v_version and v.status = 'published') then
      raise exception 'nasp_rio_branco_not_published: %', r.code;
    end if;
  end loop;

  perform set_config('request.jwt.claims', '', true);
  raise notice 'nasp rio branco: 4 tables published';
end
$$;
