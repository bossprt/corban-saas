-- PREPARED, NOT APPLIED (Human Gate: new production DDL).
-- ingest_normalized_import_batch does not record which catalog adapter parsed a batch, so
-- import_batches.adapter_id / adapter_contract_version stay NULL. This adds a governed, write-once attach step.
--
-- Tenant authority: the BATCH decides the organization (never `organization_memberships ... limit 1` and never a
-- client-supplied organization id). The caller must be an active member of THAT organization, and either the batch
-- receiver or admin/manager/supervisor there.
--
-- Why SECURITY DEFINER: import_batches has no UPDATE policy for authenticated (only select/insert). Granting a broad
-- UPDATE policy would let members rewrite any batch column, so this narrow definer function is the only writer, and
-- only of adapter_id/adapter_contract_version, only once. search_path is pinned to '' and EXECUTE is limited to
-- authenticated. Every failure returns the same error to avoid revealing whether a batch exists in another tenant.
-- The existing trigger trg_import_batch_adapter_contract still validates catalog status and contract version.
create or replace function public.attach_import_batch_adapter(p_batch_id uuid,p_adapter_key text)
returns void language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid();b record;v_adapter uuid;v_ver text;
begin
 if v_user is null then raise exception 'batch_not_found_or_forbidden'; end if;
 select id,organization_id,adapter_id,received_by,parser_key into b from public.import_batches where id=p_batch_id for update;
 if not found or not exists(select 1 from public.organization_memberships m where m.organization_id=b.organization_id and m.user_id=v_user and m.status='active') then
  raise exception 'batch_not_found_or_forbidden';
 end if;
 if b.received_by is distinct from v_user and not exists(select 1 from public.organization_memberships m where m.organization_id=b.organization_id and m.user_id=v_user and m.status='active' and m.role in ('admin','manager','supervisor')) then
  raise exception 'batch_not_found_or_forbidden';
 end if;
 select id,contract_version into v_adapter,v_ver from public.integration_adapters where adapter_key=p_adapter_key and status<>'disabled';
 if v_adapter is null then raise exception 'adapter_not_found'; end if;
 -- The batch must have been parsed by this adapter: prevents forged lineage.
 if b.parser_key is distinct from p_adapter_key then raise exception 'adapter_parser_mismatch'; end if;
 if b.adapter_id is not null then
  if b.adapter_id<>v_adapter then raise exception 'batch_adapter_immutable'; end if;
  return;
 end if;
 update public.import_batches set adapter_id=v_adapter,adapter_contract_version=v_ver where id=b.id and adapter_id is null;
end $$;
revoke all on function public.attach_import_batch_adapter(uuid,text) from public,anon;
grant execute on function public.attach_import_batch_adapter(uuid,text) to authenticated;
