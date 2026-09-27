-- F5.5: onboarding of the legacy base (clients and historical contracts of the previous system), map section 16a,
-- ADR-0044.
--
-- Legacy data is read-only history: it shows on the client file and in the search, never in dashboards, goals,
-- rankings, commission, reconciliation, payout or finance (it lives in its own table, legacy_contracts). A client that
-- already exists (same CPF) is linked, never duplicated nor overwritten. Each company has a cutoff date (when it started
-- using Corban): contracts after it are refused, they belong in the pipeline. Import runs in batches: staged rows with
-- their issues (preview), confirmation, and undo of the whole batch.

-- Company settings: cutoff date; opportunities from the legacy base stay off until the owner turns them on.
create table public.organization_legacy_settings (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  cutoff_on date not null,
  opportunities_enabled boolean not null default false,
  updated_by uuid,
  updated_at timestamptz not null default now()
);

create table public.legacy_import_batches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  source_system text not null check (source_system ~ '^[a-z0-9_-]{2,30}$'),
  file_name text not null check (length(btrim(file_name)) between 1 and 200),
  file_sha256 text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  cutoff_on date not null,
  status text not null default 'draft' check (status in ('draft', 'confirmed', 'undone', 'discarded')),
  rows_total integer not null default 0,
  rows_with_issue integer not null default 0,
  clients_created integer not null default 0,
  clients_matched integer not null default 0,
  contracts_created integer not null default 0,
  created_by uuid,
  created_at timestamptz not null default now(),
  confirmed_by uuid,
  confirmed_at timestamptz,
  undone_by uuid,
  undone_at timestamptz,
  undo_reason text check (undo_reason is null or length(btrim(undo_reason)) between 3 and 300),
  unique (organization_id, id)
);
-- The same file is not imported twice while a batch of it is open or confirmed.
create unique index legacy_import_batches_file_once on public.legacy_import_batches (organization_id, file_sha256) where status in ('draft', 'confirmed');

create table public.legacy_import_rows (
  batch_id uuid not null,
  organization_id uuid not null,
  row_number integer not null check (row_number > 0),
  cpf text,
  full_name text,
  phone text,
  bank_name text,
  agreement_name text,
  contract_type text,
  ade text,
  contract_on date,
  paid_on date,
  requested_amount numeric(15,2),
  released_amount numeric(15,2),
  installment_amount numeric(15,2),
  term integer,
  seller_name text,
  status_text text,
  issue text,
  primary key (batch_id, row_number),
  foreign key (organization_id, batch_id) references public.legacy_import_batches (organization_id, id) on delete cascade
);

create table public.legacy_contracts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  batch_id uuid not null,
  client_id uuid not null,
  source_system text not null,
  bank_name text,
  agreement_name text,
  contract_type text,
  ade text,
  contract_on date,
  paid_on date,
  requested_amount numeric(15,2),
  released_amount numeric(15,2),
  installment_amount numeric(15,2),
  term integer,
  seller_name text,
  status_text text,
  created_at timestamptz not null default now(),
  foreign key (organization_id, batch_id) references public.legacy_import_batches (organization_id, id) on delete restrict,
  foreign key (organization_id, client_id) references public.clients (organization_id, id) on delete restrict
);
create index legacy_contracts_client_idx on public.legacy_contracts (organization_id, client_id);
create index legacy_contracts_batch_idx on public.legacy_contracts (batch_id);
create index legacy_contracts_ade_idx on public.legacy_contracts (organization_id, ade) where ade is not null;

-- A client created by a legacy batch remembers it (undo removes it only if nothing else happened to it).
alter table public.clients add column legacy_batch_id uuid;
alter table public.clients add constraint clients_legacy_batch_fk foreign key (organization_id, legacy_batch_id)
  references public.legacy_import_batches (organization_id, id) on delete restrict;
create index clients_legacy_batch_idx on public.clients (legacy_batch_id) where legacy_batch_id is not null;

-- Reading: settings and batches for the owner and managers; legacy contracts for whoever sees the client.
alter table public.organization_legacy_settings enable row level security;
alter table public.legacy_import_batches enable row level security;
alter table public.legacy_import_rows enable row level security;
alter table public.legacy_contracts enable row level security;
create policy organization_legacy_settings_select on public.organization_legacy_settings for select to authenticated
  using (public.is_active_organization_member(organization_id));
create policy legacy_import_batches_select on public.legacy_import_batches for select to authenticated
  using (public.has_active_organization_role(organization_id, array['admin', 'manager']));
create policy legacy_import_rows_select on public.legacy_import_rows for select to authenticated
  using (public.has_active_organization_role(organization_id, array['admin', 'manager']));
create policy legacy_contracts_select on public.legacy_contracts for select to authenticated
  using (public.is_active_organization_member(organization_id)
         and exists (select 1 from public.clients c where c.id = legacy_contracts.client_id and c.organization_id = legacy_contracts.organization_id));
revoke all on public.organization_legacy_settings, public.legacy_import_batches, public.legacy_import_rows, public.legacy_contracts from public, anon, authenticated;
grant select on public.organization_legacy_settings, public.legacy_import_batches, public.legacy_import_rows, public.legacy_contracts to authenticated;

-- The owner sets the cutoff date (and, later, whether the legacy base feeds opportunities).
create or replace function public.set_legacy_settings(p_org uuid, p_cutoff_on date, p_opportunities boolean default false)
returns void
language plpgsql
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or not public.has_active_organization_role(p_org, array['admin']) then raise exception 'not_authorized'; end if;
  if p_cutoff_on is null or p_cutoff_on > current_date + 366 or p_cutoff_on < date '1990-01-01' then raise exception 'invalid_cutoff'; end if;
  insert into public.organization_legacy_settings (organization_id, cutoff_on, opportunities_enabled, updated_by, updated_at)
  values (p_org, p_cutoff_on, coalesce(p_opportunities, false), auth.uid(), now())
  on conflict (organization_id) do update
    set cutoff_on = excluded.cutoff_on, opportunities_enabled = excluded.opportunities_enabled, updated_by = auth.uid(), updated_at = now();
end
$$;
revoke all on function public.set_legacy_settings(uuid, date, boolean) from public, anon;
grant execute on function public.set_legacy_settings(uuid, date, boolean) to authenticated;

-- Stage rows of a file into a draft batch (a new one when p_batch is null; big files come in blocks). Each row is
-- checked now and keeps its issue: nothing is written to clients or contracts until the batch is confirmed.
create or replace function public.stage_legacy_rows(p_org uuid, p_batch uuid, p_source text, p_file_name text, p_file_sha256 text, p_rows jsonb)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  b public.legacy_import_batches%rowtype;
  v_cutoff date;
  r jsonb;
  v_row integer;
  v_cpf text; v_name text; v_phone text; v_bank text; v_agreement text; v_type text; v_ade text; v_seller text; v_status text;
  v_contract_on date; v_paid_on date; v_requested numeric; v_released numeric; v_installment numeric; v_term integer;
  v_issue text;
begin
  if auth.uid() is null or not public.has_active_organization_role(p_org, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  select cutoff_on into v_cutoff from public.organization_legacy_settings where organization_id = p_org;
  if v_cutoff is null then raise exception 'legacy_cutoff_required'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) < 1 or jsonb_array_length(p_rows) > 1000 then raise exception 'invalid_legacy_rows'; end if;

  if p_batch is null then
    if exists (select 1 from public.legacy_import_batches x where x.organization_id = p_org and x.file_sha256 = lower(p_file_sha256) and x.status = 'confirmed') then
      raise exception 'legacy_file_already_imported';
    end if;
    begin
      insert into public.legacy_import_batches (organization_id, source_system, file_name, file_sha256, cutoff_on, created_by)
      values (p_org, lower(btrim(coalesce(p_source, ''))), btrim(coalesce(p_file_name, '')), lower(coalesce(p_file_sha256, '')), v_cutoff, auth.uid())
      returning * into b;
    exception
      when unique_violation then raise exception 'legacy_file_already_imported';
      when check_violation then raise exception 'invalid_legacy_batch';
    end;
  else
    select * into b from public.legacy_import_batches where id = p_batch and organization_id = p_org for update;
    if b.id is null then raise exception 'not_authorized'; end if;
    if b.status <> 'draft' then raise exception 'legacy_batch_not_draft'; end if;
  end if;
  if b.rows_total + jsonb_array_length(p_rows) > 50000 then raise exception 'legacy_batch_too_large'; end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_issue := null;
    v_row := null; v_cpf := null; v_name := null; v_phone := null; v_bank := null; v_agreement := null; v_type := null; v_ade := null;
    v_seller := null; v_status := null; v_contract_on := null; v_paid_on := null; v_requested := null; v_released := null; v_installment := null; v_term := null;
    begin
      v_row := (r->>'row')::integer;
      v_cpf := nullif(regexp_replace(coalesce(r->>'cpf', ''), '\D', '', 'g'), '');
      v_name := nullif(btrim(coalesce(r->>'full_name', '')), '');
      v_phone := nullif(btrim(coalesce(r->>'phone', '')), '');
      v_bank := nullif(btrim(coalesce(r->>'bank_name', '')), '');
      v_agreement := nullif(btrim(coalesce(r->>'agreement_name', '')), '');
      v_type := nullif(btrim(coalesce(r->>'contract_type', '')), '');
      v_ade := nullif(btrim(coalesce(r->>'ade', '')), '');
      v_seller := nullif(btrim(coalesce(r->>'seller_name', '')), '');
      v_status := nullif(btrim(coalesce(r->>'status_text', '')), '');
      v_contract_on := nullif(r->>'contract_on', '')::date;
      v_paid_on := nullif(r->>'paid_on', '')::date;
      v_requested := nullif(r->>'requested_amount', '')::numeric;
      v_released := nullif(r->>'released_amount', '')::numeric;
      v_installment := nullif(r->>'installment_amount', '')::numeric;
      v_term := nullif(r->>'term', '')::integer;
    exception when others then
      v_issue := 'invalid_value';
    end;
    if v_row is null or v_row < 1 then raise exception 'invalid_legacy_rows'; end if;
    -- An 11-digit CPF may have lost its leading zeros in a spreadsheet: pad it back.
    if v_cpf is not null and length(v_cpf) < 11 then v_cpf := lpad(v_cpf, 11, '0'); end if;

    if v_issue is null and (v_cpf is null or not private.is_valid_cpf(v_cpf)) then v_issue := 'invalid_cpf'; end if;
    if v_issue is null and length(coalesce(v_name, '')) < 3
       and not exists (select 1 from public.clients c where c.organization_id = p_org and c.cpf = v_cpf and c.deleted_at is null) then
      v_issue := 'full_name_required';
    end if;
    if v_issue is null and (coalesce(v_requested, 0) < 0 or coalesce(v_released, 0) < 0 or coalesce(v_installment, 0) < 0
                            or v_requested >= 1e12 or v_released >= 1e12 or v_installment >= 1e12
                            or (v_term is not null and (v_term < 1 or v_term > 600))
                            or v_requested <> round(v_requested, 2) or v_released <> round(v_released, 2) or v_installment <> round(v_installment, 2)) then
      v_issue := 'invalid_value';
    end if;
    if v_issue is null and (v_contract_on > current_date or v_paid_on > current_date or v_contract_on < date '1980-01-01') then v_issue := 'invalid_date'; end if;
    if v_issue is null and coalesce(v_contract_on, v_paid_on) >= v_cutoff then v_issue := 'after_cutoff'; end if;
    if v_issue is null and v_ade is not null then
      if exists (select 1 from public.proposals_v2 p where p.organization_id = p_org and private.norm_ade(p.external_proposal_id) = private.norm_ade(v_ade)) then
        v_issue := 'already_in_corban';
      elsif exists (select 1 from public.legacy_contracts x where x.organization_id = p_org and private.norm_ade(x.ade) = private.norm_ade(v_ade)
                      and x.bank_name is not distinct from v_bank) then
        v_issue := 'duplicate_contract';
      elsif exists (select 1 from public.legacy_import_rows x where x.batch_id = b.id and x.issue is null and private.norm_ade(x.ade) = private.norm_ade(v_ade)
                      and x.bank_name is not distinct from v_bank) then
        v_issue := 'duplicate_contract';
      end if;
    end if;

    begin
      insert into public.legacy_import_rows (batch_id, organization_id, row_number, cpf, full_name, phone, bank_name, agreement_name, contract_type, ade,
                                             contract_on, paid_on, requested_amount, released_amount, installment_amount, term, seller_name, status_text, issue)
      values (b.id, p_org, v_row, v_cpf, left(v_name, 160), left(v_phone, 40), left(v_bank, 120), left(v_agreement, 120), left(v_type, 80), left(v_ade, 60),
              case when v_issue = 'invalid_value' then null else v_contract_on end, case when v_issue = 'invalid_value' then null else v_paid_on end,
              case when v_issue = 'invalid_value' then null else v_requested end, case when v_issue = 'invalid_value' then null else v_released end,
              case when v_issue = 'invalid_value' then null else v_installment end, case when v_issue = 'invalid_value' then null else v_term end,
              left(v_seller, 160), left(v_status, 80), v_issue);
    exception when unique_violation then raise exception 'legacy_row_repeated';
    end;
  end loop;

  update public.legacy_import_batches
  set rows_total = (select count(*) from public.legacy_import_rows where batch_id = b.id),
      rows_with_issue = (select count(*) from public.legacy_import_rows where batch_id = b.id and issue is not null)
  where id = b.id;
  return b.id;
end
$$;
revoke all on function public.stage_legacy_rows(uuid, uuid, text, text, text, jsonb) from public, anon;
grant execute on function public.stage_legacy_rows(uuid, uuid, text, text, text, jsonb) to authenticated;

-- Confirm: every row without issue links (or creates) its client and records its historical contract. A client that
-- already exists is never changed. A new client belongs to the seller of the legacy contract when that seller has a
-- login in Corban, otherwise to whoever imports.
create or replace function public.confirm_legacy_batch(p_batch uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  b public.legacy_import_batches%rowtype;
  x public.legacy_import_rows%rowtype;
  v_client uuid;
  v_created boolean;
  v_owner uuid;
  v_new integer := 0; v_matched integer := 0; v_contracts integer := 0;
  v_seen uuid[] := '{}';
begin
  select * into b from public.legacy_import_batches where id = p_batch for update;
  if b.id is null or auth.uid() is null or not public.has_active_organization_role(b.organization_id, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  if b.status <> 'draft' then raise exception 'legacy_batch_not_draft'; end if;
  if not exists (select 1 from public.legacy_import_rows where batch_id = b.id and issue is null) then raise exception 'legacy_batch_empty'; end if;

  for x in select * from public.legacy_import_rows where batch_id = b.id and issue is null order by row_number loop
    select c.id into v_client from public.clients c where c.organization_id = b.organization_id and c.cpf = x.cpf and c.deleted_at is null;
    if v_client is null then
      select s.user_id into v_owner from public.commercial_sellers s
      where s.organization_id = b.organization_id and s.user_id is not null and lower(btrim(s.name)) = lower(btrim(coalesce(x.seller_name, '')))
      order by s.created_at limit 1;
      select u.client_id, u.created into v_client, v_created
      from private.upsert_client_core(b.organization_id, x.cpf, x.full_name, x.phone, null, 'legacy:' || b.source_system, coalesce(v_owner, auth.uid())) u;
      update public.clients set legacy_batch_id = b.id where id = v_client and legacy_batch_id is null;
      v_new := v_new + 1;
      v_seen := v_seen || v_client;
    elsif not v_client = any(v_seen) then
      v_matched := v_matched + 1;
      v_seen := v_seen || v_client;
    end if;
    if x.ade is not null or x.bank_name is not null or x.contract_on is not null then
      insert into public.legacy_contracts (organization_id, batch_id, client_id, source_system, bank_name, agreement_name, contract_type, ade,
                                           contract_on, paid_on, requested_amount, released_amount, installment_amount, term, seller_name, status_text)
      values (b.organization_id, b.id, v_client, b.source_system, x.bank_name, x.agreement_name, x.contract_type, x.ade,
              x.contract_on, x.paid_on, x.requested_amount, x.released_amount, x.installment_amount, x.term, x.seller_name, x.status_text);
      v_contracts := v_contracts + 1;
    end if;
    v_owner := null;
  end loop;

  update public.legacy_import_batches
  set status = 'confirmed', confirmed_by = auth.uid(), confirmed_at = now(),
      clients_created = v_new, clients_matched = v_matched, contracts_created = v_contracts
  where id = b.id;
end
$$;
revoke all on function public.confirm_legacy_batch(uuid) from public, anon;
grant execute on function public.confirm_legacy_batch(uuid) to authenticated;

-- Undo a whole confirmed batch: its contracts go; the clients it created are removed (soft) only when nothing else
-- happened to them (no proposal, lead, registration or other legacy contract); the others stay.
create or replace function public.undo_legacy_batch(p_batch uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare b public.legacy_import_batches%rowtype;
begin
  select * into b from public.legacy_import_batches where id = p_batch for update;
  if b.id is null or auth.uid() is null or not public.has_active_organization_role(b.organization_id, array['admin']) then raise exception 'not_authorized'; end if;
  if b.status <> 'confirmed' then raise exception 'legacy_batch_not_confirmed'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'reason_required'; end if;

  delete from public.legacy_contracts where batch_id = b.id;
  update public.clients c set deleted_at = now(), updated_at = now()
  where c.legacy_batch_id = b.id and c.deleted_at is null
    and not exists (select 1 from public.proposals_v2 p where p.customer_id = c.id)
    and not exists (select 1 from public.leads l where l.customer_id = c.id)
    and not exists (select 1 from public.client_registrations r where r.customer_id = c.id)
    and not exists (select 1 from public.legacy_contracts x where x.client_id = c.id);
  update public.legacy_import_batches set status = 'undone', undone_by = auth.uid(), undone_at = now(), undo_reason = left(btrim(p_reason), 300)
  where id = b.id;
end
$$;
revoke all on function public.undo_legacy_batch(uuid, text) from public, anon;
grant execute on function public.undo_legacy_batch(uuid, text) to authenticated;

-- Throw away a draft (its staged rows go with it).
create or replace function public.discard_legacy_batch(p_batch uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare b public.legacy_import_batches%rowtype;
begin
  select * into b from public.legacy_import_batches where id = p_batch for update;
  if b.id is null or auth.uid() is null or not public.has_active_organization_role(b.organization_id, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  if b.status <> 'draft' then raise exception 'legacy_batch_not_draft'; end if;
  delete from public.legacy_import_rows where batch_id = b.id;
  update public.legacy_import_batches set status = 'discarded' where id = b.id;
end
$$;
revoke all on function public.discard_legacy_batch(uuid) from public, anon;
grant execute on function public.discard_legacy_batch(uuid) to authenticated;
