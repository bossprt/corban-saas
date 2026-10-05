-- NASP - Governo do Acre: the Refinanciamento contract type gets the same commission as Novo (owner request 05/10/2026).
--
-- The four Temporário and Comissionado tables had a line for Novo only. Each gets a new vigência (v2) cloned from the
-- published one, with a Refinanciamento line equal to the Novo line: same term range, rate, tax, component (à vista on
-- the net amount, 6% or 10%) and the same payout per group. Published from 01/01/2026, the vigência of v1, so v1 is
-- kept as superseded history and the contracts already registered keep their own calculation. The Efetivo tables
-- (Normal, REFIN, COMPRA) and the Prefeitura de Rio Branco tables already have Refinanciamento and are not touched.
--
-- Through the catalog RPCs (clone_table_version, replace_commercial_condition_components,
-- replace_condition_group_values, publish_product_table_version), as the company's first administrator. Runs only in
-- the company that has these tables; a table that already has a Refinanciamento line is skipped.

do $$
declare
  v_org uuid;
  v_admin uuid;
  v_refin uuid;
  v_novo uuid;
  v_draft uuid;
  v_condition uuid;
  v_groups jsonb;
  v_components jsonb;
  v_done integer := 0;
  r record;
  c record;
begin
  select t.organization_id into v_org from public.product_tables t where t.code = 'nasp-ac-temporario-4-7' limit 1;
  if v_org is null then raise notice 'nasp acre refin: company not here, nothing to do'; return; end if;

  select m.user_id into v_admin from public.organization_memberships m
  where m.organization_id = v_org and m.role = 'admin' and m.status = 'active' order by m.created_at limit 1;
  select ct.id into v_refin from public.contract_types ct
  where ct.tech_key = 'refinanciamento' and ct.is_active and (ct.organization_id is null or ct.organization_id = v_org)
  order by (ct.organization_id = v_org) desc nulls last limit 1;
  select ct.id into v_novo from public.contract_types ct
  where ct.tech_key = 'novo' and ct.is_active and (ct.organization_id is null or ct.organization_id = v_org)
  order by (ct.organization_id = v_org) desc nulls last limit 1;
  if v_admin is null or v_refin is null or v_novo is null then raise exception 'nasp_acre_refin_missing_catalog'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  for r in
    select t.code, v.id as version_id
    from public.product_tables t
    join public.product_table_versions v on v.product_table_id = t.id and v.status = 'published'
    where t.organization_id = v_org
      and t.code in ('nasp-ac-temporario-4-7', 'nasp-ac-temporario-8-18', 'nasp-ac-comissionado-4-7', 'nasp-ac-comissionado-8-24')
    order by t.code
  loop
    if exists (select 1 from public.commercial_conditions x where x.product_table_version_id = r.version_id and x.contract_type_id = v_refin) then
      raise notice 'nasp acre refin: % already has Refinanciamento', r.code; continue;
    end if;
    select * into c from public.commercial_conditions x where x.product_table_version_id = r.version_id and x.contract_type_id = v_novo;
    if c.id is null then raise exception 'nasp_acre_refin_no_novo_line: %', r.code; end if;

    select jsonb_agg(jsonb_build_object('component_type_id', k.component_type_id, 'value_kind', k.value_kind, 'received_value', k.received_value,
                                        'calculation_base', k.calculation_base, 'source', k.source))
    into v_components from public.commercial_condition_components k where k.condition_id = c.id;
    select jsonb_agg(jsonb_build_object('group_id', g.group_id, 'component_type_id', g.component_type_id, 'value_kind', g.value_kind,
                                        'value', g.value, 'source', g.source))
    into v_groups from public.commercial_condition_group_values g where g.condition_id = c.id;
    if v_components is null or v_groups is null then raise exception 'nasp_acre_refin_incomplete_novo_line: %', r.code; end if;

    v_draft := public.clone_table_version(r.version_id);
    insert into public.commercial_conditions (organization_id, product_table_version_id, contract_type_id, term, term_min, term_max,
                                              amount_min, amount_max, coefficient, rate, tax_pct, created_by)
    values (v_org, v_draft, v_refin, c.term, c.term_min, c.term_max, c.amount_min, c.amount_max, c.coefficient, c.rate, c.tax_pct, v_admin)
    returning id into v_condition;
    perform public.replace_commercial_condition_components(v_condition, v_components);
    if public.replace_condition_group_values(v_condition, v_groups) <> jsonb_array_length(v_groups) then
      raise exception 'nasp_acre_refin_group_values: %', r.code;
    end if;

    perform public.publish_product_table_version(v_draft, date '2026-01-01');
    if not exists (select 1 from public.product_table_versions v where v.id = v_draft and v.status = 'published') then
      raise exception 'nasp_acre_refin_not_published: %', r.code;
    end if;
    v_done := v_done + 1;
  end loop;

  perform set_config('request.jwt.claims', '', true);
  raise notice 'nasp acre refin: % tables got Refinanciamento', v_done;
end
$$;
