-- Commission receipt registered by hand on the contract (owner request 29/09/2026): for a bank that sends no report, or
-- money seen in the account before the report arrives.
--
-- It is the same path as a bank report, with one line, in one call: import_receipt_report (financeiro.edit) creates a
-- draft "Lançamento manual" report from the contract's paying source (the partner promoter when the production goes
-- through one, else the bank), link_receipt_line ties the line to this contract (expected value from the active
-- calculation, installment, duplicates, a chargeback beyond what was received flagged divergent), and confirm_receipt_report
-- (financeiro.approve) books it. So the receipt, its reconciliation (matched or divergent, then Conciliação), the
-- company finance entry and the seller credit follow exactly as for a file. Nothing is written if any step refuses.
-- Security invoker: every step checks the caller's own permissions.

create or replace function public.register_manual_receipt(
  p_proposal_id uuid, p_kind text, p_amount text, p_received_on date, p_installment integer, p_note text)
returns uuid
language plpgsql
set search_path to ''
as $$
declare
  p record;
  v_source_kind text;
  v_source uuid;
  v_report uuid;
  v_line public.receipt_lines%rowtype;
  v_receipt uuid;
  v_note text := left(btrim(coalesce(p_note, '')), 100);
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if coalesce(p_kind, '') not in ('upfront', 'deferred', 'chargeback') then raise exception 'invalid_receipt_kind'; end if;
  if coalesce(p_amount, '') !~ '^\d{1,13}(\.\d{1,2})?$' or p_amount::numeric <= 0 then raise exception 'invalid_receipt_amount'; end if;
  if p_received_on is null or p_received_on < date '2000-01-01' or p_received_on > (now() at time zone 'America/Sao_Paulo')::date then
    raise exception 'invalid_receipt_date';
  end if;
  if p_installment is not null and (p_kind <> 'deferred' or p_installment < 1 or p_installment > 9999) then raise exception 'invalid_receipt_installment'; end if;

  -- RLS: only a contract the caller can see.
  select x.id, x.organization_id, x.external_proposal_id, r.production_origin, r.org_bank_id, r.org_provider_id into p
  from public.proposals_v2 x
  join public.product_table_versions v on v.id = x.product_table_version_id
  join public.product_tables t on t.id = v.product_table_id
  join public.organization_product_routes r on r.id = t.route_id
  where x.id = p_proposal_id;
  if p.id is null then raise exception 'proposal_not_found'; end if;
  if not public.has_permission(p.organization_id, 'financeiro.approve') then raise exception 'not_authorized'; end if;
  if p.production_origin = 'third_party' and p.org_provider_id is not null then
    v_source_kind := 'provider'; v_source := p.org_provider_id;
  elsif p.org_bank_id is not null then
    v_source_kind := 'bank'; v_source := p.org_bank_id;
  else
    raise exception 'receipt_source_not_found';
  end if;

  v_report := public.import_receipt_report(
    p.organization_id, v_source_kind, v_source, p_kind, p_received_on,
    'Lançamento manual', encode(extensions.digest(convert_to(p.id::text || '|' || p_kind || '|' || p_amount || '|' || p_received_on::text || '|' || auth.uid()::text || '|' || clock_timestamp()::text, 'UTF8'), 'sha256'), 'hex'),
    p_amount::numeric,
    jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'row', 1, 'ade', coalesce(nullif(btrim(p.external_proposal_id), ''), 'MANUAL'), 'amount', p_amount,
      'installment', p_installment::text, 'paid_on', p_received_on::text,
      'bank', 'Lançamento manual' || case when v_note <> '' then ': ' || v_note else '' end))));

  select * into v_line from public.receipt_lines where report_id = v_report;
  perform public.link_receipt_line(v_line.id, p.id);
  select * into v_line from public.receipt_lines where id = v_line.id;
  if v_line.status = 'duplicate' then raise exception 'manual_receipt_duplicate'; end if;
  if v_line.status = 'no_calc' then raise exception 'manual_receipt_no_calc'; end if;
  if v_line.status = 'installment_invalid' then raise exception 'manual_receipt_installment_invalid'; end if;
  if v_line.status not in ('ok', 'divergent') then raise exception 'manual_receipt_not_matched'; end if;

  perform public.confirm_receipt_report(v_report);
  select id into v_receipt from public.commission_receipts where line_id = v_line.id;
  return v_receipt;
end
$$;
revoke all on function public.register_manual_receipt(uuid, text, text, date, integer, text) from public, anon;
grant execute on function public.register_manual_receipt(uuid, text, text, date, integer, text) to authenticated;
