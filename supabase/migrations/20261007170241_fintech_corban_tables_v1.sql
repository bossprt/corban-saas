-- FINTECH CORBAN: 35 commission tables (owner request 07/10/2026, from the bank's table export).
--
-- Own production (Smart sells direct to the bank), no IR withheld, no tax. One route per agreement: FGTS (BFFUNDO,
-- FLEX, FIXO and J17 - FIXO), CLT Privado (PRIVADO - C, C-SEGURO) and INSS (Novo, Port + Refin, Portabilidade Pura and
-- Entrada). One line per row of the export, with its term range and amount range, published from the export's start
-- date. Owner decisions:
--   - Commission à vista as % of the operation. Base Bruto where the export says "Valor Bruto" (Port + Refin and
--     Portabilidade Entrada); Líquido everywhere else (including the rows where the export leaves it empty).
--   - Contract type: PORT + REFIN = Refin/Portabilidade; PORTABILIDADE PURA and ENTRADA = Portabilidade; the rest Novo.
--   - BFFUNDO: 18,5% from R$ 600,01 to R$ 49.999,99 and 0% at exactly R$ 50.000 (the export's two rows touch at 50.000).
--   - Rows paying 0% are kept as lines without commission, so a contract of that table is known to pay nothing.
--   - Payout by group, as % of the operation = bank % x Corretor 65%, Parceiro 80%, Balcão 50%, Call Center 25%,
--     Afiliado 10% (exact, not rounded). Smart Promotora is own production (no payout).
--   - "Máximo de Parcelas" is ignored (0 in every row); no monthly rate is stored (the export has none).
--   - The bank's table ids are kept: "Id Tabela" as the external table code, "Id Tabela Principal" in the metadata.
--
-- Amount ranges are matched by the commission engine as it is today (the contract's gross amount); matching the
-- range on the net amount for net lines is the next step, after the owner validates these tables.
--
-- Built like the NASP tables, as the company's first administrator. Runs only in the company that has the bank FINTECH
-- CORBAN and the three agreements; anywhere else, and when FINTECH tables already exist, it does nothing.

do $$
declare
  v_org uuid;
  v_admin uuid;
  v_bank uuid;
  v_route uuid;
  v_table uuid;
  v_version uuid;
  v_condition uuid;
  v_type uuid;
  v_avista uuid;
  v_groups jsonb;
  v_tables integer := 0;
  v_lines integer := 0;
  v_prev integer;
  r record;
begin
  select b.organization_id, b.id into v_org, v_bank
  from public.organization_banks b where b.name = 'FINTECH CORBAN' and b.is_active;
  if v_org is null or (select count(*) from public.organization_agreements a
                       where a.organization_id = v_org and a.is_active and a.name in ('FGTS', 'INSS', 'CLT Privado')) <> 3 then
    raise notice 'fintech corban: company not here, nothing to do'; return;
  end if;
  if exists (select 1 from public.product_tables t where t.organization_id = v_org and t.code like 'fintech-%') then
    raise notice 'fintech corban: tables already exist'; return;
  end if;

  select m.user_id into v_admin from public.organization_memberships m
  where m.organization_id = v_org and m.role = 'admin' and m.status = 'active' order by m.created_at limit 1;
  select k.id into v_avista from public.commission_component_types k where k.name = 'À Vista' and k.is_active;
  if v_admin is null or v_avista is null then raise exception 'fintech_missing_catalog'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  for r in
    select x.*, a.id as agreement_id from (values
      (976, 43014, 'FLEX FGTS', 'FGTS', 'novo', 1, 96, 0, 50000, '9.5', 'LÍQUIDO', date '2026-09-03', '6.175','7.6','4.75','2.375','0.95'),
      (632, 43015, 'SAQUE - FGTS - BFFUNDO - TX 1,80 - NORMAL', 'FGTS', 'novo', 1, 96, 40, 150, '45', 'LÍQUIDO', date '2026-06-08', '29.25','36','22.5','11.25','4.5'),
      (632, 43015, 'SAQUE - FGTS - BFFUNDO - TX 1,80 - NORMAL', 'FGTS', 'novo', 1, 96, 150.01, 250, '35', 'LÍQUIDO', date '2026-06-08', '22.75','28','17.5','8.75','3.5'),
      (632, 43015, 'SAQUE - FGTS - BFFUNDO - TX 1,80 - NORMAL', 'FGTS', 'novo', 1, 96, 250.01, 600, '20.5', 'LÍQUIDO', date '2026-06-08', '13.325','16.4','10.25','5.125','2.05'),
      (632, 43015, 'SAQUE - FGTS - BFFUNDO - TX 1,80 - NORMAL', 'FGTS', 'novo', 1, 96, 600.01, 49999.99, '18.5', 'LÍQUIDO', date '2026-06-08', '12.025','14.8','9.25','4.625','1.85'),
      (632, 43015, 'SAQUE - FGTS - BFFUNDO - TX 1,80 - NORMAL', 'FGTS', 'novo', 1, 96, 50000, 50000, '0', 'LÍQUIDO', date '2026-06-08', '0','0','0','0','0'),
      (948, 43017, 'FIXO 10', 'FGTS', 'novo', 1, 96, 0, 30000, '14.5', 'LÍQUIDO', date '2026-06-08', '9.425','11.6','7.25','3.625','1.45'),
      (949, 43018, 'FIXO 15', 'FGTS', 'novo', 1, 96, 0, 30000, '21', 'LÍQUIDO', date '2026-09-03', '13.65','16.8','10.5','5.25','2.1'),
      (996, 43019, 'FIXO 20', 'FGTS', 'novo', 1, 96, 0, 30000, '30', 'LÍQUIDO', date '2026-06-08', '19.5','24','15','7.5','3'),
      (961, 43021, 'FIXO 30', 'FGTS', 'novo', 1, 96, 0, 1400, '50', 'LÍQUIDO', date '2026-06-08', '32.5','40','25','12.5','5'),
      (963, 43022, 'FIXO 25', 'FGTS', 'novo', 1, 96, 0, 10000, '38', 'LÍQUIDO', date '2026-06-08', '24.7','30.4','19','9.5','3.8'),
      (1015, 43023, 'PRIVADO - C', 'CLT Privado', 'novo', 6, 6, 500, 20000, '0.5', 'LÍQUIDO', date '2026-07-08', '0.325','0.4','0.25','0.125','0.05'),
      (1015, 43023, 'PRIVADO - C', 'CLT Privado', 'novo', 9, 9, 500, 20000, '1.5', 'LÍQUIDO', date '2026-07-08', '0.975','1.2','0.75','0.375','0.15'),
      (1015, 43023, 'PRIVADO - C', 'CLT Privado', 'novo', 12, 12, 500, 20000, '2', 'LÍQUIDO', date '2026-07-08', '1.3','1.6','1','0.5','0.2'),
      (1015, 43023, 'PRIVADO - C', 'CLT Privado', 'novo', 15, 15, 500, 20000, '2.5', 'LÍQUIDO', date '2026-07-08', '1.625','2','1.25','0.625','0.25'),
      (1015, 43023, 'PRIVADO - C', 'CLT Privado', 'novo', 18, 18, 500, 20000, '3', 'LÍQUIDO', date '2026-07-08', '1.95','2.4','1.5','0.75','0.3'),
      (1015, 43023, 'PRIVADO - C', 'CLT Privado', 'novo', 24, 24, 500, 20000, '4', 'LÍQUIDO', date '2026-07-08', '2.6','3.2','2','1','0.4'),
      (1019, 43024, 'PRIVADO - C-SEGURO', 'CLT Privado', 'novo', 18, 18, 500, 20000, '4', 'LÍQUIDO', date '2026-07-08', '2.6','3.2','2','1','0.4'),
      (1019, 43024, 'PRIVADO - C-SEGURO', 'CLT Privado', 'novo', 24, 24, 500, 20000, '6.5', 'LÍQUIDO', date '2026-07-08', '4.225','5.2','3.25','1.625','0.65'),
      (991, 43025, 'NOVO - INSS - FP - NORMAL- TX 1,85', 'INSS', 'novo', 84, 84, 1000, 125000, '5.5', 'LÍQUIDO', date '2026-06-08', '3.575','4.4','2.75','1.375','0.55'),
      (991, 43025, 'NOVO - INSS - FP - NORMAL- TX 1,85', 'INSS', 'novo', 96, 96, 1000, 125000, '10.5', 'LÍQUIDO', date '2026-06-08', '6.825','8.4','5.25','2.625','1.05'),
      (991, 43025, 'NOVO - INSS - FP - NORMAL- TX 1,85', 'INSS', 'novo', 108, 108, 1000, 125000, '10.5', 'LÍQUIDO', date '2026-06-08', '6.825','8.4','5.25','2.625','1.05'),
      (1066, 43026, 'NOVO - INSS - FP - NORMAL- TX 1,85 - CARÊNCIA 90', 'INSS', 'novo', 84, 84, 1000, 125000, '5.5', 'LÍQUIDO', date '2026-06-08', '3.575','4.4','2.75','1.375','0.55'),
      (1066, 43026, 'NOVO - INSS - FP - NORMAL- TX 1,85 - CARÊNCIA 90', 'INSS', 'novo', 96, 96, 1000, 125000, '10.5', 'LÍQUIDO', date '2026-06-08', '6.825','8.4','5.25','2.625','1.05'),
      (1066, 43026, 'NOVO - INSS - FP - NORMAL- TX 1,85 - CARÊNCIA 90', 'INSS', 'novo', 108, 108, 1000, 125000, '11.5', 'LÍQUIDO', date '2026-06-08', '7.475','9.2','5.75','2.875','1.15'),
      (1011, 43027, 'PORT + REFIN - 1,75', 'INSS', 'refin_portabilidade', 1, 108, 5000, 125000, '3.5', 'BRUTO', date '2026-06-08', '2.275','2.8','1.75','0.875','0.35'),
      (1005, 43028, 'PORT + REFIN - 1,80', 'INSS', 'refin_portabilidade', 1, 108, 5000, 125000, '4.5', 'BRUTO', date '2026-06-08', '2.925','3.6','2.25','1.125','0.45'),
      (994, 43029, 'PORT + REFIN - 1,85', 'INSS', 'refin_portabilidade', 1, 108, 5000, 125000, '5.5', 'BRUTO', date '2026-06-08', '3.575','4.4','2.75','1.375','0.55'),
      (1021, 43030, 'PORT + REFIN ESPECIAL 2', 'INSS', 'refin_portabilidade', 1, 108, 10000, 125000, '2.5', 'BRUTO', date '2026-06-08', '1.625','2','1.25','0.625','0.25'),
      (1023, 43031, 'PORT + REFIN ESPECIAL 3', 'INSS', 'refin_portabilidade', 1, 108, 10000, 125000, '0.7', 'BRUTO', date '2026-06-08', '0.455','0.56','0.35','0.175','0.07'),
      (945, 43051, 'PORTABILIDADE ENTRADA', 'INSS', 'portabilidade', 1, 108, 1000, 125000, '0', 'BRUTO', date '2026-06-09', '0','0','0','0','0'),
      (1070, 44249, 'J17 - FIXO 10', 'FGTS', 'novo', 1, 96, 0, 2500, '14.5', 'LÍQUIDO', date '2026-07-06', '9.425','11.6','7.25','3.625','1.45'),
      (1071, 45356, 'J17 - FIXO 15', 'FGTS', 'novo', 1, 96, 0, 2500, '21', 'LÍQUIDO', date '2026-09-03', '13.65','16.8','10.5','5.25','2.1'),
      (1072, 46463, 'J17 - FIXO 20', 'FGTS', 'novo', 1, 96, 0, 2500, '30', 'LÍQUIDO', date '2026-07-06', '19.5','24','15','7.5','3'),
      (1073, 47570, 'J17 - FIXO 25', 'FGTS', 'novo', 1, 96, 0, 2500, '38', 'LÍQUIDO', date '2026-07-06', '24.7','30.4','19','9.5','3.8'),
      (1074, 48677, 'J17 - FIXO 30', 'FGTS', 'novo', 1, 96, 0, 2500, '50', 'LÍQUIDO', date '2026-07-06', '32.5','40','25','12.5','5'),
      (1067, 49787, 'NOVO - INSS - FP - NORMAL- TX 1,85 - INVALIDEZ', 'INSS', 'novo', 84, 108, 1000, 125000, '3.5', 'LÍQUIDO', date '2026-07-06', '2.275','2.8','1.75','0.875','0.35'),
      (1068, 50762, 'NOVO - INSS - FP - NORMAL- TX 1,85 - INVALIDEZ CARÊNCIA 90', 'INSS', 'novo', 84, 108, 1000, 125000, '4', 'LÍQUIDO', date '2026-07-06', '2.6','3.2','2','1','0.4'),
      (1091, 57453, 'PORTABILIDADE PURA - 1,66', 'INSS', 'portabilidade', 72, 108, 15000, 125000, '0.5', 'LÍQUIDO', date '2026-08-11', '0.325','0.4','0.25','0.125','0.05'),
      (1092, 57595, 'PORTABILIDADE PURA - 1,68', 'INSS', 'portabilidade', 72, 108, 15000, 125000, '0.8', 'LÍQUIDO', date '2026-08-11', '0.52','0.64','0.4','0.2','0.08'),
      (1093, 57737, 'PORTABILIDADE PURA - 1,70', 'INSS', 'portabilidade', 72, 95, 15000, 125000, '1.2', 'LÍQUIDO', date '2026-08-11', '0.78','0.96','0.6','0.3','0.12'),
      (1093, 57737, 'PORTABILIDADE PURA - 1,70', 'INSS', 'portabilidade', 96, 108, 15000, 125000, '2.2', 'LÍQUIDO', date '2026-08-11', '1.43','1.76','1.1','0.55','0.22'),
      (1094, 57879, 'PORTABILIDADE PURA - 1,72', 'INSS', 'portabilidade', 72, 95, 10000, 125000, '1.7', 'LÍQUIDO', date '2026-08-11', '1.105','1.36','0.85','0.425','0.17'),
      (1094, 57879, 'PORTABILIDADE PURA - 1,72', 'INSS', 'portabilidade', 96, 108, 10000, 125000, '2.25', 'LÍQUIDO', date '2026-08-11', '1.4625','1.8','1.125','0.5625','0.225'),
      (1095, 58021, 'PORTABILIDADE PURA - 1,75', 'INSS', 'portabilidade', 72, 95, 10000, 125000, '1.7', 'LÍQUIDO', date '2026-08-11', '1.105','1.36','0.85','0.425','0.17'),
      (1095, 58021, 'PORTABILIDADE PURA - 1,75', 'INSS', 'portabilidade', 96, 108, 10000, 125000, '2.7', 'LÍQUIDO', date '2026-08-11', '1.755','2.16','1.35','0.675','0.27'),
      (1096, 58163, 'PORTABILIDADE PURA - 1,78', 'INSS', 'portabilidade', 72, 95, 10000, 125000, '2.2', 'LÍQUIDO', date '2026-08-11', '1.43','1.76','1.1','0.55','0.22'),
      (1096, 58163, 'PORTABILIDADE PURA - 1,78', 'INSS', 'portabilidade', 96, 108, 10000, 125000, '3.2', 'LÍQUIDO', date '2026-08-11', '2.08','2.56','1.6','0.8','0.32'),
      (1097, 58305, 'PORTABILIDADE PURA - 1,80', 'INSS', 'portabilidade', 72, 83, 10000, 125000, '2.7', 'LÍQUIDO', date '2026-08-11', '1.755','2.16','1.35','0.675','0.27'),
      (1097, 58305, 'PORTABILIDADE PURA - 1,80', 'INSS', 'portabilidade', 84, 95, 10000, 125000, '3.2', 'LÍQUIDO', date '2026-08-11', '2.08','2.56','1.6','0.8','0.32'),
      (1097, 58305, 'PORTABILIDADE PURA - 1,80', 'INSS', 'portabilidade', 96, 108, 10000, 125000, '4', 'LÍQUIDO', date '2026-08-11', '2.6','3.2','2','1','0.4'),
      (1098, 58447, 'PORTABILIDADE PURA - 1,83', 'INSS', 'portabilidade', 72, 83, 10000, 125000, '2.7', 'LÍQUIDO', date '2026-08-11', '1.755','2.16','1.35','0.675','0.27'),
      (1098, 58447, 'PORTABILIDADE PURA - 1,83', 'INSS', 'portabilidade', 84, 95, 10000, 125000, '3.2', 'LÍQUIDO', date '2026-08-11', '2.08','2.56','1.6','0.8','0.32'),
      (1098, 58447, 'PORTABILIDADE PURA - 1,83', 'INSS', 'portabilidade', 96, 108, 10000, 125000, '4.2', 'LÍQUIDO', date '2026-08-11', '2.73','3.36','2.1','1.05','0.42'),
      (1099, 58589, 'PORTABILIDADE PURA - 1,85', 'INSS', 'portabilidade', 72, 108, 10000, 125000, '4.5', 'LÍQUIDO', date '2026-08-11', '2.925','3.6','2.25','1.125','0.45'),
      (1090, 61748, 'INSS NOVO 20 MIL', 'INSS', 'novo', 84, 84, 20000, 125000, '6', 'LÍQUIDO', date '2026-09-03', '3.9','4.8','3','1.5','0.6'),
      (1090, 61748, 'INSS NOVO 20 MIL', 'INSS', 'novo', 96, 96, 20000, 125000, '11', 'LÍQUIDO', date '2026-09-03', '7.15','8.8','5.5','2.75','1.1'),
      (1090, 61748, 'INSS NOVO 20 MIL', 'INSS', 'novo', 108, 108, 20000, 125000, '12', 'LÍQUIDO', date '2026-09-03', '7.8','9.6','6','3','1.2'),
      (1089, 61749, 'INSS NOVO 20 MIL - CARENCIA', 'INSS', 'novo', 84, 84, 20000, 125000, '6', 'LÍQUIDO', date '2026-08-25', '3.9','4.8','3','1.5','0.6'),
      (1089, 61749, 'INSS NOVO 20 MIL - CARENCIA', 'INSS', 'novo', 96, 96, 20000, 125000, '11', 'LÍQUIDO', date '2026-08-25', '7.15','8.8','5.5','2.75','1.1'),
      (1089, 61749, 'INSS NOVO 20 MIL - CARENCIA', 'INSS', 'novo', 108, 108, 20000, 125000, '12.5', 'LÍQUIDO', date '2026-08-25', '8.125','10','6.25','3.125','1.25')
    ) as x(main_id, table_id, name, agreement, type_key, term_min, term_max, amount_min, amount_max, received, base, valid_from,
           corretor, parceiro, balcao, call_center, afiliado)
    join public.organization_agreements a on a.organization_id = v_org and a.name = x.agreement and a.is_active
    order by x.table_id, x.term_min, x.amount_min
  loop
    -- A new table at each new bank table id: its route (bank + agreement, own production), the table and a draft version.
    if v_prev is distinct from r.table_id then
      if v_version is not null then
        perform public.publish_product_table_version(v_version, (select x.effective_from::date from public.product_table_versions x where x.id = v_version));
      end if;
      v_route := null;
      select id into v_route from public.organization_product_routes
      where organization_id = v_org and org_bank_id = v_bank and org_agreement_id = r.agreement_id and org_provider_id is null and production_origin = 'own';
      if v_route is null then
        insert into public.organization_product_routes (organization_id, org_bank_id, org_provider_id, org_agreement_id, production_origin, status)
        values (v_org, v_bank, null, r.agreement_id, 'own', 'active') returning id into v_route;
      end if;
      insert into public.product_tables (organization_id, route_id, code, name, status, formalization)
      values (v_org, v_route, 'fintech-' || r.table_id, r.name, 'active', 'digital') returning id into v_table;
      insert into public.product_table_versions (organization_id, product_table_id, version, status, effective_from, metadata)
      values (v_org, v_table, 1, 'draft', r.valid_from,
              jsonb_build_object('external_table_code', r.table_id::text, 'bank_main_table_id', r.main_id::text, 'source', 'fintech_export_07_10_2026'))
      returning id into v_version;
      v_prev := r.table_id;
      v_tables := v_tables + 1;
    end if;

    select ct.id into v_type from public.contract_types ct
    where ct.tech_key = r.type_key and ct.is_active and (ct.organization_id is null or ct.organization_id = v_org)
    order by (ct.organization_id = v_org) desc nulls last limit 1;
    if v_type is null then raise exception 'fintech_missing_contract_type: %', r.type_key; end if;

    insert into public.commercial_conditions (organization_id, product_table_version_id, contract_type_id, term, term_min, term_max,
                                              amount_min, amount_max, tax_pct, created_by)
    values (v_org, v_version, v_type, r.term_min, r.term_min, r.term_max, r.amount_min, r.amount_max, 0, v_admin)
    returning id into v_condition;
    v_lines := v_lines + 1;

    if r.received::numeric > 0 then
      perform public.replace_commercial_condition_components(v_condition, jsonb_build_array(jsonb_build_object(
        'component_type_id', v_avista, 'value_kind', 'percentage', 'received_value', r.received, 'calculation_base', r.base, 'source', 'manual')));
      select jsonb_agg(jsonb_build_object('group_id', g.id, 'component_type_id', v_avista, 'value_kind', 'percentage', 'value', p.pct, 'source', 'manual'))
      into v_groups
      from (values ('Corretor', r.corretor), ('Parceiro', r.parceiro), ('Balcão', r.balcao), ('Call Center', r.call_center), ('Afiliado', r.afiliado)) as p(name, pct)
      join public.commission_groups g on g.organization_id = v_org and g.name = p.name and g.is_active;
      if jsonb_array_length(coalesce(v_groups, '[]')) <> 5 then raise exception 'fintech_missing_groups: %', r.table_id; end if;
      if public.replace_condition_group_values(v_condition, v_groups) <> 5 then raise exception 'fintech_group_values: %', r.table_id; end if;
    end if;
  end loop;
  if v_version is not null then
    perform public.publish_product_table_version(v_version, (select x.effective_from::date from public.product_table_versions x where x.id = v_version));
  end if;

  if v_tables <> 35 or v_lines <> 61 then raise exception 'fintech_count_mismatch: % tables, % lines', v_tables, v_lines; end if;
  if exists (select 1 from public.product_tables t join public.product_table_versions v on v.product_table_id = t.id
             where t.organization_id = v_org and t.code like 'fintech-%' and v.status <> 'published') then
    raise exception 'fintech_not_published';
  end if;

  perform set_config('request.jwt.claims', '', true);
  raise notice 'fintech corban: % tables, % lines published', v_tables, v_lines;
end
$$;
