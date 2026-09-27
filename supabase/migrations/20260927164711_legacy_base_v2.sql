-- F5.5, adjusted to the real 2tech export (ADR-0044): 72% of its contracts have no ADE and the number comes in two
-- columns (proposal and contract). Each legacy contract now keeps the old system's own code (ContratoId), which is
-- what detects a repeated contract, and a second number; both numbers are checked against the pipeline.

alter table public.legacy_import_rows add column contract_number text, add column legacy_ref text;
alter table public.legacy_contracts add column contract_number text, add column legacy_ref text;
create unique index legacy_contracts_ref_once on public.legacy_contracts (organization_id, source_system, legacy_ref) where legacy_ref is not null;

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
  v_ref text; v_number text;
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
    v_seller := null; v_status := null; v_ref := null; v_number := null; v_contract_on := null; v_paid_on := null; v_requested := null; v_released := null; v_installment := null; v_term := null;
    begin
      v_row := (r->>'row')::integer;
      v_cpf := nullif(regexp_replace(coalesce(r->>'cpf', ''), '\D', '', 'g'), '');
      v_name := nullif(btrim(coalesce(r->>'full_name', '')), '');
      v_phone := nullif(btrim(coalesce(r->>'phone', '')), '');
      v_bank := nullif(btrim(coalesce(r->>'bank_name', '')), '');
      v_agreement := nullif(btrim(coalesce(r->>'agreement_name', '')), '');
      v_type := nullif(btrim(coalesce(r->>'contract_type', '')), '');
      v_ade := nullif(btrim(coalesce(r->>'ade', '')), '');
      v_number := nullif(btrim(coalesce(r->>'contract_number', '')), '');
      v_ref := nullif(btrim(coalesce(r->>'legacy_ref', '')), '');
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
    -- Already in the pipeline: either number of the old system matches a contract of Corban.
    if v_issue is null and exists (select 1 from public.proposals_v2 p where p.organization_id = p_org and p.external_proposal_id is not null
                                    and private.norm_ade(p.external_proposal_id) in (private.norm_ade(v_ade), private.norm_ade(v_number))) then
      v_issue := 'already_in_corban';
    end if;
    -- Repeated: by the old system's own code when the file has it, otherwise by bank + number.
    if v_issue is null and v_ref is not null then
      if exists (select 1 from public.legacy_contracts x where x.organization_id = p_org and x.source_system = b.source_system and x.legacy_ref = v_ref)
         or exists (select 1 from public.legacy_import_rows x where x.batch_id = b.id and x.issue is null and x.legacy_ref = v_ref) then
        v_issue := 'duplicate_contract';
      end if;
    elsif v_issue is null and coalesce(v_ade, v_number) is not null then
      if exists (select 1 from public.legacy_contracts x where x.organization_id = p_org and x.bank_name is not distinct from v_bank
                   and private.norm_ade(coalesce(x.ade, x.contract_number)) = private.norm_ade(coalesce(v_ade, v_number)))
         or exists (select 1 from public.legacy_import_rows x where x.batch_id = b.id and x.issue is null and x.bank_name is not distinct from v_bank
                   and private.norm_ade(coalesce(x.ade, x.contract_number)) = private.norm_ade(coalesce(v_ade, v_number))) then
        v_issue := 'duplicate_contract';
      end if;
    end if;

    begin
      insert into public.legacy_import_rows (batch_id, organization_id, row_number, cpf, full_name, phone, bank_name, agreement_name, contract_type, ade,
                                             contract_on, paid_on, requested_amount, released_amount, installment_amount, term, seller_name, status_text, issue,
                                             contract_number, legacy_ref)
      values (b.id, p_org, v_row, v_cpf, left(v_name, 160), left(v_phone, 40), left(v_bank, 120), left(v_agreement, 120), left(v_type, 80), left(v_ade, 60),
              case when v_issue = 'invalid_value' then null else v_contract_on end, case when v_issue = 'invalid_value' then null else v_paid_on end,
              case when v_issue = 'invalid_value' then null else v_requested end, case when v_issue = 'invalid_value' then null else v_released end,
              case when v_issue = 'invalid_value' then null else v_installment end, case when v_issue = 'invalid_value' then null else v_term end,
              left(v_seller, 160), left(v_status, 80), v_issue, left(v_number, 60), left(v_ref, 60));
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
    if x.ade is not null or x.contract_number is not null or x.legacy_ref is not null or x.bank_name is not null or x.contract_on is not null then
      insert into public.legacy_contracts (organization_id, batch_id, client_id, source_system, bank_name, agreement_name, contract_type, ade,
                                           contract_on, paid_on, requested_amount, released_amount, installment_amount, term, seller_name, status_text,
                                           contract_number, legacy_ref)
      values (b.organization_id, b.id, v_client, b.source_system, x.bank_name, x.agreement_name, x.contract_type, x.ade,
              x.contract_on, x.paid_on, x.requested_amount, x.released_amount, x.installment_amount, x.term, x.seller_name, x.status_text,
              x.contract_number, x.legacy_ref);
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
