-- PREPARED, NOT APPLIED. Forward-only; replaces objects created by LIVE migrations, edits none of them.
-- Findings (2026-09-23 wave):
--  1. Attempt history was erased. claim_integration_run clears error_code / error_message when a run is retried or taken over, and
--     nothing else recorded a failed attempt, so the only trace of attempt N-1 vanished on attempt N. Now every failed attempt and every
--     expired lease is appended as an immutable 'diagnostic' artifact (append-only table, idempotent per attempt).
--  2. Dispatch starvation. list_dispatchable_integration_runs returned the oldest eligible runs whatever their adapter; runs the worker
--     cannot execute (2Tech waiting for a real file, Bevicred deferred, local provider in production) stayed eligible forever and could
--     occupy every slot of a bounded cycle. The worker now passes the adapter keys it can actually resolve.
--  3. fail_integration_run raised (and left the run RUNNING until lease expiry) if the message looked like a secret. It now stores a fixed
--     marker instead, so a hostile provider message cannot stall a run.
-- All functions stay SECURITY INVOKER and service_role-only. No SECURITY DEFINER is created.

drop function if exists public.list_dispatchable_integration_runs(integer,timestamptz);
create or replace function public.list_dispatchable_integration_runs(p_limit integer,p_now timestamptz default now(),p_adapter_keys text[] default null)
returns table(run_id uuid,organization_id uuid,binding_id uuid,adapter_key text,capability text,fingerprint text,correlation_id text,status text,attempt_count integer,max_attempts integer,request jsonb,actor_user_id uuid)
language sql stable set search_path='' as $$
 select r.id,r.organization_id,r.binding_id,a.adapter_key,r.capability,r.request_fingerprint,r.correlation_id,r.status,r.attempt_count,r.max_attempts,r.metadata->'request',r.created_by
 from public.integration_runs r
 join public.integration_source_bindings b on b.id=r.binding_id and b.organization_id=r.organization_id and b.enabled
 join public.integration_adapters a on a.id=r.adapter_id and a.status<>'disabled'
 where (p_adapter_keys is null or a.adapter_key=any(p_adapter_keys))
   and (r.status='queued'
    or (r.status='failed' and not r.terminal and r.attempt_count<r.max_attempts and r.next_attempt_at<=p_now)
    or (r.status='running' and r.lease_expires_at<=p_now))
 order by coalesce(r.next_attempt_at,r.lease_expires_at,r.created_at),r.created_at
 limit least(greatest(coalesce(p_limit,10),1),50)
$$;
revoke all on function public.list_dispatchable_integration_runs(integer,timestamptz,text[]) from public,anon,authenticated;
grant execute on function public.list_dispatchable_integration_runs(integer,timestamptz,text[]) to service_role;

create or replace function public.fail_integration_run(p_org uuid,p_run uuid,p_token uuid,p_code text,p_message text,p_retryable boolean,p_backoff_seconds integer,p_now timestamptz default now())
returns text language plpgsql set search_path='' as $$
declare v_run public.integration_runs%rowtype;v_terminal boolean;v_msg text;v_code text;
begin
 select * into v_run from public.integration_runs r where r.id=p_run and r.organization_id=p_org for update;
 if not found then raise exception 'run_not_found'; end if;
 if v_run.status<>'running' or v_run.claim_token is distinct from p_token then return 'lease_lost'; end if;
 v_terminal:=not coalesce(p_retryable,false) or v_run.attempt_count>=v_run.max_attempts;
 v_msg:=case when public.integration_content_has_secret(p_message) then '[redacted by database guard]' else left(p_message,500) end;
 v_code:=case when public.integration_content_has_secret(p_code) then 'redacted_code' else left(p_code,80) end;
 perform set_config('corban.integration_run_rpc','on',true);
 insert into public.integration_run_artifacts(organization_id,run_id,artifact_kind,payload,content_sha256)
 values(p_org,p_run,'diagnostic',jsonb_build_object('attempt',v_run.attempt_count,'outcome',case when v_terminal then 'failed_terminal' else 'retry_scheduled' end,'code',v_code,'message',v_msg,'retryable',coalesce(p_retryable,false),'at',p_now),md5(p_run::text||':fail:'||v_run.attempt_count::text))
 on conflict(run_id,artifact_kind,content_sha256) where content_sha256 is not null do nothing;
 update public.integration_runs set status='failed',terminal=v_terminal,error_code=case when not coalesce(p_retryable,false) then 'terminal:'||v_code else v_code end,error_message=v_msg,
  next_attempt_at=case when v_terminal then null else p_now+make_interval(secs=>greatest(0,least(coalesce(p_backoff_seconds,0),3600))) end where id=p_run;
 perform set_config('corban.integration_run_rpc','off',true);
 return case when v_terminal then 'failed_terminal' else 'retry_scheduled' end;
end $$;

create or replace function public.claim_integration_run(p_org uuid,p_binding uuid,p_capability text,p_fingerprint text,p_actor uuid,p_max_attempts integer,p_lease_seconds integer,p_request jsonb,p_correlation text,p_now timestamptz default now(),p_adapter_key text default null)
returns table(run_id uuid,outcome text,claim_token uuid,attempt_count integer,status text,next_attempt_at timestamptz,external_request_id text,error_code text)
language plpgsql set search_path='' as $$
declare v_adapter uuid;v_adapter_key text;v_run public.integration_runs%rowtype;v_token uuid:=gen_random_uuid();v_id uuid;
begin
 if p_lease_seconds is null or p_lease_seconds not between 5 and 3600 then raise exception 'invalid_lease'; end if;
 if p_max_attempts is null or p_max_attempts not between 1 and 10 then raise exception 'invalid_max_attempts'; end if;
 if p_fingerprint !~ '^[0-9a-f]{64}$' then raise exception 'invalid_fingerprint'; end if;
 if p_actor is null or not exists(select 1 from public.organization_memberships m where m.organization_id=p_org and m.user_id=p_actor and m.status='active' and m.role in ('admin','manager','supervisor')) then raise exception 'actor_not_authorized'; end if;
 select b.adapter_id,a.adapter_key into v_adapter,v_adapter_key from public.integration_source_bindings b join public.integration_adapters a on a.id=b.adapter_id where b.id=p_binding and b.organization_id=p_org and b.enabled;
 if v_adapter is null then raise exception 'binding_not_found'; end if;
 if p_adapter_key is not null and p_adapter_key<>v_adapter_key then raise exception 'adapter_mismatch'; end if;
 perform set_config('corban.integration_run_rpc','on',true);
 insert into public.integration_runs(organization_id,binding_id,adapter_id,capability,status,request_fingerprint,max_attempts,metadata,created_by,correlation_id)
 values(p_org,p_binding,v_adapter,p_capability,'queued',p_fingerprint,p_max_attempts,jsonb_build_object('request',coalesce(p_request,'{}'::jsonb)),p_actor,left(p_correlation,128))
 on conflict(organization_id,binding_id,request_fingerprint) do nothing;
 select * into v_run from public.integration_runs r where r.organization_id=p_org and r.binding_id=p_binding and r.request_fingerprint=p_fingerprint for update;
 v_id:=v_run.id;
 if v_run.status='succeeded' then perform set_config('corban.integration_run_rpc','off',true); return query select v_id,'replayed',null::uuid,v_run.attempt_count,v_run.status,null::timestamptz,v_run.external_request_id,null::text; return; end if;
 if v_run.status='cancelled' then perform set_config('corban.integration_run_rpc','off',true); return query select v_id,'cancelled',null::uuid,v_run.attempt_count,v_run.status,null::timestamptz,null::text,null::text; return; end if;
 if v_run.status='failed' and (v_run.terminal or v_run.attempt_count>=v_run.max_attempts) then perform set_config('corban.integration_run_rpc','off',true); return query select v_id,'failed_terminal',null::uuid,v_run.attempt_count,v_run.status,null::timestamptz,null::text,v_run.error_code; return; end if;
 if v_run.status='failed' and v_run.next_attempt_at is not null and p_now<v_run.next_attempt_at then perform set_config('corban.integration_run_rpc','off',true); return query select v_id,'retry_scheduled',null::uuid,v_run.attempt_count,v_run.status,v_run.next_attempt_at,null::text,v_run.error_code; return; end if;
 if v_run.status='running' and v_run.lease_expires_at>p_now then perform set_config('corban.integration_run_rpc','off',true); return query select v_id,'in_progress',null::uuid,v_run.attempt_count,v_run.status,null::timestamptz,null::text,null::text; return; end if;
 if v_run.status='running' then
  -- the previous worker never reported: keep a trace of that attempt before the row is reused
  insert into public.integration_run_artifacts(organization_id,run_id,artifact_kind,payload,content_sha256)
  values(p_org,v_id,'diagnostic',jsonb_build_object('attempt',v_run.attempt_count,'outcome','lease_expired','at',p_now),md5(v_id::text||':lease:'||v_run.attempt_count::text))
  on conflict do nothing; -- (no conflict target: the OUT column run_id of this function would make one ambiguous)
 end if;
 if v_run.status='running' and v_run.attempt_count>=v_run.max_attempts then
  update public.integration_runs set status='failed',terminal=true,error_code='terminal:lease_expired_attempts_exhausted',error_message='worker lease expired on the last attempt',next_attempt_at=null where id=v_id;
  perform set_config('corban.integration_run_rpc','off',true);
  return query select v_id,'failed_terminal',null::uuid,v_run.attempt_count,'failed'::text,null::timestamptz,null::text,'terminal:lease_expired_attempts_exhausted'; return;
 end if;
 update public.integration_runs set status='running',attempt_count=v_run.attempt_count+1,claim_token=v_token,lease_expires_at=p_now+make_interval(secs=>p_lease_seconds),started_at=p_now,next_attempt_at=null,error_code=null,error_message=null,terminal=false where id=v_id;
 perform set_config('corban.integration_run_rpc','off',true);
 return query select v_id,case when v_run.status='running' then 'takeover' else 'claimed' end,v_token,v_run.attempt_count+1,'running'::text,null::timestamptz,null::text,null::text;
end $$;
