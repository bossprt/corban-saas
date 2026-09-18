-- PREPARED, NOT APPLIED (Human Gate: replaces two live production functions; logic unchanged except digest qualification).
-- pgcrypto lives in schema `extensions`, but both functions pin `search_path=public` and call `digest(...)`
-- unqualified. At runtime they fail with:  ERROR 42883: function digest(text, unknown) does not exist
-- (reproduced in a rolled-back transaction). Effect on live: file ingestion (ingest_normalized_import_batch) and the
-- evidence publisher (publish_financial_evidence_event, used by import-driven financial publication) cannot succeed.
-- The live database has 0 users, so neither was ever exercised end to end.
-- Only change: digest( -> extensions.digest(. search_path stays pinned to `public` (not widened).
create or replace function public.ingest_normalized_import_batch(p_source_id uuid, p_original_filename text, p_content_sha256 text, p_mime_type text, p_parser_key text, p_parser_version text, p_rows jsonb)
 returns uuid
 language plpgsql
 set search_path to 'public'
as $function$
declare v_user uuid:=auth.uid();v_org uuid;v_batch uuid;v_item jsonb;v_raw uuid;v_n jsonb;v_row_no int;
begin
 select organization_id into v_org from public.organization_memberships where user_id=v_user and status='active' limit 1;
 if v_org is null then raise exception 'active_membership_required'; end if;
 if not exists(select 1 from public.import_sources where id=p_source_id and organization_id=v_org and is_active) then raise exception 'source_not_found'; end if;
 if p_content_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'invalid_sha256'; end if;
 if jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)=0 then raise exception 'rows_required'; end if;
 select id into v_batch from public.import_batches where organization_id=v_org and content_sha256=p_content_sha256;
 if v_batch is not null then return v_batch; end if;
 insert into public.import_batches(organization_id,source_id,original_filename,content_sha256,mime_type,parser_key,parser_version,status,row_count,received_by,completed_at)
 values(v_org,p_source_id,p_original_filename,p_content_sha256,p_mime_type,p_parser_key,p_parser_version,'ready_for_review',jsonb_array_length(p_rows),v_user,now()) returning id into v_batch;
 for v_item in select value from jsonb_array_elements(p_rows) loop
  v_row_no:=(v_item->>'rowNumber')::int; v_n:=v_item->'normalized';
  if v_row_no<1 or jsonb_typeof(v_item->'rawPayload')<>'object' or jsonb_typeof(v_n)<>'object' then raise exception 'invalid_row_payload'; end if;
  insert into public.import_raw_rows(organization_id,batch_id,row_number,raw_payload,raw_hash)
  values(v_org,v_batch,v_row_no,v_item->'rawPayload',encode(extensions.digest((v_item->'rawPayload')::text,'sha256'),'hex')) returning id into v_raw;
  insert into public.import_normalized_rows(organization_id,raw_row_id,record_kind,bank_key,external_proposal_number,producer_tax_id,external_table_code,external_table_name,operation_type,term,rate,commission_upfront,commission_deferred,amount,normalized_payload,normalization_version)
  values(v_org,v_raw,v_n->>'recordKind',nullif(v_n->>'bankKey',''),nullif(v_n->>'externalProposalNumber',''),nullif(v_n->>'producerTaxId',''),nullif(v_n->>'externalTableCode',''),nullif(v_n->>'externalTableName',''),nullif(v_n->>'operationType',''),nullif(v_n->>'term','')::int,nullif(v_n->>'rate','')::numeric,nullif(v_n->>'commissionUpfront','')::numeric,nullif(v_n->>'commissionDeferred','')::numeric,nullif(v_n->>'amount','')::numeric,coalesce(v_n->'normalizedPayload','{}'::jsonb),p_parser_version);
 end loop;
 return v_batch;
end $function$;

create or replace function public.publish_financial_evidence_event(p_proposal_id uuid, p_event_type text, p_component_type text, p_amount numeric, p_occurred_at timestamp with time zone, p_source_kind text, p_source_reference text, p_import_batch_id uuid default null::uuid, p_import_raw_row_id uuid default null::uuid, p_import_decision_id uuid default null::uuid)
 returns uuid
 language plpgsql
 set search_path to 'public'
as $function$
declare v_user uuid:=auth.uid();v_org uuid;v_event uuid;v_channel uuid;v_producer uuid;v_payer uuid;v_key text;v_semantic text;v_raw_batch uuid;v_decision_batch uuid;
begin
 select organization_id into v_org from public.organization_memberships where user_id=v_user and status='active' limit 1;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 if p_event_type not in ('commission_reported','payment_received','downstream_paid') then raise exception 'unsupported_evidence_event'; end if;
 if p_amount is null or p_amount<0 or p_occurred_at is null then raise exception 'invalid_financial_fact'; end if;
 if p_source_kind not in ('import','bank_report','partner_report','payment_evidence') then raise exception 'confirmed_evidence_source_required'; end if;
 if not exists(select 1 from public.proposals_v2 where id=p_proposal_id and organization_id=v_org) then raise exception 'proposal_not_found'; end if;
 select channel_id,producer_entity_id,payer_entity_id into v_channel,v_producer,v_payer from public.proposal_commercial_snapshots where proposal_id=p_proposal_id and organization_id=v_org;
 if not found then raise exception 'frozen_commercial_snapshot_required'; end if;
 if p_source_kind='import' then
  if p_import_batch_id is null then raise exception 'import_batch_required'; end if;
  select s.financial_semantic into v_semantic from public.import_batches b join public.import_sources s on s.id=b.source_id and s.organization_id=b.organization_id where b.id=p_import_batch_id and b.organization_id=v_org;
  if v_semantic is null then raise exception 'batch_not_found'; end if;
  if p_event_type='commission_reported' and v_semantic<>'commission_statement' then raise exception 'source_does_not_prove_reported_commission'; end if;
  if p_event_type='payment_received' and v_semantic<>'payment_statement' then raise exception 'source_does_not_prove_payment'; end if;
  if p_event_type='downstream_paid' and v_semantic<>'network_payment_statement' then raise exception 'source_does_not_prove_network_payment'; end if;
  if p_import_raw_row_id is not null then select batch_id into v_raw_batch from public.import_raw_rows where id=p_import_raw_row_id and organization_id=v_org; if v_raw_batch is distinct from p_import_batch_id then raise exception 'raw_row_batch_mismatch'; end if; end if;
  if p_import_decision_id is not null then select batch_id into v_decision_batch from public.import_decisions where id=p_import_decision_id and organization_id=v_org; if v_decision_batch is distinct from p_import_batch_id then raise exception 'decision_batch_mismatch'; end if; end if;
 elsif nullif(trim(p_source_reference),'') is null then raise exception 'external_evidence_reference_required'; end if;
 v_key:='evidence:'||p_event_type||':'||p_proposal_id::text||':'||coalesce(p_component_type,'none')||':'||p_source_kind||':'||encode(extensions.digest(concat_ws('|',coalesce(p_source_reference,''),coalesce(p_import_batch_id::text,''),coalesce(p_import_raw_row_id::text,''),coalesce(p_import_decision_id::text,'')),'sha256'),'hex');
 select id into v_event from public.financial_events where organization_id=v_org and idempotency_key=v_key;
 if v_event is null then
  perform set_config('corban.financial_evidence_rpc','on',true);
  insert into public.financial_events(organization_id,proposal_id,channel_id,producer_entity_id,payer_entity_id,event_type,component_type,amount,currency,occurred_at,idempotency_key,source_kind,source_reference,metadata,created_by)
  values(v_org,p_proposal_id,v_channel,v_producer,v_payer,p_event_type,p_component_type,p_amount,'BRL',p_occurred_at,v_key,p_source_kind,p_source_reference,jsonb_build_object('evidence_semantic',v_semantic),v_user) returning id into v_event;
  perform set_config('corban.financial_evidence_rpc','off',true);
 end if;
 insert into public.financial_evidence_links(organization_id,financial_event_id,import_batch_id,import_raw_row_id,import_decision_id,evidence_kind,evidence_reference)
 select v_org,v_event,p_import_batch_id,p_import_raw_row_id,p_import_decision_id,p_source_kind,p_source_reference where not exists(select 1 from public.financial_evidence_links where financial_event_id=v_event and coalesce(import_batch_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_batch_id,'00000000-0000-0000-0000-000000000000') and coalesce(import_raw_row_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_raw_row_id,'00000000-0000-0000-0000-000000000000') and coalesce(import_decision_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_decision_id,'00000000-0000-0000-0000-000000000000') and coalesce(evidence_reference,'')=coalesce(p_source_reference,''));
 return v_event;
end $function$;
