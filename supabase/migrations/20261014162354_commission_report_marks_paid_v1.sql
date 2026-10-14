-- Owner (14/10/2026): when the bank pays the commission of a contract, the client already got the money. Confirming a
-- commission report moves each contract of the report that is not yet "Paga" to "Paga" (pago ao cliente), so the seller's
-- share is released without waiting for someone to update the pipeline. Only contracts with a seller and an active
-- commission calculation move; the others stay as they are and the report page lists them to check. Chargeback reports
-- never move anything. The move is recorded in the pipeline history as "pelo relatório de comissão".

alter table public.proposal_status_evidence drop constraint proposal_status_evidence_source_check;
alter table public.proposal_status_evidence add constraint proposal_status_evidence_source_check
  check (source = any (array['import'::text, 'manual'::text, 'commission_report'::text]));

-- Moves one contract to "Paga" because a confirmed commission report paid it. Caller holds the report lock and has
-- already checked financeiro.approve; returns false when the contract does not qualify (and then nothing changes).
create or replace function private.mark_paid_by_commission_report(p_proposal uuid, p_report uuid, p_paid_on date)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
declare
  p public.proposals_v2%rowtype;
  c public.operational_cases%rowtype;
  s public.operational_stages%rowtype;
  rep public.receipt_reports%rowtype;
  v_paid_on date := least(coalesce(p_paid_on, current_date), current_date);
  v_note text;
begin
  select * into rep from public.receipt_reports where id = p_report;
  select * into p from public.proposals_v2 where id = p_proposal and organization_id = rep.organization_id for update;
  if p.id is null or p.status in ('paid', 'cancelled', 'rejected') then return false; end if;
  if p.seller_id is null then return false; end if;
  if not exists (select 1 from public.proposal_commission_calcs x where x.proposal_id = p.id and x.status = 'active') then return false; end if;

  v_note := left('Pago ao cliente pelo relatório de comissão ' || coalesce(rep.file_name, ''), 500);

  perform set_config('corban.operational_rpc', 'on', true);
  perform set_config('corban.proposal_rpc', 'on', true);
  perform set_config('corban.stage_move_rpc', 'on', true);
  perform set_config('corban.paid_evidence_rpc', 'on', true);

  select * into c from public.operational_cases where proposal_id = p.id and organization_id = p.organization_id for update;
  if c.id is not null then
    select * into s from public.operational_stages
    where organization_id = p.organization_id and canonical_state = 'paid' and is_active
    order by sort_order limit 1;
    if s.id is not null and s.id is distinct from c.current_stage_id then
      update public.operational_cases
      set current_stage_id = s.id, canonical_state = s.canonical_state, entered_stage_at = now(),
          due_at = case when s.sla_minutes is null then null else now() + make_interval(mins => s.sla_minutes) end,
          pendency_reason = null, pendency_due_at = null, updated_at = now()
      where id = c.id;
      if c.digitization_job_id is not null then
        update public.digitization_jobs set status = 'completed', updated_at = now()
        where organization_id = c.organization_id and id = c.digitization_job_id;
      end if;
      insert into public.operational_events (organization_id, operational_case_id, event_type, from_state, to_state, source, actor_user_id, metadata)
      values (c.organization_id, c.id, 'state_transition', c.canonical_state, s.canonical_state, 'corban_os', auth.uid(),
              jsonb_build_object('note', v_note, 'paid_on', v_paid_on, 'from_stage_id', c.current_stage_id, 'to_stage_id', s.id,
                                 'receipt_report_id', p_report));
    end if;
  end if;

  update public.proposals_v2 set status = 'paid', paid_to_client_on = v_paid_on, updated_at = now() where id = p.id;
  insert into public.proposal_status_evidence (organization_id, proposal_id, canonical_status, raw_status, evidenced_at, created_by, source, note)
  values (p.organization_id, p.id, 'paid', 'commission_report', now(), auth.uid(), 'commission_report', v_note);

  perform set_config('corban.paid_evidence_rpc', 'off', true);
  perform set_config('corban.stage_move_rpc', 'off', true);
  perform set_config('corban.proposal_rpc', 'off', true);
  perform set_config('corban.operational_rpc', 'off', true);
  return true;
end
$function$;

revoke all on function private.mark_paid_by_commission_report(uuid, uuid, date) from public, anon, authenticated;

create or replace function public.confirm_receipt_report(p_report_id uuid)
 returns integer
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  rep public.receipt_reports%rowtype;
  v_count int;
  r record;
begin
  select * into rep from public.receipt_reports where id = p_report_id for update;
  if rep.id is null or auth.uid() is null or not public.has_permission(rep.organization_id, 'financeiro.approve') then raise exception 'not_authorized'; end if;
  if rep.status <> 'draft' then raise exception 'receipt_report_is_closed'; end if;

  perform set_config('corban.receipt_rpc', 'on', true);
  -- The frozen commission may have changed since the import: compare again right before writing.
  perform private.rematch_receipt_report(p_report_id);
  if exists (select 1 from public.receipt_lines where report_id = p_report_id and status not in ('ok','divergent','ignored')) then
    raise exception 'receipt_report_has_unresolved_lines';
  end if;
  if rep.declared_total is not null and rep.declared_total <> rep.lines_total then raise exception 'receipt_total_mismatch'; end if;

  insert into public.commission_receipts (organization_id, proposal_id, calc_id, report_id, line_id, entry_kind, component_key, installment_number,
                                          amount, expected_amount, reconciliation, received_on, created_by)
  select l.organization_id, l.proposal_id, l.calc_id, l.report_id, l.id,
         case when rep.report_kind = 'chargeback' then 'chargeback' else 'receipt' end,
         l.component_key, l.assigned_installment, l.amount, l.expected_amount,
         case when l.status = 'ok' then 'matched' else 'divergent' end,
         coalesce(l.paid_on, rep.reference_month), auth.uid()
  from public.receipt_lines l
  where l.report_id = p_report_id and l.status in ('ok','divergent')
  order by l.row_number;
  get diagnostics v_count = row_count;

  update public.receipt_reports set status = 'confirmed', confirmed_by = auth.uid(), confirmed_at = now() where id = p_report_id;
  perform set_config('corban.receipt_rpc', 'off', true);

  -- The bank paid the commission, so the client got the money: contracts still open move to "Paga" (14/10/2026).
  if rep.report_kind <> 'chargeback' then
    for r in
      select l.proposal_id, min(l.paid_on) as paid_on
      from public.receipt_lines l
      where l.report_id = p_report_id and l.status in ('ok','divergent') and l.proposal_id is not null
      group by l.proposal_id
    loop
      perform private.mark_paid_by_commission_report(r.proposal_id, p_report_id, r.paid_on);
    end loop;
  end if;
  return v_count;
end
$function$;
