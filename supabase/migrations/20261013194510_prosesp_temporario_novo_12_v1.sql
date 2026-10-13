-- PROSESP - Governo do Acre - Temporário: Novo at 12 months (owner decision 13/10/2026: "são novos de 12 meses, 8%").
--
-- The table had Novo lines for 4 to 5 months (5%) and 6 to 8 months (8%); a WorkBank sheet brought new contracts of 12
-- months and they were refused ("Prazo 12 fora da tabela"). The table gets a new vigência cloned from the published one
-- with a Novo line for 12 months equal to the 6 to 8 months Novo line (8% à vista on the same base, same payout per
-- group; source "manual", since it is the owner's decision). Published from the current vigência's start, so the
-- current one stays as superseded history and the contracts already registered keep their own calculation.
--
-- Through the catalog RPCs, as the company's first administrator. Runs only in the company that has this table; skipped
-- if the table already has a Novo line covering 12 months.

do $$
declare
  v_org uuid;
  v_admin uuid;
  v_novo uuid;
  v_version uuid;
  v_from date;
  v_draft uuid;
  v_condition uuid;
  v_groups jsonb;
  v_components jsonb;
  c record;
begin
  select t.organization_id, v.id, (v.effective_from at time zone 'America/Sao_Paulo')::date into v_org, v_version, v_from
  from public.product_tables t
  join public.organization_product_routes r on r.id = t.route_id
  join public.organization_banks b on b.id = r.org_bank_id and b.name = 'PROSESP'
  join public.product_table_versions v on v.product_table_id = t.id and v.status = 'published'
  where t.name = 'PROSESP - Governo do Acre - Temporário' and t.status = 'active';
  if v_org is null then raise notice 'prosesp novo 12: company not here, nothing to do'; return; end if;

  select m.user_id into v_admin from public.organization_memberships m
  where m.organization_id = v_org and m.role = 'admin' and m.status = 'active' order by m.created_at limit 1;
  select ct.id into v_novo from public.contract_types ct
  where ct.tech_key = 'novo' and ct.is_active and (ct.organization_id is null or ct.organization_id = v_org)
  order by (ct.organization_id = v_org) desc nulls last limit 1;
  if v_admin is null or v_novo is null or v_from is null then raise exception 'prosesp_novo_12_missing_catalog'; end if;

  if exists (select 1 from public.commercial_conditions x where x.product_table_version_id = v_version and x.contract_type_id = v_novo
             and 12 between x.term_min and x.term_max) then
    raise notice 'prosesp novo 12: already has a Novo line for 12 months'; return;
  end if;
  select * into strict c from public.commercial_conditions x
  where x.product_table_version_id = v_version and x.contract_type_id = v_novo and x.term_min = 6 and x.term_max = 8;

  select jsonb_agg(jsonb_build_object('component_type_id', k.component_type_id, 'value_kind', k.value_kind, 'received_value', trim_scale(k.received_value)::text,
                                      'calculation_base', k.calculation_base, 'source', 'manual'))
  into v_components from public.commercial_condition_components k where k.condition_id = c.id;
  select jsonb_agg(jsonb_build_object('group_id', g.group_id, 'component_type_id', g.component_type_id, 'value_kind', g.value_kind,
                                      'value', trim_scale(g.value)::text, 'source', 'manual'))
  into v_groups from public.commercial_condition_group_values g where g.condition_id = c.id;
  if v_components is null or v_groups is null then raise exception 'prosesp_novo_12_incomplete_line'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  v_draft := public.clone_table_version(v_version);
  insert into public.commercial_conditions (organization_id, product_table_version_id, contract_type_id, term, term_min, term_max,
                                            amount_min, amount_max, coefficient, rate, tax_pct, created_by)
  values (v_org, v_draft, v_novo, 12, 12, 12, c.amount_min, c.amount_max, c.coefficient, c.rate, c.tax_pct, v_admin)
  returning id into v_condition;
  perform public.replace_commercial_condition_components(v_condition, v_components);
  if public.replace_condition_group_values(v_condition, v_groups) <> jsonb_array_length(v_groups) then
    raise exception 'prosesp_novo_12_group_values';
  end if;

  perform public.publish_product_table_version(v_draft, v_from);
  if not exists (select 1 from public.product_table_versions v where v.id = v_draft and v.status = 'published') then
    raise exception 'prosesp_novo_12_not_published';
  end if;

  perform set_config('request.jwt.claims', '', true);
  raise notice 'prosesp novo 12: line published';
end
$$;
