-- Interest, fine and discount on settlement, partial payment and payment receipts (owner approval 04/11/2026).
-- Nothing is deleted: a partial payment settles what was paid and opens the remainder as a new entry linked to it;
-- undoing the settlement brings the original amount back and cancels the remainder still open.

alter table public.fin_entry_events drop constraint fin_entry_events_kind_check;
alter table public.fin_entry_events add constraint fin_entry_events_kind_check
  check (kind in ('created', 'edited', 'settled', 'settlement_undone', 'cancelled', 'reconciled', 'reconciliation_undone', 'receipt_added'));

-- interest/discount exist only while settled; the money that left/entered the account is amount + interest - discount.
-- original_amount keeps the amount before a partial payment (only while settled), remainder_of links the open rest.
alter table public.fin_entries
  add column interest numeric(15,2) not null default 0 check (interest >= 0 and interest < 1e13),
  add column discount numeric(15,2) not null default 0 check (discount >= 0 and discount < 1e13),
  add column original_amount numeric(15,2),
  add column remainder_of uuid,
  add constraint fin_entries_remainder_fk foreign key (organization_id, remainder_of) references public.fin_entries (organization_id, id),
  add constraint fin_entries_adjust_only_settled check (status = 'settled' or (interest = 0 and discount = 0 and original_amount is null)),
  add constraint fin_entries_original_gt_amount check (original_amount is null or original_amount > amount),
  add constraint fin_entries_paid_positive check (amount + interest - discount > 0);
create index fin_entries_remainder_of_idx on public.fin_entries (remainder_of) where remainder_of is not null;

-- Settle with optional paid value, interest and discount. Paid below the amount (after interest/discount) is a partial
-- payment: only for manual entries. Returns the id of the remainder entry, or null.
drop function public.fin_settle_entry(uuid, date, uuid);
create function public.fin_settle_entry(p_entry uuid, p_settled_on date, p_bank_account uuid,
                                        p_paid numeric default null, p_interest numeric default 0, p_discount numeric default 0)
returns uuid
language plpgsql
security definer
set search_path to ''
set timezone to 'America/Sao_Paulo'
as $$
declare e public.fin_entries%rowtype; v_int numeric := coalesce(p_interest, 0); v_disc numeric := coalesce(p_discount, 0); v_principal numeric; v_rest uuid;
begin
  select * into e from public.fin_entries where id = p_entry for update;
  if e.id is null or auth.uid() is null or not public.has_permission(e.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if e.status <> 'open' then raise exception 'fin_entry_not_open'; end if;
  if p_settled_on is null or p_settled_on > current_date then raise exception 'fin_settle_invalid'; end if;
  if v_int < 0 or v_disc < 0 or v_int <> round(v_int, 2) or v_disc <> round(v_disc, 2) or v_int >= 1e13 or v_disc >= 1e13 then raise exception 'fin_settle_amount'; end if;
  if p_paid is null then
    v_principal := e.amount;
  else
    if p_paid <= 0 or p_paid <> round(p_paid, 2) or p_paid >= 1e13 then raise exception 'fin_settle_amount'; end if;
    v_principal := p_paid - v_int + v_disc;
  end if;
  if v_principal <= 0 or v_principal > e.amount or v_principal + v_int - v_disc <= 0 then raise exception 'fin_settle_amount'; end if;
  if v_principal < e.amount and e.source <> 'manual' then raise exception 'fin_partial_automatic'; end if;
  perform private.fin_check_refs(e.organization_id, e.account_id, e.branch_id, p_bank_account);

  if v_principal < e.amount then
    insert into public.fin_entries (organization_id, direction, status, description, account_id, branch_id, counterpart, document,
                                    amount, due_on, competence_on, source, proposal_id, remainder_of, created_by)
    values (e.organization_id, e.direction, 'open', left(e.description || ' (restante)', 200), e.account_id, e.branch_id, e.counterpart, e.document,
            e.amount - v_principal, e.due_on, e.competence_on, 'manual', e.proposal_id, e.id, auth.uid())
    returning id into v_rest;
    perform private.fin_event(e.organization_id, v_rest, 'created', jsonb_build_object('remainder_of', e.id), null);
  end if;

  update public.fin_entries
  set status = 'settled', settled_on = p_settled_on, bank_account_id = p_bank_account, amount = v_principal, interest = v_int, discount = v_disc,
      original_amount = case when v_principal < e.amount then e.amount end, updated_at = now()
  where id = e.id;
  perform private.fin_event(e.organization_id, e.id, 'settled', jsonb_build_object('on', p_settled_on, 'bank', p_bank_account,
    'paid', v_principal + v_int - v_disc, 'interest', v_int, 'discount', v_disc, 'original_amount', e.amount, 'remainder', v_rest), null);
  return v_rest;
end
$$;
revoke all on function public.fin_settle_entry(uuid, date, uuid, numeric, numeric, numeric) from public, anon;
grant execute on function public.fin_settle_entry(uuid, date, uuid, numeric, numeric, numeric) to authenticated;

-- Undo also brings back the amount before a partial payment and cancels the remainder still open (blocked when the
-- remainder was already settled: undo that one first).
create or replace function public.fin_undo_settlement(p_entry uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare e public.fin_entries%rowtype; r public.fin_entries%rowtype;
begin
  select * into e from public.fin_entries where id = p_entry for update;
  if e.id is null or auth.uid() is null or not public.has_permission(e.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if e.status <> 'settled' then raise exception 'fin_entry_not_settled'; end if;
  if e.source <> 'manual' then raise exception 'fin_entry_automatic'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'reason_required'; end if;
  if exists (select 1 from public.fin_statement_lines l where l.entry_id = e.id) then raise exception 'fin_entry_reconciled'; end if;
  if e.original_amount is not null then
    select * into r from public.fin_entries where remainder_of = e.id and status <> 'cancelled' for update;
    if r.status = 'settled' then raise exception 'fin_remainder_settled'; end if;
    if r.id is not null then
      update public.fin_entries set status = 'cancelled', updated_at = now() where id = r.id;
      perform private.fin_event(r.organization_id, r.id, 'cancelled', jsonb_build_object('original_undone', e.id), p_reason);
    end if;
  end if;
  update public.fin_entries
  set status = 'open', settled_on = null, bank_account_id = null, amount = coalesce(e.original_amount, e.amount),
      interest = 0, discount = 0, original_amount = null, updated_at = now()
  where id = e.id;
  perform private.fin_event(e.organization_id, e.id, 'settlement_undone',
    jsonb_build_object('was', e.settled_on, 'interest', e.interest, 'discount', e.discount, 'amount_back', coalesce(e.original_amount, e.amount), 'remainder_cancelled', r.id), p_reason);
end
$$;

-- A settled entry is reconciled against what really moved: amount + interest - discount.
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
  if (l.amount > 0) <> (e.direction = 'in') or abs(l.amount) <> e.amount + e.interest - e.discount then raise exception 'fin_match_amount'; end if;
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

-- Realized values use what moved (amount + interest - discount); forecast uses the open amount.
create or replace function public.fin_cash_flow(p_org uuid, p_from date, p_to date, p_branch uuid default null)
returns table (month date, realized_in numeric, realized_out numeric, forecast_in numeric, forecast_out numeric)
language plpgsql
stable
security definer
set search_path to ''
set timezone to 'America/Sao_Paulo'
as $$
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.view') then raise exception 'not_authorized'; end if;
  return query
    with m as (select generate_series(date_trunc('month', p_from)::date, date_trunc('month', p_to)::date, interval '1 month')::date as month),
    e as (
      select date_trunc('month', coalesce(x.settled_on, x.due_on))::date as month, x.direction, x.status, x.amount + x.interest - x.discount as amount
      from public.fin_entries x join public.fin_chart_accounts a on a.id = x.account_id
      where x.organization_id = p_org and x.status <> 'cancelled' and a.kind <> 'transfer'
        and coalesce(x.settled_on, x.due_on) between p_from and p_to and (p_branch is null or x.branch_id = p_branch)
    )
    select m.month,
           coalesce(sum(e.amount) filter (where e.status = 'settled' and e.direction = 'in'), 0),
           coalesce(sum(e.amount) filter (where e.status = 'settled' and e.direction = 'out'), 0),
           coalesce(sum(e.amount) filter (where e.status = 'open' and e.direction = 'in'), 0),
           coalesce(sum(e.amount) filter (where e.status = 'open' and e.direction = 'out'), 0)
    from m left join e on e.month = m.month
    group by m.month order by m.month;
end
$$;

-- Interest and discount stay on the entry's own account in the income statement.
create or replace function public.fin_income_statement(p_org uuid, p_from date, p_to date, p_branch uuid default null)
returns table (month date, kind text, account_code text, account_name text, total numeric)
language plpgsql
stable
security definer
set search_path to ''
set timezone to 'America/Sao_Paulo'
as $$
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.view') then raise exception 'not_authorized'; end if;
  return query
    select date_trunc('month', x.competence_on)::date, a.kind, a.code, a.name,
           sum(case when x.direction = 'in' then x.amount + x.interest - x.discount else -(x.amount + x.interest - x.discount) end)
    from public.fin_entries x join public.fin_chart_accounts a on a.id = x.account_id
    where x.organization_id = p_org and x.status <> 'cancelled' and a.kind <> 'transfer'
      and x.competence_on between p_from and p_to and (p_branch is null or x.branch_id = p_branch)
    group by 1, 2, 3, 4
    order by 1, 3;
end
$$;

create or replace function public.fin_bank_balances(p_org uuid)
returns table (bank_account_id uuid, balance numeric, pending_lines integer)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.view') then raise exception 'not_authorized'; end if;
  return query
    select k.id,
           k.opening_balance + coalesce((select sum(case when e.direction = 'in' then e.amount + e.interest - e.discount else -(e.amount + e.interest - e.discount) end)
                                         from public.fin_entries e
                                         where e.bank_account_id = k.id and e.status = 'settled' and e.settled_on >= k.opening_on), 0),
           (select count(*)::integer from public.fin_statement_lines l where l.bank_account_id = k.id and l.status = 'pending')
    from public.fin_bank_accounts k where k.organization_id = p_org;
end
$$;

-- Payment receipts: private bucket, path <organization_id>/<entry_id>/<uuid>/<file>. Files are evidence: no update or
-- delete for users; the record is written only by fin_add_receipt after the upload.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fin-receipts', 'fin-receipts', false, 4194304, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists fin_receipts_select on storage.objects;
create policy fin_receipts_select on storage.objects for select to authenticated
using (
  bucket_id = 'fin-receipts'
  and exists (select 1 from public.fin_entries e
              where e.organization_id::text = (storage.foldername(name))[1] and e.id::text = (storage.foldername(name))[2]
                and public.has_permission(e.organization_id, 'financeiro.view'))
);

drop policy if exists fin_receipts_insert on storage.objects;
create policy fin_receipts_insert on storage.objects for insert to authenticated
with check (
  bucket_id = 'fin-receipts'
  and owner_id = (select auth.uid()::text)
  and exists (select 1 from public.fin_entries e
              where e.organization_id::text = (storage.foldername(name))[1] and e.id::text = (storage.foldername(name))[2]
                and e.status <> 'cancelled' and public.has_permission(e.organization_id, 'financeiro.edit'))
);

create table public.fin_entry_receipts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  entry_id uuid not null,
  storage_path text not null unique,
  file_name text not null check (length(file_name) between 1 and 200),
  mime_type text not null check (mime_type in ('application/pdf', 'image/jpeg', 'image/png', 'image/webp')),
  file_size_bytes integer not null check (file_size_bytes > 0 and file_size_bytes <= 4194304),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  uploaded_by uuid,
  created_at timestamptz not null default now(),
  foreign key (organization_id, entry_id) references public.fin_entries (organization_id, id)
);
create index fin_entry_receipts_entry_idx on public.fin_entry_receipts (entry_id);
alter table public.fin_entry_receipts enable row level security;
create policy fin_entry_receipts_select on public.fin_entry_receipts for select to authenticated using (public.has_permission(organization_id, 'financeiro.view'));

create or replace function public.fin_add_receipt(p_entry uuid, p_path text, p_file_name text, p_mime text, p_size integer, p_sha256 text)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare e public.fin_entries%rowtype; v_id uuid;
begin
  select * into e from public.fin_entries where id = p_entry for update;
  if e.id is null or auth.uid() is null or not public.has_permission(e.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if e.status = 'cancelled' then raise exception 'fin_entry_invalid'; end if;
  if p_path is null or p_path not like e.organization_id::text || '/' || e.id::text || '/%'
     or not exists (select 1 from storage.objects o where o.bucket_id = 'fin-receipts' and o.name = p_path) then raise exception 'fin_receipt_invalid'; end if;
  insert into public.fin_entry_receipts (organization_id, entry_id, storage_path, file_name, mime_type, file_size_bytes, sha256, uploaded_by)
  values (e.organization_id, e.id, p_path, p_file_name, p_mime, p_size, p_sha256, auth.uid())
  returning id into v_id;
  perform private.fin_event(e.organization_id, e.id, 'receipt_added', jsonb_build_object('receipt', v_id, 'file', p_file_name), null);
  return v_id;
end
$$;
revoke all on function public.fin_add_receipt(uuid, text, text, text, integer, text) from public, anon;
grant execute on function public.fin_add_receipt(uuid, text, text, text, integer, text) to authenticated;
