-- Contracts API (ADR-0056): table aliases for the NASP at Smart Promotora (owner approval, 13/10/2026).
-- The NASP has one table "Normal - Efetivo / Pensionista" for new, refinancing and debt purchase; Corban has one table
-- per type in Governo do Acre. "novo" already matches by name; these two say which Corban table the other types use.
-- Found by name inside the Smart company and its NASP bank; stops if a table is missing or repeated.

do $$
declare
  v_org constant uuid := '62405e20-af29-4359-b39c-79c206146b6c';
  v_bank uuid;
  v_table uuid;
  x record;
begin
  select b.id into strict v_bank from public.organization_banks b where b.organization_id = v_org and b.name = 'NASP';
  for x in select * from (values
    ('refinanciamento', 'NASP - Gov. Acre - REFIN - NORMAL'),
    ('compra_de_divida', 'NASP - Gov. Acre - COMPRA NORMAL')) as a(type_key, table_name)
  loop
    select t.id into strict v_table from public.product_tables t
    join public.organization_product_routes r on r.id = t.route_id and r.org_bank_id = v_bank
    where t.organization_id = v_org and t.name = x.table_name and t.status = 'active';
    insert into public.api_contract_table_aliases (organization_id, bank_id, external_table, contract_type_key, product_table_id)
    values (v_org, v_bank, 'Normal - Efetivo / Pensionista', x.type_key, v_table)
    on conflict (organization_id, bank_id, external_table, contract_type_key) do nothing;
  end loop;
end
$$;
