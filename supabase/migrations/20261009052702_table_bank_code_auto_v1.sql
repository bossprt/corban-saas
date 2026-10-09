-- The bank's code of a table, filled by itself (09/10/2026). 20261008141157_factor_price_import_v1 filled
-- product_tables.bank_table_code only for the Daycoval tables that existed then; a table created or imported later (by
-- any company, MAIS VALOR included) stayed without it, so the bank's Fator Price did not find it. Now, when a table is
-- created or renamed without a code, the code comes from its system code ending in the number ("day-bev-745031") or
-- from its name starting with it ("745031 - RFN - GOV ACRE ..."); a code typed on the table page is never replaced.
-- The tables still without a code get it now by the same rule (nothing else changes).
-- Contract: tests/security/table-bank-code-auto-contract.sql

create or replace function private.table_bank_code_from(p_code text, p_name text)
returns text language sql immutable set search_path to '' as $$
  select coalesce(substring(p_code from '(?:^|-)([0-9]{5,8})$'), substring(p_name from '^([0-9]{5,8})( |-|$)'))
$$;

create or replace function private.product_tables_bank_code()
returns trigger language plpgsql set search_path to '' as $$
begin
  if new.bank_table_code is null then
    new.bank_table_code := private.table_bank_code_from(new.code, new.name);
  end if;
  return new;
end
$$;
revoke all on function private.product_tables_bank_code() from public, anon, authenticated;
create trigger product_tables_10_bank_code before insert or update of code, name, bank_table_code on public.product_tables
for each row execute function private.product_tables_bank_code();

update public.product_tables set bank_table_code = private.table_bank_code_from(code, name)
where bank_table_code is null and private.table_bank_code_from(code, name) is not null;
