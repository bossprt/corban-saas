-- Mirror of live migration 20260918214759 integration_secret_and_contract_guards_v1 (already applied).
-- Replaces the text-match secret guard with a jsonb top-level key guard.
-- Repository reconciliation only; do not re-apply as new history.
create or replace function public.guard_integration_binding_no_secrets()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare k text;
begin
 for k in select lower(key) from jsonb_object_keys(coalesce(new.settings,'{}'::jsonb)) key loop
   if k in ('password','senha','secret','api_key','apikey','token','access_token','refresh_token','client_secret','authorization') then
     raise exception 'integration binding settings cannot contain credentials or tokens';
   end if;
 end loop;
 return new;
end $$;
revoke all on function public.guard_integration_binding_no_secrets() from public,anon,authenticated;
drop trigger if exists trg_integration_binding_no_secrets on public.integration_source_bindings;
create trigger trg_integration_binding_no_secrets before insert or update on public.integration_source_bindings
for each row execute function public.guard_integration_binding_no_secrets();

create or replace function public.guard_import_batch_adapter_contract()
returns trigger language plpgsql set search_path=public,pg_temp as $$
declare v text;
begin
 if new.adapter_id is null then
   if new.adapter_contract_version is not null then raise exception 'adapter_contract_version requires adapter_id'; end if;
   return new;
 end if;
 select contract_version into v from public.integration_adapters where id=new.adapter_id and status <> 'disabled';
 if v is null then raise exception 'adapter is missing or disabled'; end if;
 if new.adapter_contract_version is null then new.adapter_contract_version:=v;
 elsif new.adapter_contract_version<>v then raise exception 'adapter contract version mismatch'; end if;
 return new;
end $$;
revoke all on function public.guard_import_batch_adapter_contract() from public,anon,authenticated;
drop trigger if exists trg_import_batch_adapter_contract on public.import_batches;
create trigger trg_import_batch_adapter_contract before insert or update of adapter_id,adapter_contract_version on public.import_batches
for each row execute function public.guard_import_batch_adapter_contract();
