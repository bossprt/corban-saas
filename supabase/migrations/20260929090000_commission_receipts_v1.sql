-- F5: receipt of commission from the paying sources and contract-by-contract reconciliation (MAPA-OPERACAO §5).
--
-- Flow: finance uploads a report of a paying source (bank, or promoter on third-party routes) of one kind
-- (upfront, deferred or chargeback). The app parses the file with the column layout saved for that source and kind,
-- and import_receipt_report stores a draft with one line per row. Each line is matched to a proposal by ADE within the
-- routes of the paying source and compared, to the cent (owner: zero tolerance), with the commission frozen on the
-- proposal by the F4 engine:
--   upfront     sum of the received amounts of the non-deferred components;
--   deferred    the received amount of that installment (standard, or the last one with the residual);
--   chargeback  must not exceed what was received for the proposal so far.
-- Lines that do not match are linked by hand or ignored with a reason. Confirming the report (financeiro.approve)
-- writes one immutable ledger entry per line; a divergent entry stays open until someone accepts it with a note.
-- The ledger is append-only: corrections are new entries, never edits. F6 pays the team from this ledger.
-- Owner decisions: tolerance zero; alert "paid without receipt" after 30 days.

-- Column layout per paying source and report kind ---------------------------------------------------------------------

create table public.receipt_layouts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  source_kind text not null check (source_kind in ('bank','provider')),
  source_id uuid not null,
  report_kind text not null check (report_kind in ('upfront','deferred','chargeback')),
  mapping jsonb not null,
  updated_by uuid,
  updated_at timestamptz not null default now(),
  unique (organization_id, source_kind, source_id, report_kind),
  constraint receipt_layout_mapping check (
    jsonb_typeof(mapping) = 'object'
    and coalesce(length(mapping->>'ade'), 0) between 1 and 120
    and coalesce(length(mapping->>'amount'), 0) between 1 and 120)
);

-- Reports and their lines ------------------------------------------------------------------------------------------------

create table public.receipt_reports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  source_kind text not null check (source_kind in ('bank','provider')),
  source_id uuid not null,
  report_kind text not null check (report_kind in ('upfront','deferred','chargeback')),
  reference_month date not null check (extract(day from reference_month) = 1),
  file_name text not null check (length(file_name) between 1 and 160),
  file_sha256 text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  declared_total numeric(15,2) check (declared_total >= 0),
  line_count int not null default 0,
  lines_total numeric(15,2) not null default 0,
  status text not null default 'draft' check (status in ('draft','confirmed','discarded')),
  uploaded_by uuid,
  created_at timestamptz not null default now(),
  confirmed_by uuid,
  confirmed_at timestamptz,
  discarded_by uuid,
  discarded_at timestamptz,
  unique (organization_id, id)
);

-- The same file never enters twice (a discarded draft frees it).
create unique index receipt_reports_file_once_idx on public.receipt_reports (organization_id, file_sha256) where status <> 'discarded';
create index receipt_reports_list_idx on public.receipt_reports (organization_id, created_at desc);

create table public.receipt_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  report_id uuid not null,
  row_number int not null check (row_number >= 1),
  ade text not null check (length(ade) between 1 and 60),
  bank_label text check (length(bank_label) <= 120),
  installment_number int check (installment_number >= 1),
  amount numeric(15,2) not null check (amount > 0),
  paid_on date,
  proposal_id uuid,
  matched_by text check (matched_by in ('auto','manual')),
  component_key text check (component_key in ('upfront','deferred')),
  assigned_installment int,
  calc_id uuid,
  expected_amount numeric(15,2),
  status text not null check (status in ('ok','divergent','not_found','ambiguous','duplicate','no_calc','installment_invalid','ignored')),
  note text check (length(note) <= 300),
  unique (report_id, row_number),
  foreign key (organization_id, report_id) references public.receipt_reports (organization_id, id) on delete restrict,
  foreign key (organization_id, proposal_id) references public.proposals_v2 (organization_id, id) on delete restrict
);

create index receipt_lines_report_idx on public.receipt_lines (report_id, row_number);
create index receipt_lines_proposal_idx on public.receipt_lines (proposal_id) where proposal_id is not null;

-- Immutable ledger ------------------------------------------------------------------------------------------------------------

create table public.commission_receipts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  proposal_id uuid not null,
  calc_id uuid,
  report_id uuid not null,
  line_id uuid not null unique references public.receipt_lines(id) on delete restrict,
  entry_kind text not null check (entry_kind in ('receipt','chargeback')),
  component_key text check (component_key in ('upfront','deferred')),
  installment_number int,
  amount numeric(15,2) not null check (amount > 0),
  expected_amount numeric(15,2),
  reconciliation text not null check (reconciliation in ('matched','divergent')),
  received_on date,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  constraint commission_receipt_shape check ((entry_kind = 'receipt') = (component_key is not null)),
  foreign key (organization_id, proposal_id) references public.proposals_v2 (organization_id, id) on delete restrict,
  foreign key (organization_id, report_id) references public.receipt_reports (organization_id, id) on delete restrict
);

-- A proposal receives each component (and each deferred installment) once.
create unique index commission_receipts_once_idx on public.commission_receipts (proposal_id, component_key, coalesce(installment_number, 0)) where entry_kind = 'receipt';
create index commission_receipts_proposal_idx on public.commission_receipts (organization_id, proposal_id);

create table public.commission_receipt_resolutions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  receipt_id uuid not null unique,
  decision text not null check (decision = 'accepted'),
  note text not null check (length(btrim(note)) between 3 and 300),
  decided_by uuid,
  decided_at timestamptz not null default now(),
  foreign key (organization_id, receipt_id) references public.commission_receipts (organization_id, id) on delete restrict
);

-- Guards --------------------------------------------------------------------------------------------------------------------------

create or replace function public.guard_receipt_write()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if current_setting('corban.receipt_rpc', true) is distinct from 'on' then raise exception 'receipt_write_requires_governed_rpc'; end if;
  if tg_op = 'DELETE' then raise exception 'receipt_records_are_not_deletable'; end if;
  if tg_table_name in ('commission_receipts','commission_receipt_resolutions') and tg_op <> 'INSERT' then
    raise exception 'receipt_ledger_is_append_only';
  end if;
  if tg_table_name = 'receipt_lines' and tg_op = 'UPDATE' then
    if exists (select 1 from public.receipt_reports r where r.id = old.report_id and r.status <> 'draft') then raise exception 'receipt_report_is_closed'; end if;
    if new.report_id is distinct from old.report_id or new.row_number is distinct from old.row_number or new.ade is distinct from old.ade
       or new.amount is distinct from old.amount or new.installment_number is distinct from old.installment_number or new.organization_id is distinct from old.organization_id then
      raise exception 'receipt_line_source_is_immutable';
    end if;
  end if;
  if tg_table_name = 'receipt_reports' and tg_op = 'UPDATE' then
    if old.status <> 'draft' then raise exception 'receipt_report_is_closed'; end if;
    if (to_jsonb(new) - array['status','line_count','lines_total','confirmed_by','confirmed_at','discarded_by','discarded_at'])
       is distinct from (to_jsonb(old) - array['status','line_count','lines_total','confirmed_by','confirmed_at','discarded_by','discarded_at']) then
      raise exception 'receipt_report_source_is_immutable';
    end if;
  end if;
  return new;
end
$$;

revoke all on function public.guard_receipt_write() from public, anon, authenticated;
create trigger receipt_layouts_00_guard before insert or update or delete on public.receipt_layouts for each row execute function public.guard_receipt_write();
create trigger receipt_reports_00_guard before insert or update or delete on public.receipt_reports for each row execute function public.guard_receipt_write();
create trigger receipt_lines_00_guard before insert or update or delete on public.receipt_lines for each row execute function public.guard_receipt_write();
create trigger commission_receipts_00_guard before insert or update or delete on public.commission_receipts for each row execute function public.guard_receipt_write();
create trigger commission_receipt_resolutions_00_guard before insert or update or delete on public.commission_receipt_resolutions for each row execute function public.guard_receipt_write();

-- Row level security: finance only --------------------------------------------------------------------------------------------

alter table public.receipt_layouts enable row level security;
alter table public.receipt_reports enable row level security;
alter table public.receipt_lines enable row level security;
alter table public.commission_receipts enable row level security;
alter table public.commission_receipt_resolutions enable row level security;
revoke all on table public.receipt_layouts, public.receipt_reports, public.receipt_lines, public.commission_receipts, public.commission_receipt_resolutions from anon, authenticated;
grant select on public.receipt_layouts, public.receipt_reports, public.receipt_lines, public.commission_receipts, public.commission_receipt_resolutions to authenticated;

create policy receipt_layouts_select on public.receipt_layouts for select to authenticated using (public.has_permission(organization_id, 'financeiro.view'));
create policy receipt_reports_select on public.receipt_reports for select to authenticated using (public.has_permission(organization_id, 'financeiro.view'));
create policy receipt_lines_select on public.receipt_lines for select to authenticated using (public.has_permission(organization_id, 'financeiro.view'));
create policy commission_receipts_select on public.commission_receipts for select to authenticated using (public.has_permission(organization_id, 'financeiro.view'));
create policy commission_receipt_resolutions_select on public.commission_receipt_resolutions for select to authenticated using (public.has_permission(organization_id, 'financeiro.view'));

-- Helpers ------------------------------------------------------------------------------------------------------------------------------

-- ADE as banks print it varies in punctuation and case; compare letters and digits only.
create or replace function private.norm_ade(p text)
returns text
language sql
immutable
set search_path to ''
as $$ select nullif(regexp_replace(upper(coalesce(p, '')), '[^0-9A-Z]', '', 'g'), '') $$;

create index proposals_v2_ade_norm_idx on public.proposals_v2 (organization_id, private.norm_ade(external_proposal_id)) where external_proposal_id is not null;
create index proposal_external_identities_ade_norm_idx on public.proposal_external_identities (organization_id, private.norm_ade(external_proposal_number));

create or replace function private.check_receipt_source(p_org uuid, p_kind text, p_id uuid)
returns void
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if p_kind = 'bank' and exists (select 1 from public.organization_banks where organization_id = p_org and id = p_id) then return; end if;
  if p_kind = 'provider' and exists (select 1 from public.organization_providers where organization_id = p_org and id = p_id) then return; end if;
  raise exception 'receipt_source_not_found';
end
$$;

-- Matches one draft line: proposal (unless linked by hand), component, installment, expected amount and status.
create or replace function private.match_receipt_line(p_line_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  l public.receipt_lines%rowtype;
  rep public.receipt_reports%rowtype;
  v_proposal uuid;
  v_count int;
  v_calc public.proposal_commission_calcs%rowtype;
  v_component text;
  v_inst int;
  v_expected numeric;
  v_status text;
begin
  select * into l from public.receipt_lines where id = p_line_id for update;
  select * into rep from public.receipt_reports where id = l.report_id;
  if l.status = 'ignored' then return; end if;

  -- Proposal: kept when linked by hand, else by ADE within the routes of the paying source.
  if l.matched_by = 'manual' and l.proposal_id is not null then
    v_proposal := l.proposal_id; v_count := 1;
  else
    select count(*), min(p.id::text)::uuid into v_count, v_proposal
    from public.proposals_v2 p
    join public.product_table_versions v on v.id = p.product_table_version_id
    join public.product_tables t on t.id = v.product_table_id
    join public.organization_product_routes r on r.id = t.route_id
    where p.organization_id = l.organization_id
      and (case rep.source_kind when 'bank' then r.org_bank_id = rep.source_id else r.org_provider_id = rep.source_id end)
      and (private.norm_ade(p.external_proposal_id) = private.norm_ade(l.ade)
           or exists (select 1 from public.proposal_external_identities e
                      where e.organization_id = p.organization_id and e.proposal_id = p.id and private.norm_ade(e.external_proposal_number) = private.norm_ade(l.ade)));
  end if;

  if v_count = 0 then
    v_status := 'not_found'; v_proposal := null;
  elsif v_count > 1 then
    v_status := 'ambiguous'; v_proposal := null;
  else
    select * into v_calc from public.proposal_commission_calcs c where c.proposal_id = v_proposal and c.status = 'active';
    if rep.report_kind = 'chargeback' then
      v_component := null;
      select coalesce(sum(case when x.entry_kind = 'receipt' then x.amount else -x.amount end), 0) into v_expected
      from public.commission_receipts x where x.proposal_id = v_proposal;
      -- Chargebacks already on earlier lines of this draft also consume what was received.
      v_expected := v_expected - coalesce((select sum(o.amount) from public.receipt_lines o
                                           where o.report_id = l.report_id and o.row_number < l.row_number and o.proposal_id = v_proposal and o.status in ('ok','divergent')), 0);
      v_status := case when l.amount <= v_expected then 'ok' else 'divergent' end;
    elsif v_calc.id is null then
      v_status := 'no_calc';
    elsif rep.report_kind = 'upfront' then
      v_component := 'upfront';
      select sum(x.amount) into v_expected from public.proposal_commission_lines x where x.calc_id = v_calc.id and x.part = 'upfront' and x.line_kind = 'received';
      if v_expected is null then v_status := 'no_calc'; end if;
    else
      v_component := 'deferred';
      if not exists (select 1 from public.proposal_commission_lines x where x.calc_id = v_calc.id and x.part like 'deferred%') or coalesce(v_calc.installments, 0) < 1 then
        v_status := 'no_calc';
      else
        -- Installment given by the report, or the next one not yet received (ledger or earlier lines of this draft).
        v_inst := coalesce(l.installment_number, (
          select min(n) from generate_series(1, v_calc.installments) n
          where not exists (select 1 from public.commission_receipts x where x.proposal_id = v_proposal and x.entry_kind = 'receipt' and x.component_key = 'deferred' and x.installment_number = n)
            and not exists (select 1 from public.receipt_lines o where o.report_id = l.report_id and o.row_number < l.row_number and o.proposal_id = v_proposal
                            and o.component_key = 'deferred' and o.assigned_installment = n and o.status in ('ok','divergent'))));
        if v_inst is null or v_inst < 1 or v_inst > v_calc.installments then
          v_status := 'installment_invalid';
        else
          select x.amount into v_expected from public.proposal_commission_lines x
          where x.calc_id = v_calc.id and x.line_kind = 'received'
            and x.part = case when v_inst = v_calc.installments then 'deferred_last' else 'deferred_standard' end;
        end if;
      end if;
    end if;

    if v_status is null then
      if exists (select 1 from public.commission_receipts x where x.proposal_id = v_proposal and x.entry_kind = 'receipt'
                 and x.component_key = v_component and coalesce(x.installment_number, 0) = coalesce(v_inst, 0))
         or exists (select 1 from public.receipt_lines o where o.report_id = l.report_id and o.row_number < l.row_number and o.proposal_id = v_proposal
                    and o.component_key = v_component and coalesce(o.assigned_installment, 0) = coalesce(v_inst, 0) and o.status in ('ok','divergent')) then
        v_status := 'duplicate';
      else
        v_status := case when l.amount = v_expected then 'ok' else 'divergent' end;
      end if;
    end if;
  end if;

  update public.receipt_lines
  set proposal_id = v_proposal,
      matched_by = case when v_proposal is null then null when l.matched_by = 'manual' then 'manual' else 'auto' end,
      component_key = v_component, assigned_installment = v_inst, calc_id = v_calc.id,
      expected_amount = v_expected, status = v_status
  where id = l.id;
end
$$;

revoke all on function private.norm_ade(text) from public, anon;
grant execute on function private.norm_ade(text) to authenticated;
revoke all on function private.check_receipt_source(uuid, text, uuid) from public, anon, authenticated;
revoke all on function private.match_receipt_line(uuid) from public, anon, authenticated;

create or replace function private.rematch_receipt_report(p_report uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare r record;
begin
  -- Lines are matched in file order, so "next installment" and duplicates follow the report.
  for r in select id from public.receipt_lines where report_id = p_report order by row_number loop
    perform private.match_receipt_line(r.id);
  end loop;
end
$$;

revoke all on function private.rematch_receipt_report(uuid) from public, anon, authenticated;

-- RPCs ---------------------------------------------------------------------------------------------------------------------------------

create or replace function public.save_receipt_layout(p_org uuid, p_source_kind text, p_source_id uuid, p_report_kind text, p_mapping jsonb)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare v_id uuid;
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  perform private.check_receipt_source(p_org, p_source_kind, p_source_id);
  perform set_config('corban.receipt_rpc', 'on', true);
  insert into public.receipt_layouts (organization_id, source_kind, source_id, report_kind, mapping, updated_by)
  values (p_org, p_source_kind, p_source_id, p_report_kind, jsonb_strip_nulls(p_mapping), auth.uid())
  on conflict (organization_id, source_kind, source_id, report_kind)
  do update set mapping = excluded.mapping, updated_by = auth.uid(), updated_at = now()
  returning id into v_id;
  perform set_config('corban.receipt_rpc', 'off', true);
  return v_id;
end
$$;

-- p_rows: [{row, ade, amount ("1234.56"), installment?, paid_on? ("YYYY-MM-DD"), bank?}] already parsed by the app.
create or replace function public.import_receipt_report(
  p_org uuid, p_source_kind text, p_source_id uuid, p_report_kind text, p_reference_month date,
  p_file_name text, p_file_sha256 text, p_declared_total numeric, p_rows jsonb
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_id uuid;
  x jsonb;
  v_amount numeric;
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  perform private.check_receipt_source(p_org, p_source_kind, p_source_id);
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) < 1 or jsonb_array_length(p_rows) > 20000 then raise exception 'invalid_receipt_rows'; end if;
  if exists (select 1 from public.receipt_reports where organization_id = p_org and file_sha256 = lower(p_file_sha256) and status <> 'discarded') then
    raise exception 'receipt_file_already_imported';
  end if;

  perform set_config('corban.receipt_rpc', 'on', true);
  insert into public.receipt_reports (organization_id, source_kind, source_id, report_kind, reference_month, file_name, file_sha256, declared_total, uploaded_by)
  values (p_org, p_source_kind, p_source_id, p_report_kind, date_trunc('month', p_reference_month)::date, btrim(p_file_name), lower(p_file_sha256), p_declared_total, auth.uid())
  returning id into v_id;

  for x in select * from jsonb_array_elements(p_rows) loop
    -- Amounts arrive as exact decimal strings; anything with more than two decimals is rejected, never rounded.
    if coalesce(x->>'amount', '') !~ '^\d{1,13}(\.\d{1,2})?$' then raise exception 'invalid_receipt_amount'; end if;
    v_amount := (x->>'amount')::numeric;
    if v_amount <= 0 then raise exception 'invalid_receipt_amount'; end if;
    if coalesce(btrim(x->>'ade'), '') = '' then raise exception 'invalid_receipt_ade'; end if;
    if nullif(x->>'installment', '') is not null and (x->>'installment') !~ '^\d{1,4}$' then raise exception 'invalid_receipt_installment'; end if;
    if nullif(x->>'paid_on', '') is not null and (x->>'paid_on') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'invalid_receipt_date'; end if;
    insert into public.receipt_lines (organization_id, report_id, row_number, ade, bank_label, installment_number, amount, paid_on, status)
    values (p_org, v_id, (x->>'row')::int, left(btrim(x->>'ade'), 60), left(nullif(btrim(x->>'bank'), ''), 120),
            nullif(x->>'installment', '')::int, v_amount, nullif(x->>'paid_on', '')::date, 'not_found');
  end loop;

  update public.receipt_reports r
  set line_count = s.n, lines_total = s.total
  from (select count(*) n, coalesce(sum(amount), 0) total from public.receipt_lines where report_id = v_id) s
  where r.id = v_id;

  perform private.rematch_receipt_report(v_id);
  perform set_config('corban.receipt_rpc', 'off', true);
  return v_id;
end
$$;

-- Links a line to a proposal by hand (the proposal must be of the report's organization); null proposal re-matches by ADE.
create or replace function public.link_receipt_line(p_line_id uuid, p_proposal_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare l public.receipt_lines%rowtype;
begin
  select * into l from public.receipt_lines where id = p_line_id;
  if l.id is null or auth.uid() is null or not public.has_permission(l.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if p_proposal_id is not null and not exists (select 1 from public.proposals_v2 where organization_id = l.organization_id and id = p_proposal_id) then raise exception 'proposal_not_found'; end if;
  perform set_config('corban.receipt_rpc', 'on', true);
  update public.receipt_lines
  set proposal_id = p_proposal_id, matched_by = case when p_proposal_id is null then null else 'manual' end, status = 'not_found', note = null
  where id = p_line_id;
  perform private.rematch_receipt_report(l.report_id);
  perform set_config('corban.receipt_rpc', 'off', true);
end
$$;

create or replace function public.ignore_receipt_line(p_line_id uuid, p_note text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare l public.receipt_lines%rowtype;
begin
  select * into l from public.receipt_lines where id = p_line_id;
  if l.id is null or auth.uid() is null or not public.has_permission(l.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if p_note is null or length(btrim(p_note)) < 3 then raise exception 'note_required'; end if;
  perform set_config('corban.receipt_rpc', 'on', true);
  update public.receipt_lines
  set status = 'ignored', proposal_id = null, matched_by = null, component_key = null, assigned_installment = null, calc_id = null, expected_amount = null, note = left(btrim(p_note), 300)
  where id = p_line_id;
  perform private.rematch_receipt_report(l.report_id);
  perform set_config('corban.receipt_rpc', 'off', true);
end
$$;

create or replace function public.rematch_receipt_report(p_report_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare rep public.receipt_reports%rowtype;
begin
  select * into rep from public.receipt_reports where id = p_report_id;
  if rep.id is null or auth.uid() is null or not public.has_permission(rep.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if rep.status <> 'draft' then raise exception 'receipt_report_is_closed'; end if;
  perform set_config('corban.receipt_rpc', 'on', true);
  perform private.rematch_receipt_report(p_report_id);
  perform set_config('corban.receipt_rpc', 'off', true);
end
$$;

create or replace function public.discard_receipt_report(p_report_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare rep public.receipt_reports%rowtype;
begin
  select * into rep from public.receipt_reports where id = p_report_id for update;
  if rep.id is null or auth.uid() is null or not public.has_permission(rep.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if rep.status <> 'draft' then raise exception 'receipt_report_is_closed'; end if;
  perform set_config('corban.receipt_rpc', 'on', true);
  update public.receipt_reports set status = 'discarded', discarded_by = auth.uid(), discarded_at = now() where id = p_report_id;
  perform set_config('corban.receipt_rpc', 'off', true);
end
$$;

-- Confirms a draft: every line resolved, file total checked, one ledger entry per matched line.
create or replace function public.confirm_receipt_report(p_report_id uuid)
returns int
language plpgsql
security definer
set search_path to ''
as $$
declare
  rep public.receipt_reports%rowtype;
  v_count int;
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
  return v_count;
end
$$;

-- Accepts a divergent entry with a reason (the amount stays as received; F6 pays from what was received).
create or replace function public.accept_receipt_divergence(p_receipt_id uuid, p_note text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare x public.commission_receipts%rowtype;
begin
  select * into x from public.commission_receipts where id = p_receipt_id;
  if x.id is null or auth.uid() is null or not public.has_permission(x.organization_id, 'financeiro.approve') then raise exception 'not_authorized'; end if;
  if x.reconciliation <> 'divergent' then raise exception 'receipt_not_divergent'; end if;
  if p_note is null or length(btrim(p_note)) < 3 then raise exception 'note_required'; end if;
  perform set_config('corban.receipt_rpc', 'on', true);
  insert into public.commission_receipt_resolutions (organization_id, receipt_id, decision, note, decided_by)
  values (x.organization_id, x.id, 'accepted', left(btrim(p_note), 300), auth.uid());
  perform set_config('corban.receipt_rpc', 'off', true);
end
$$;

-- Financial alerts for finance users: paid without receipt after p_days, open divergences, missing deferred
-- installments (one month of grace after each due month) and chargebacks of the last p_days.
create or replace function public.finance_alerts(p_org uuid, p_days int default 30)
returns table (kind text, proposal_id uuid, reference text, amount numeric, since timestamptz)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.view') then raise exception 'not_authorized'; end if;
  return query
  with paid as (
    select p.id, p.external_proposal_id, p.customer_snapshot->>'full_name' as client,
           coalesce((select max(e.evidenced_at) from public.proposal_status_evidence e where e.proposal_id = p.id and e.canonical_status = 'paid'), p.updated_at) as paid_at
    from public.proposals_v2 p where p.organization_id = p_org and p.status = 'paid'
  )
  select 'paid_without_receipt'::text, pd.id, coalesce(pd.external_proposal_id, '') || coalesce(' · ' || pd.client, ''), null::numeric, pd.paid_at
  from paid pd
  where pd.paid_at < now() - make_interval(days => p_days)
    and not exists (select 1 from public.commission_receipts x where x.proposal_id = pd.id and x.entry_kind = 'receipt' and x.component_key = 'upfront')
  union all
  select 'divergence_open', x.proposal_id, coalesce(p.external_proposal_id, ''), x.amount - coalesce(x.expected_amount, 0), x.created_at
  from public.commission_receipts x join public.proposals_v2 p on p.id = x.proposal_id
  where x.organization_id = p_org and x.reconciliation = 'divergent'
    and not exists (select 1 from public.commission_receipt_resolutions r where r.receipt_id = x.id)
  union all
  select 'deferred_missing', pd.id, coalesce(pd.external_proposal_id, '') || coalesce(' · ' || pd.client, ''),
         (least(c.installments, floor(extract(epoch from now() - pd.paid_at) / 86400 / 30)::int - 1)
          - (select count(*) from public.commission_receipts x where x.proposal_id = pd.id and x.entry_kind = 'receipt' and x.component_key = 'deferred'))::numeric,
         pd.paid_at
  from paid pd
  join public.proposal_commission_calcs c on c.proposal_id = pd.id and c.status = 'active'
  where exists (select 1 from public.proposal_commission_lines l where l.calc_id = c.id and l.part like 'deferred%')
    and least(c.installments, floor(extract(epoch from now() - pd.paid_at) / 86400 / 30)::int - 1)
        > (select count(*) from public.commission_receipts x where x.proposal_id = pd.id and x.entry_kind = 'receipt' and x.component_key = 'deferred')
  union all
  select 'chargeback', x.proposal_id, coalesce(p.external_proposal_id, ''), x.amount, x.created_at
  from public.commission_receipts x join public.proposals_v2 p on p.id = x.proposal_id
  where x.organization_id = p_org and x.entry_kind = 'chargeback' and x.created_at > now() - make_interval(days => p_days);
end
$$;

revoke all on function public.save_receipt_layout(uuid, text, uuid, text, jsonb) from public, anon;
revoke all on function public.import_receipt_report(uuid, text, uuid, text, date, text, text, numeric, jsonb) from public, anon;
revoke all on function public.link_receipt_line(uuid, uuid) from public, anon;
revoke all on function public.ignore_receipt_line(uuid, text) from public, anon;
revoke all on function public.rematch_receipt_report(uuid) from public, anon;
revoke all on function public.discard_receipt_report(uuid) from public, anon;
revoke all on function public.confirm_receipt_report(uuid) from public, anon;
revoke all on function public.accept_receipt_divergence(uuid, text) from public, anon;
revoke all on function public.finance_alerts(uuid, int) from public, anon;
grant execute on function public.save_receipt_layout(uuid, text, uuid, text, jsonb) to authenticated;
grant execute on function public.import_receipt_report(uuid, text, uuid, text, date, text, text, numeric, jsonb) to authenticated;
grant execute on function public.link_receipt_line(uuid, uuid) to authenticated;
grant execute on function public.ignore_receipt_line(uuid, text) to authenticated;
grant execute on function public.rematch_receipt_report(uuid) to authenticated;
grant execute on function public.discard_receipt_report(uuid) to authenticated;
grant execute on function public.confirm_receipt_report(uuid) to authenticated;
grant execute on function public.accept_receipt_divergence(uuid, text) to authenticated;
grant execute on function public.finance_alerts(uuid, int) to authenticated;
