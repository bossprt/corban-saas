-- Undo a statement reconciliation and bring an ignored line back (owner approval 04/11/2026). A wrong click on the
-- statement screen used to be permanent. Nothing is deleted: the line goes back to pending, the entry goes back to the
-- state it had before the reconciliation (or is cancelled when it was created from the line), and both keep a record.

alter table public.fin_entry_events drop constraint fin_entry_events_kind_check;
alter table public.fin_entry_events add constraint fin_entry_events_kind_check
  check (kind in ('created', 'edited', 'settled', 'settlement_undone', 'cancelled', 'reconciled', 'reconciliation_undone'));

-- What happened to each statement line: ignored, brought back, reconciliation undone. Written only by the functions.
alter table public.fin_statement_lines add constraint fin_statement_lines_org_id_key unique (organization_id, id);
create table public.fin_statement_line_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  line_id uuid not null,
  kind text not null check (kind in ('ignored', 'restored', 'unmatched')),
  entry_id uuid,
  reason text,
  actor_user_id uuid,
  created_at timestamptz not null default now(),
  foreign key (organization_id, line_id) references public.fin_statement_lines (organization_id, id)
);
create index fin_statement_line_events_line on public.fin_statement_line_events (line_id, created_at);
alter table public.fin_statement_line_events enable row level security;
create policy fin_statement_line_events_select on public.fin_statement_line_events for select to authenticated
  using (public.has_permission(organization_id, 'financeiro.view'));
revoke all on public.fin_statement_line_events from public, anon, authenticated;
grant select on public.fin_statement_line_events to authenticated;

create or replace function public.fin_ignore_line(p_line uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare l public.fin_statement_lines%rowtype;
begin
  select * into l from public.fin_statement_lines where id = p_line for update;
  if l.id is null or auth.uid() is null or not public.has_permission(l.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if l.status <> 'pending' then raise exception 'fin_line_not_pending'; end if;
  update public.fin_statement_lines set status = 'ignored' where id = l.id;
  insert into public.fin_statement_line_events (organization_id, line_id, kind, actor_user_id) values (l.organization_id, l.id, 'ignored', auth.uid());
end
$$;
revoke all on function public.fin_ignore_line(uuid) from public, anon;
grant execute on function public.fin_ignore_line(uuid) to authenticated;

-- The reconciliation now notes whether it settled the entry and the bank account the entry had before, so it can be
-- undone exactly. Otherwise the same as 20260927204141.
create or replace function public.fin_match_line(p_line uuid, p_entry uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare l public.fin_statement_lines%rowtype; e public.fin_entries%rowtype;
begin
  select * into l from public.fin_statement_lines where id = p_line for update;
  if l.id is null or auth.uid() is null or not public.has_permission(l.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if l.status <> 'pending' then raise exception 'fin_line_not_pending'; end if;
  select * into e from public.fin_entries where id = p_entry and organization_id = l.organization_id for update;
  if e.id is null or e.status = 'cancelled' then raise exception 'fin_entry_invalid'; end if;
  if (l.amount > 0) <> (e.direction = 'in') or abs(l.amount) <> e.amount then raise exception 'fin_match_amount'; end if;
  if e.status = 'settled' and e.bank_account_id is not null and e.bank_account_id <> l.bank_account_id then raise exception 'fin_match_other_account'; end if;
  if exists (select 1 from public.fin_statement_lines x where x.entry_id = e.id) then raise exception 'fin_entry_reconciled'; end if;
  if e.status = 'open' then
    update public.fin_entries set status = 'settled', settled_on = l.posted_on, bank_account_id = l.bank_account_id, updated_at = now() where id = e.id;
    perform private.fin_event(e.organization_id, e.id, 'settled', jsonb_build_object('on', l.posted_on, 'bank', l.bank_account_id), null);
  else
    update public.fin_entries set bank_account_id = l.bank_account_id, updated_at = now() where id = e.id;
  end if;
  update public.fin_statement_lines set status = 'matched', entry_id = e.id where id = l.id;
  perform private.fin_event(e.organization_id, e.id, 'reconciled',
    jsonb_build_object('line', l.id, 'posted_on', l.posted_on, 'settled_by_match', e.status = 'open', 'bank_before', e.bank_account_id), null);
end
$$;
revoke all on function public.fin_match_line(uuid, uuid) from public, anon;
grant execute on function public.fin_match_line(uuid, uuid) to authenticated;

-- An ignored line goes back to the lines to reconcile.
create or replace function public.fin_restore_line(p_line uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare l public.fin_statement_lines%rowtype;
begin
  select * into l from public.fin_statement_lines where id = p_line for update;
  if l.id is null or auth.uid() is null or not public.has_permission(l.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if l.status <> 'ignored' then raise exception 'fin_line_not_ignored'; end if;
  update public.fin_statement_lines set status = 'pending' where id = l.id;
  insert into public.fin_statement_line_events (organization_id, line_id, kind, actor_user_id) values (l.organization_id, l.id, 'restored', auth.uid());
end
$$;
revoke all on function public.fin_restore_line(uuid) from public, anon;
grant execute on function public.fin_restore_line(uuid) to authenticated;

-- Undo a reconciliation, with a reason. The entry goes back to what it was:
--   created from the line ("criar lançamento") -> cancelled;
--   settled by the reconciliation (it was open) -> open again;
--   already settled before -> stays settled, with the bank account it had before.
-- Reconciliations made before this migration carry no note: there the 'settled' event written in the same transaction
-- (same created_at) tells that the reconciliation settled it, and the last earlier settlement gives the bank account.
create or replace function public.fin_unmatch_line(p_line uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare l public.fin_statement_lines%rowtype; e public.fin_entries%rowtype; v_at timestamptz; v_detail jsonb; v_settled boolean; v_bank uuid; v_outcome text;
begin
  select * into l from public.fin_statement_lines where id = p_line for update;
  if l.id is null or auth.uid() is null or not public.has_permission(l.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if l.status <> 'matched' then raise exception 'fin_line_not_matched'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'reason_required'; end if;
  select * into e from public.fin_entries where id = l.entry_id and organization_id = l.organization_id for update;
  if e.id is null then raise exception 'not_authorized'; end if;

  update public.fin_statement_lines set status = 'pending', entry_id = null where id = l.id;

  if e.source = 'statement' and e.source_ref = l.id then
    update public.fin_entries set status = 'cancelled', settled_on = null, updated_at = now() where id = e.id;
    v_outcome := 'cancelled';
  else
    select created_at, detail into v_at, v_detail from public.fin_entry_events
    where entry_id = e.id and kind = 'reconciled' and detail->>'line' = l.id::text order by created_at desc limit 1;
    if v_detail ? 'settled_by_match' then
      v_settled := (v_detail->>'settled_by_match')::boolean;
      v_bank := nullif(v_detail->>'bank_before', '')::uuid;
    else
      v_settled := exists (select 1 from public.fin_entry_events where entry_id = e.id and kind = 'settled' and created_at = v_at);
      select nullif(detail->>'bank', '')::uuid into v_bank from public.fin_entry_events
      where entry_id = e.id and kind = 'settled' and (v_at is null or created_at < v_at) order by created_at desc limit 1;
    end if;
    if v_settled then
      update public.fin_entries set status = 'open', settled_on = null, bank_account_id = null, updated_at = now() where id = e.id;
      v_outcome := 'reopened';
    else
      update public.fin_entries set bank_account_id = v_bank, updated_at = now() where id = e.id;
      v_outcome := 'kept_settled';
    end if;
  end if;

  perform private.fin_event(e.organization_id, e.id, 'reconciliation_undone', jsonb_build_object('line', l.id, 'outcome', v_outcome), p_reason);
  insert into public.fin_statement_line_events (organization_id, line_id, kind, entry_id, reason, actor_user_id)
  values (l.organization_id, l.id, 'unmatched', e.id, btrim(p_reason), auth.uid());
end
$$;
revoke all on function public.fin_unmatch_line(uuid, text) from public, anon;
grant execute on function public.fin_unmatch_line(uuid, text) to authenticated;
