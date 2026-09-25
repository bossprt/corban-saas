-- PREPARED, NOT APPLIED. Forward-only; no data is deleted; no SECURITY DEFINER.
-- Finding (CONFIRMED by harness on the LIVE schema): a run created by a member who is later deactivated stays dispatchable forever.
-- list_dispatchable_integration_runs returns it (oldest eligible first), claim_integration_run refuses the actor (actor_not_authorized), the worker
-- logs an error and moves on, and the same run is listed again on the next pass. With as many such runs as the pass size (default 10, cap 25)
-- they fill every slot and starve legitimate work.
-- Fix, two parts:
--   1. the dispatch list only returns runs whose creator is STILL an active admin/manager/supervisor of the run's organization (the exact rule claim enforces),
--      so an orphan can never occupy a slot again;
--   2. sweep_orphaned_integration_runs (service_role only) moves orphans to a governed, sanitized end state: queued / retry-pending runs become
--      cancelled, expired-lease running runs become terminally failed, each with a fixed error code and message (artifacts are only writable for RUNNING runs, so the run row itself carries the explanation). A manager can still create a NEW execution
--      linked to the cancelled/failed parent (existing re-execution rules). Creating runs as a revoked user stays refused by claim.

create or replace function public.list_dispatchable_integration_runs(p_limit integer,p_now timestamptz default now(),p_adapter_keys text[] default null)
returns table(run_id uuid,organization_id uuid,binding_id uuid,adapter_key text,capability text,fingerprint text,correlation_id text,status text,attempt_count integer,max_attempts integer,request jsonb,actor_user_id uuid)
language sql stable set search_path='' as $$
 select r.id,r.organization_id,r.binding_id,a.adapter_key,r.capability,r.request_fingerprint,r.correlation_id,r.status,r.attempt_count,r.max_attempts,r.metadata->'request',r.created_by
 from public.integration_runs r
 join public.integration_source_bindings b on b.id=r.binding_id and b.organization_id=r.organization_id and b.enabled
 join public.integration_adapters a on a.id=r.adapter_id and a.status<>'disabled'
 where (p_adapter_keys is null or a.adapter_key=any(p_adapter_keys))
   and r.created_by is not null
   and exists(select 1 from public.organization_memberships m where m.organization_id=r.organization_id and m.user_id=r.created_by and m.status='active' and m.role in ('admin','manager','supervisor'))
   and (r.status='queued'
    or (r.status='failed' and not r.terminal and r.attempt_count<r.max_attempts and r.next_attempt_at<=p_now)
    or (r.status='running' and r.lease_expires_at<=p_now))
 order by coalesce(r.next_attempt_at,r.lease_expires_at,r.created_at),r.created_at
 limit least(greatest(coalesce(p_limit,10),1),50)
$$;

create or replace function public.sweep_orphaned_integration_runs(p_limit integer default 50,p_now timestamptz default now())
returns integer language plpgsql set search_path='' as $$
declare r public.integration_runs%rowtype; n integer:=0;
begin
 perform set_config('corban.integration_run_rpc','on',true);
 for r in
  select x.* from public.integration_runs x
  where (x.status='queued' or (x.status='failed' and not x.terminal and x.attempt_count<x.max_attempts) or (x.status='running' and x.lease_expires_at<=p_now))
    and (x.created_by is null or not exists(select 1 from public.organization_memberships m where m.organization_id=x.organization_id and m.user_id=x.created_by and m.status='active' and m.role in ('admin','manager','supervisor')))
  order by x.created_at
  limit least(greatest(coalesce(p_limit,50),1),200)
  for update skip locked
 loop
  if r.status='running' then
   update public.integration_runs set status='failed',terminal=true,error_code='terminal:actor_no_longer_authorized',error_message='the member who created this run no longer has access',next_attempt_at=null where id=r.id;
  else
   update public.integration_runs set status='cancelled',error_code='actor_no_longer_authorized',error_message='the member who created this run no longer has access',next_attempt_at=null where id=r.id;
  end if;
  n:=n+1;
 end loop;
 perform set_config('corban.integration_run_rpc','off',true);
 return n;
end $$;

revoke all on function public.sweep_orphaned_integration_runs(integer,timestamptz) from public,anon,authenticated;
grant execute on function public.sweep_orphaned_integration_runs(integer,timestamptz) to service_role;
