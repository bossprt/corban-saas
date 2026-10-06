-- "Folha de Pagamento" (Smart Promotora) was launched with "Parcelas = 3" meaning "repeat 3 months", and the system
-- divided R$ 1.432,40 into 3 installments (477,46 + 477,46 + 477,48), as the field then did (owner, 06/10/2026). This
-- cancels those 3 open entries with the reason recorded (they stay in the history) and launches the same payable as
-- intended: R$ 1.432,40 every month for 4 months (the owner asked for 4), due on 07/10, 07/11, 07/12/2026 and
-- 07/01/2027, same plan account, branch and counterpart,
-- through public.fin_cancel_entry and public.fin_create_entry (repeat), as the user who launched it. Runs once: only
-- when the 3 open divided entries are there and the repeated ones are not.

do $$
declare
  v_org uuid;
  v_group uuid;
  e record;
  v_first record;
begin
  select o.id into v_org from public.organizations o where o.name = 'Smart Promotora Ltda.';
  if v_org is null then raise notice 'payroll fix: company not here'; return; end if;
  select installment_group into v_group from public.fin_entries
  where organization_id = v_org and description = 'Folha de Pagamento (1/3)' and amount = 477.46 and status = 'open' and installments = 3
  limit 1;
  if v_group is null or (select count(*) from public.fin_entries where installment_group = v_group and status = 'open') <> 3 then
    raise notice 'payroll fix: divided entries not found as expected, nothing to do'; return;
  end if;
  if exists (select 1 from public.fin_entries where organization_id = v_org and description like 'Folha de Pagamento (_/4)' and amount = 1432.40 and status <> 'cancelled') then
    raise notice 'payroll fix: repeated entries already there'; return;
  end if;
  select * into v_first from public.fin_entries where installment_group = v_group and installment_no = 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_first.created_by, 'role', 'authenticated')::text, true);
  for e in select id from public.fin_entries where installment_group = v_group order by installment_no loop
    perform public.fin_cancel_entry(e.id, 'Lançado como parcelamento por engano: era repetir R$ 1.432,40 por mês (corrigido em 06/10/2026: 4 meses)');
  end loop;
  perform public.fin_create_entry(v_org, 'out', 'Folha de Pagamento', v_first.account_id, v_first.branch_id, v_first.counterpart, v_first.document,
    1432.40, date '2026-10-07', date '2026-10-07', 4, null, null, true);
  perform set_config('request.jwt.claims', '', true);
end
$$;
