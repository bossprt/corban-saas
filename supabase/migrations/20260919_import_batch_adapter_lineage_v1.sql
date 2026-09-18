-- PREPARED, NOT APPLIED (Human Gate: new production DDL).
-- ingest_normalized_import_batch does not record which catalog adapter parsed a batch, so
-- import_batches.adapter_id / adapter_contract_version stay NULL. This adds a governed, write-once attach step.
-- The existing guard trigger trg_import_batch_adapter_contract validates catalog status and contract version.
create or replace function public.attach_import_batch_adapter(p_batch_id uuid,p_adapter_key text)
returns void language plpgsql set search_path=public as $$
declare v_user uuid:=auth.uid();v_org uuid;v_adapter uuid;v_ver text;v_current uuid;v_received_by uuid;
begin
 select organization_id into v_org from public.organization_memberships where user_id=v_user and status='active' limit 1;
 if v_org is null then raise exception 'active_membership_required'; end if;
 select id,contract_version into v_adapter,v_ver from public.integration_adapters where adapter_key=p_adapter_key and status<>'disabled';
 if v_adapter is null then raise exception 'adapter_not_found'; end if;
 select adapter_id,received_by into v_current,v_received_by from public.import_batches where id=p_batch_id and organization_id=v_org;
 if not found then raise exception 'batch_not_found'; end if;
 if v_received_by is distinct from v_user and not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 if v_current is not null then
  if v_current<>v_adapter then raise exception 'batch_adapter_immutable'; end if;
  return;
 end if;
 update public.import_batches set adapter_id=v_adapter,adapter_contract_version=v_ver where id=p_batch_id and organization_id=v_org and adapter_id is null;
end $$;
revoke all on function public.attach_import_batch_adapter(uuid,text) from public,anon;
grant execute on function public.attach_import_batch_adapter(uuid,text) to authenticated;
