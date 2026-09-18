-- CORBAN OS V2 — Atomic Import Ingestion V0
-- Pre-authorized by user under autonomous implementation mandate.
create or replace function public.ingest_normalized_import_batch(
 p_source_id uuid,p_original_filename text,p_content_sha256 text,p_mime_type text,
 p_parser_key text,p_parser_version text,p_rows jsonb
) returns uuid language plpgsql security invoker set search_path=public as $$
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
  values(v_org,v_batch,v_row_no,v_item->'rawPayload',encode(digest((v_item->'rawPayload')::text,'sha256'),'hex')) returning id into v_raw;
  insert into public.import_normalized_rows(organization_id,raw_row_id,record_kind,bank_key,external_proposal_number,producer_tax_id,external_table_code,external_table_name,operation_type,term,rate,commission_upfront,commission_deferred,amount,normalized_payload,normalization_version)
  values(v_org,v_raw,v_n->>'recordKind',nullif(v_n->>'bankKey',''),nullif(v_n->>'externalProposalNumber',''),nullif(v_n->>'producerTaxId',''),nullif(v_n->>'externalTableCode',''),nullif(v_n->>'externalTableName',''),nullif(v_n->>'operationType',''),nullif(v_n->>'term','')::int,nullif(v_n->>'rate','')::numeric,nullif(v_n->>'commissionUpfront','')::numeric,nullif(v_n->>'commissionDeferred','')::numeric,nullif(v_n->>'amount','')::numeric,coalesce(v_n->'normalizedPayload','{}'::jsonb),p_parser_version);
 end loop;
 return v_batch;
end $$;
revoke all on function public.ingest_normalized_import_batch(uuid,text,text,text,text,text,jsonb) from public,anon;
grant execute on function public.ingest_normalized_import_batch(uuid,text,text,text,text,text,jsonb) to authenticated;
