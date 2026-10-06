-- Contas a pagar e receber: "repeat" next to "split" (owner request 06/10/2026). "Parcelas" read as "repeat 3 times" (a
-- salary, the rent) but the system divided the amount by 3. fin_create_entry gains p_repeat: false keeps the split
-- (the total divided into monthly installments, the last one absorbing the cents); true launches the same amount every
-- month, N times. Everything else is unchanged: one group, "(1/3)" in the description, due and competence one month
-- apart, settlement only for a single entry. Same signature plus the new parameter with its default, so callers that
-- do not pass it keep splitting.

drop function public.fin_create_entry(uuid, text, text, uuid, uuid, text, text, numeric, date, date, integer, date, uuid);

create function public.fin_create_entry(p_org uuid, p_direction text, p_description text, p_account uuid, p_branch uuid, p_counterpart text,
  p_document text, p_amount numeric, p_due_on date, p_competence_on date, p_installments integer, p_settled_on date, p_bank_account uuid,
  p_repeat boolean default false)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_n integer := coalesce(p_installments, 1);
  v_part numeric; v_last numeric; v_group uuid := gen_random_uuid(); v_id uuid; v_first uuid; i integer;
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if p_direction not in ('in', 'out') then raise exception 'fin_entry_invalid'; end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) or p_amount >= 1e13 then raise exception 'invalid_amount'; end if;
  if v_n < 1 or v_n > 60 then raise exception 'fin_installments_invalid'; end if;
  if p_due_on is null then raise exception 'fin_due_required'; end if;
  if p_settled_on is not null and (v_n > 1 or p_settled_on > current_date) then raise exception 'fin_settle_invalid'; end if;
  perform private.fin_check_refs(p_org, p_account, p_branch, p_bank_account);
  if coalesce(p_repeat, false) then
    v_part := p_amount;
    v_last := p_amount;
  else
    v_part := trunc(p_amount / v_n, 2);
    v_last := p_amount - v_part * (v_n - 1);
  end if;
  if v_part <= 0 then raise exception 'invalid_amount'; end if;
  for i in 1..v_n loop
    begin
      insert into public.fin_entries (organization_id, direction, status, description, account_id, branch_id, counterpart, document, amount, due_on, competence_on,
                                      settled_on, bank_account_id, source, installment_group, installment_no, installments, created_by)
      values (p_org, p_direction, case when p_settled_on is null then 'open' else 'settled' end,
              btrim(p_description) || case when v_n > 1 then ' (' || i || '/' || v_n || ')' else '' end,
              p_account, p_branch, nullif(btrim(coalesce(p_counterpart, '')), ''), nullif(btrim(coalesce(p_document, '')), ''),
              case when i = v_n then v_last else v_part end, (p_due_on + make_interval(months => i - 1))::date,
              (coalesce(p_competence_on, p_due_on) + make_interval(months => i - 1))::date,
              p_settled_on, case when p_settled_on is null then null else p_bank_account end, 'manual',
              case when v_n > 1 then v_group end, case when v_n > 1 then i end, case when v_n > 1 then v_n end, auth.uid())
      returning id into v_id;
    exception when check_violation then raise exception 'fin_entry_invalid';
    end;
    perform private.fin_event(p_org, v_id, 'created', jsonb_build_object('amount', case when i = v_n then v_last else v_part end, 'repeat', coalesce(p_repeat, false)), null);
    if p_settled_on is not null then perform private.fin_event(p_org, v_id, 'settled', jsonb_build_object('on', p_settled_on, 'bank', p_bank_account), null); end if;
    v_first := coalesce(v_first, v_id);
  end loop;
  return v_first;
end
$function$;
revoke all on function public.fin_create_entry(uuid, text, text, uuid, uuid, text, text, numeric, date, date, integer, date, uuid, boolean) from public, anon;
grant execute on function public.fin_create_entry(uuid, text, text, uuid, uuid, text, text, numeric, date, date, integer, date, uuid, boolean) to authenticated;
