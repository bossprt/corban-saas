-- Contas a pagar e receber: installments inside the same month (owner request 06/10/2026). Repeating or splitting went
-- month by month only; fin_create_entry gains p_interval_days: null keeps one month apart (as before); a number of days
-- (7, 15, 10...) puts each installment that many days after the previous one, for due and competence alike. Everything
-- else is unchanged. Same signature plus the new parameter with its default.

drop function public.fin_create_entry(uuid, text, text, uuid, uuid, text, text, numeric, date, date, integer, date, uuid, boolean);

create function public.fin_create_entry(p_org uuid, p_direction text, p_description text, p_account uuid, p_branch uuid, p_counterpart text,
  p_document text, p_amount numeric, p_due_on date, p_competence_on date, p_installments integer, p_settled_on date, p_bank_account uuid,
  p_repeat boolean default false, p_interval_days integer default null)
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
  if p_interval_days is not null and (p_interval_days < 1 or p_interval_days > 365) then raise exception 'fin_installments_invalid'; end if;
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
              case when i = v_n then v_last else v_part end,
              case when p_interval_days is null then (p_due_on + make_interval(months => i - 1))::date else p_due_on + p_interval_days * (i - 1) end,
              case when p_interval_days is null then (coalesce(p_competence_on, p_due_on) + make_interval(months => i - 1))::date
                   else coalesce(p_competence_on, p_due_on) + p_interval_days * (i - 1) end,
              p_settled_on, case when p_settled_on is null then null else p_bank_account end, 'manual',
              case when v_n > 1 then v_group end, case when v_n > 1 then i end, case when v_n > 1 then v_n end, auth.uid())
      returning id into v_id;
    exception when check_violation then raise exception 'fin_entry_invalid';
    end;
    perform private.fin_event(p_org, v_id, 'created', jsonb_build_object('amount', case when i = v_n then v_last else v_part end, 'repeat', coalesce(p_repeat, false), 'interval_days', p_interval_days), null);
    if p_settled_on is not null then perform private.fin_event(p_org, v_id, 'settled', jsonb_build_object('on', p_settled_on, 'bank', p_bank_account), null); end if;
    v_first := coalesce(v_first, v_id);
  end loop;
  return v_first;
end
$function$;
revoke all on function public.fin_create_entry(uuid, text, text, uuid, uuid, text, text, numeric, date, date, integer, date, uuid, boolean, integer) from public, anon;
grant execute on function public.fin_create_entry(uuid, text, text, uuid, uuid, text, text, numeric, date, date, integer, date, uuid, boolean, integer) to authenticated;
