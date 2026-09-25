--
-- Schema private (captured from production via pg_get_functiondef on 2026-09-24; pg_dump ran with --schema=public)
--

CREATE SCHEMA IF NOT EXISTS private;
GRANT USAGE ON SCHEMA private TO authenticated;

CREATE OR REPLACE FUNCTION private.attach_import_batch_adapter(p_batch_id uuid, p_adapter_key text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_user uuid:=(select auth.uid());b record;v_adapter uuid;v_ver text;
begin
 if v_user is null then raise exception 'batch_not_found_or_forbidden'; end if;
 select id,organization_id,adapter_id,received_by,parser_key into b from public.import_batches where id=p_batch_id for update;
 if not found or not exists(select 1 from public.organization_memberships m where m.organization_id=b.organization_id and m.user_id=v_user and m.status='active' and (b.received_by is not distinct from v_user or m.role in ('admin','manager','supervisor'))) then raise exception 'batch_not_found_or_forbidden'; end if;
 select id,contract_version into v_adapter,v_ver from public.integration_adapters where adapter_key=p_adapter_key and status<>'disabled';
 if v_adapter is null then raise exception 'adapter_not_found'; end if;
 if b.parser_key is distinct from p_adapter_key then raise exception 'adapter_parser_mismatch'; end if;
 if b.adapter_id is not null then if b.adapter_id<>v_adapter then raise exception 'batch_adapter_immutable'; end if; return; end if;
 perform set_config('corban.adapter_attach_rpc','on',true);
 update public.import_batches set adapter_id=v_adapter,adapter_contract_version=v_ver where id=b.id and adapter_id is null;
 perform set_config('corban.adapter_attach_rpc','off',true);
end $function$
;

CREATE OR REPLACE FUNCTION private.caller_role_in(p_org uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select m.role from public.organization_memberships m where m.organization_id=p_org and m.user_id=(select auth.uid()) and m.status='active' limit 1
$function$
;

CREATE OR REPLACE FUNCTION private.commercial_route(p_proposal_id uuid)
 RETURNS TABLE(proposal_id uuid, channel_id uuid, producer_entity_id uuid, payer_entity_id uuid, commission_rule_version_id uuid, split_rule_version_id uuid, snapshot jsonb, created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_org uuid;
begin
 select p.organization_id into v_org from public.proposals_v2 p where p.id=p_proposal_id;
 if v_org is null or coalesce(private.caller_role_in(v_org),'') not in ('admin','manager','supervisor') then raise exception 'forbidden'; end if;
 return query select s.proposal_id,s.channel_id,s.producer_entity_id,s.payer_entity_id,s.commission_rule_version_id,s.split_rule_version_id,s.snapshot,s.created_at
  from public.proposal_commercial_snapshots s where s.proposal_id=p_proposal_id and s.organization_id=v_org;
end $function$
;

CREATE OR REPLACE FUNCTION private.import_row_evidence(p_row_id uuid)
 RETURNS TABLE(record_kind text, amount numeric, normalized_payload jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_org uuid;
begin
 select n.organization_id into v_org from public.import_normalized_rows n where n.id=p_row_id;
 if v_org is null or coalesce(private.caller_role_in(v_org),'') not in ('admin','manager','supervisor') then raise exception 'forbidden'; end if;
 return query select n.record_kind,n.amount,n.normalized_payload from public.import_normalized_rows n where n.id=p_row_id and n.organization_id=v_org;
end $function$
;

CREATE OR REPLACE FUNCTION private.lead_write(p_org uuid, p_lead uuid, p_op text, p_args jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_user uuid:=(select auth.uid());v_role text;l public.leads%rowtype;v_id uuid;v_customer uuid;
begin
 v_role:=private.caller_role_in(p_org);
 if v_user is null or v_role is null then raise exception 'lead_forbidden'; end if;
 if p_op='create' then
  insert into public.leads(organization_id,channel,campaign,external_ref,full_name,phone,email,owner_user_id,metadata,created_by)
  values(p_org,p_args->>'channel',nullif(p_args->>'campaign',''),nullif(p_args->>'external_ref',''),p_args->>'full_name',nullif(p_args->>'phone',''),nullif(lower(p_args->>'email'),''),v_user,coalesce(p_args->'metadata','{}'::jsonb),v_user)
  on conflict (organization_id,channel,external_ref) where external_ref is not null do nothing returning id into v_id;
  if v_id is null then select id into v_id from public.leads where organization_id=p_org and channel=p_args->>'channel' and external_ref=nullif(p_args->>'external_ref',''); return v_id; end if;
  insert into public.lead_events(organization_id,lead_id,event_type,to_status,actor_user_id,detail) values(p_org,v_id,'created','new',v_user,jsonb_build_object('channel',p_args->>'channel','campaign',p_args->>'campaign'));
  return v_id;
 end if;
 select * into l from public.leads where id=p_lead and organization_id=p_org for update;
 if not found then raise exception 'lead_forbidden'; end if;
 if p_op='status' then
  if l.status in ('converted') then raise exception 'lead_already_converted'; end if;
  if p_args->>'status' not in ('new','contacted','qualified','lost') then raise exception 'invalid_lead_status'; end if;
  if p_args->>'status'='lost' and nullif(btrim(p_args->>'lost_reason'),'') is null then raise exception 'lost_reason_required'; end if;
  if l.status='lost' and p_args->>'status'<>'lost' and v_role not in ('admin','manager','supervisor') then raise exception 'lead_reactivation_requires_supervisor'; end if;
  update public.leads set status=p_args->>'status',lost_reason=case when p_args->>'status'='lost' then p_args->>'lost_reason' else null end,updated_at=now() where id=l.id;
  insert into public.lead_events(organization_id,lead_id,event_type,from_status,to_status,actor_user_id,detail) values(p_org,l.id,case when l.status='lost' then 'reactivated' else 'status_changed' end,l.status,p_args->>'status',v_user,jsonb_build_object('lost_reason',p_args->>'lost_reason'));
  return l.id;
 end if;
 if p_op='convert' then
  if l.status='converted' then return l.customer_id; end if;
  if l.status='lost' then raise exception 'lost_lead_must_be_reactivated'; end if;
  if p_args->>'cpf' !~ '^[0-9]{11}$' then raise exception 'invalid_cpf_format'; end if;
  insert into public.clients(organization_id,full_name,cpf,phone,email,original_source) values(p_org,l.full_name,p_args->>'cpf',l.phone,l.email,'lead:'||l.channel) returning id into v_customer;
  insert into public.customer_timeline_events(organization_id,customer_id,event_type,source,actor_user_id) values(p_org,v_customer,'customer.created','lead_conversion',v_user);
  update public.leads set status='converted',customer_id=v_customer,converted_at=now(),updated_at=now() where id=l.id;
  insert into public.lead_events(organization_id,lead_id,event_type,from_status,to_status,actor_user_id,detail) values(p_org,l.id,'converted',l.status,'converted',v_user,jsonb_build_object('customer_id',v_customer));
  return v_customer;
 end if;
 raise exception 'invalid_lead_operation';
end $function$
;

CREATE OR REPLACE FUNCTION private.list_import_rows(p_batch_id uuid, p_numbers text[] DEFAULT NULL::text[])
 RETURNS TABLE(id uuid, organization_id uuid, raw_row_id uuid, batch_id uuid, source_id uuid, row_number integer, record_kind text, bank_key text, external_proposal_number text, producer_tax_id text, external_table_code text, external_table_name text, operation_type text, term integer, rate numeric, normalization_version text, commission_upfront numeric, commission_deferred numeric, amount numeric, normalized_payload jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_org uuid;v_role text;v_priv boolean;
begin
 select b.organization_id into v_org from public.import_batches b where b.id=p_batch_id;
 v_role:=case when v_org is null then null else private.caller_role_in(v_org) end;
 if v_role is null then raise exception 'batch_not_found_or_forbidden'; end if;
 v_priv:=v_role in ('admin','manager','supervisor');
 return query
  select n.id,n.organization_id,n.raw_row_id,rr.batch_id,b.source_id,rr.row_number,n.record_kind,n.bank_key,n.external_proposal_number,n.producer_tax_id,n.external_table_code,n.external_table_name,n.operation_type,n.term,n.rate,n.normalization_version,
   case when v_priv then n.commission_upfront end,case when v_priv then n.commission_deferred end,case when v_priv then n.amount end,case when v_priv then n.normalized_payload end
  from public.import_normalized_rows n
  join public.import_raw_rows rr on rr.id=n.raw_row_id and rr.organization_id=n.organization_id
  join public.import_batches b on b.id=rr.batch_id and b.organization_id=rr.organization_id
  where n.organization_id=v_org
    and ((p_numbers is null and rr.batch_id=p_batch_id) or (p_numbers is not null and n.external_proposal_number=any(p_numbers)))
  order by rr.row_number,n.id
  limit 500;
end $function$
;

REVOKE ALL ON FUNCTION private.attach_import_batch_adapter(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.caller_role_in(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.commercial_route(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.import_row_evidence(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.lead_write(uuid, uuid, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.list_import_rows(uuid, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.attach_import_batch_adapter(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION private.caller_role_in(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION private.commercial_route(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION private.import_row_evidence(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION private.lead_write(uuid, uuid, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION private.list_import_rows(uuid, text[]) TO authenticated;
