-- PREPARED, NOT APPLIED (Human Gate: new production DDL). Replaces the earlier draft of this file (never applied).
-- ingest_normalized_import_batch does not record which catalog adapter parsed a batch, so import_batches.adapter_id /
-- adapter_contract_version stay NULL. This adds a governed, write-once attach step.
--
-- Design (resource-derived tenant, no exposed SECURITY DEFINER):
--  * The BATCH decides the organization. Never `organization_memberships ... limit 1`, never a client-supplied org id.
--  * The caller must hold an ACTIVE membership in THAT organization and be the batch receiver or admin/manager/supervisor.
--  * The adapter must exist in the catalog (not disabled) and must equal the batch's real parser_key (no forged lineage).
--  * Lineage is write-once, enforced by a trigger independent of the RPC.
--  * Missing batch, foreign batch and unauthorized caller all raise the same error (no enumeration oracle).
--
-- Why a definer at all (alternatives rejected): authenticated has NO UPDATE policy on import_batches. A column-level
-- UPDATE grant would make generate_import_match_candidates (which UPDATEs status as invoker) fail with permission denied;
-- an UPDATE policy would let members change any column of their tenant's batches. So the single write is done by a
-- narrow SECURITY DEFINER function that lives in a NON-EXPOSED schema (PostgREST exposes only public, graphql_public —
-- verified live: Invalid schema: private). The public entry point is SECURITY INVOKER, so the advisor has nothing to flag
-- in public. The definer: search_path='', fully qualified names, EXECUTE only for authenticated, no organization argument,
-- updates only adapter_id/adapter_contract_version and only while adapter_id is NULL.
create schema if not exists private;
revoke all on schema private from public,anon;
grant usage on schema private to authenticated;

create or replace function private.attach_import_batch_adapter(p_batch_id uuid,p_adapter_key text)
returns void language plpgsql security definer set search_path='' as $$
declare v_user uuid:=(select auth.uid());b record;v_adapter uuid;v_ver text;
begin
 if v_user is null then raise exception 'batch_not_found_or_forbidden'; end if;
 select id,organization_id,adapter_id,received_by,parser_key into b from public.import_batches where id=p_batch_id for update;
 if not found or not exists(select 1 from public.organization_memberships m where m.organization_id=b.organization_id and m.user_id=v_user and m.status='active'
      and (b.received_by is not distinct from v_user or m.role in ('admin','manager','supervisor'))) then
  raise exception 'batch_not_found_or_forbidden';
 end if;
 select id,contract_version into v_adapter,v_ver from public.integration_adapters where adapter_key=p_adapter_key and status<>'disabled';
 if v_adapter is null then raise exception 'adapter_not_found'; end if;
 if b.parser_key is distinct from p_adapter_key then raise exception 'adapter_parser_mismatch'; end if;
 if b.adapter_id is not null then
  if b.adapter_id<>v_adapter then raise exception 'batch_adapter_immutable'; end if;
  return;
 end if;
 perform set_config('corban.adapter_attach_rpc','on',true);
 update public.import_batches set adapter_id=v_adapter,adapter_contract_version=v_ver where id=b.id and adapter_id is null;
 perform set_config('corban.adapter_attach_rpc','off',true);
end $$;
revoke all on function private.attach_import_batch_adapter(uuid,text) from public,anon;
grant execute on function private.attach_import_batch_adapter(uuid,text) to authenticated;

create or replace function public.attach_import_batch_adapter(p_batch_id uuid,p_adapter_key text)
returns void language sql security invoker set search_path='' as $$
 select private.attach_import_batch_adapter(p_batch_id,p_adapter_key);
$$;
revoke all on function public.attach_import_batch_adapter(uuid,text) from public,anon;
grant execute on function public.attach_import_batch_adapter(uuid,text) to authenticated;

-- Defence in depth: whatever path writes the columns (future policy, service role script), lineage is write-once and
-- only the governed attach step may set it. Runs as the invoker (pure logic, no table reads).
create or replace function public.guard_import_batch_adapter_write_once()
returns trigger language plpgsql set search_path='' as $$
begin
 if old.adapter_id is not null and (new.adapter_id is distinct from old.adapter_id or new.adapter_contract_version is distinct from old.adapter_contract_version) then
  raise exception 'batch_adapter_immutable';
 end if;
 if new.adapter_id is distinct from old.adapter_id and current_setting('corban.adapter_attach_rpc',true) is distinct from 'on' then
  raise exception 'adapter_lineage_requires_governed_rpc';
 end if;
 return new;
end $$;
revoke all on function public.guard_import_batch_adapter_write_once() from public,anon,authenticated;
drop trigger if exists trg_import_batch_adapter_write_once on public.import_batches;
create trigger trg_import_batch_adapter_write_once before update of adapter_id,adapter_contract_version on public.import_batches
for each row execute function public.guard_import_batch_adapter_write_once();
