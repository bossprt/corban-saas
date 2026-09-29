-- Rounding leftovers of the 26/09 share conversion (20260926010227_commission_group_values_v1).
--
-- The conversion computed value = received x share / 100, with the share stored at 6 decimals. A share of 3/7
-- (42.857142857...%) was kept as 42.857143, so 7 x 42.857143 / 100 became 3.00000001 instead of 3. Production had 8
-- such values out of 24,609 (PROSESP, Governo do Acre, Efetivo 24 and 36 months, Corretor and Parceiro), all in draft
-- table versions. Owner approval 28/09/2026.
--
-- Only converted values within 0.000001 of a 4-decimal number are touched. The update goes through the governed flag,
-- so the guard still refuses any value of a published version (fail closed instead of rewriting financial history).

do $$
declare
  v_fixed integer;
begin
  perform set_config('corban.group_values_rpc', 'on', true);
  update public.commercial_condition_group_values
     set value = trim_scale(round(value, 4))
   where source = 'converted'
     and value <> round(value, 4)
     and abs(value - round(value, 4)) <= 0.000001;
  get diagnostics v_fixed = row_count;
  perform set_config('corban.group_values_rpc', 'off', true);
  raise notice 'group values rounded: %', v_fixed;

  if exists (select 1 from public.commercial_condition_group_values
             where source = 'converted' and value <> round(value, 4) and abs(value - round(value, 4)) <= 0.000001) then
    raise exception 'group_value_rounding_left_rows';
  end if;
end
$$;
