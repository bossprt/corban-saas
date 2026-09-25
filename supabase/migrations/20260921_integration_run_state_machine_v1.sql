-- PREPARED, NOT APPLIED (Human Gate: DDL on live tables integration_runs / integration_run_artifacts).
-- Forward-only. Builds on the live integration contract (integration_adapters, integration_source_bindings, integration_runs,
-- integration_run_artifacts and their consistency guards). It adds:
--   * lease / fencing columns, so two workers can never both own a run and a late worker cannot overwrite a newer one;
--   * an explicit, fail-closed state machine enforced by a trigger (direct UPDATE cannot fake a transition or a success);
--   * "succeeded requires deterministic evidence": at least one response_metadata artifact must exist;
--   * append-only artifacts (no UPDATE / DELETE), idempotent by content hash;
--   * secret-like content is rejected in metadata, artifacts and error messages (defence in depth; the app redacts first);
--   * worker-only functions (service_role) for claim / complete / fail / cancel. They are SECURITY INVOKER: service_role
--     bypasses RLS by design and every other role has no EXECUTE, so no new SECURITY DEFINER surface is created;
--   * read access to runs / artifacts narrowed to supervisor+ (raw provider payloads can carry commercial data).
-- Transitions: queued->running, running->running (lease takeover), running->succeeded|failed, failed->running (governed retry),
-- queued|failed->cancelled. succeeded and cancelled are terminal. A terminal failure (terminal=true or attempts exhausted) never retries.

alter table public.integration_runs
 add column if not exists next_attempt_at timestamptz,
 add column if not exists lease_expires_at timestamptz,
 add column if not exists claim_token uuid,
 add column if not exists terminal boolean not null default false,
 add column if not exists correlation_id text,
 add column if not exists updated_at timestamptz not null default now();

alter table public.integration_runs
 add constraint integration_runs_running_has_lease check (status<>'running' or (claim_token is not null and lease_expires_at is not null and started_at is not null)),
 add constraint integration_runs_attempts_le_max check (attempt_count<=max_attempts),
 add constraint integration_runs_error_len check (error_message is null or length(error_message)<=500),
 add constraint integration_runs_correlation_len check (correlation_id is null or length(correlation_id)<=128);

create unique index if not exists integration_run_artifacts_dedupe_uidx on public.integration_run_artifacts(run_id,artifact_kind,content_sha256) where content_sha256 is not null;

-- Secret-like content detector (plain invoker function, no elevated rights).
create or replace function public.integration_content_has_secret(p_value text)
returns boolean language sql immutable set search_path='' as $$
 select coalesce(p_value,'') ~* '"(password|senha|secret|api_?key|token|access_token|refresh_token|client_secret|authorization)"\s*:\s*(?!\s|"\[redacted\]"|null)'
     or coalesce(p_value,'') ~* '(bearer\s+[a-z0-9._~+/=-]{12,}|(authorization|api[_-]?key|password|senha|secret|token)\s*[:=]\s*[^\s"\[]{6,}|://[^/\s:@]+:(?!\[redacted\])[^/\s@]+@)'
$$;
revoke all on function public.integration_content_has_secret(text) from public,anon;
grant execute on function public.integration_content_has_secret(text) to authenticated,service_role;

create or replace function public.guard_integration_run_state()
returns trigger language plpgsql set search_path='' as $$
declare ok boolean;
begin
 if tg_op='DELETE' then raise exception 'integration_run_cannot_be_deleted'; end if;
 if current_setting('corban.integration_run_rpc',true) is distinct from 'on' then raise exception 'integration_run_requires_governed_rpc'; end if;
 if public.integration_content_has_secret(new.metadata::text) or public.integration_content_has_secret(new.error_message) then raise exception 'integration_run_secret_like_content'; end if;
 if tg_op='INSERT' then
  if new.status<>'queued' or new.attempt_count<>0 or new.terminal or new.claim_token is not null then raise exception 'integration_run_must_start_queued'; end if;
  return new;
 end if;
 if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id or new.binding_id is distinct from old.binding_id
    or new.adapter_id is distinct from old.adapter_id or new.capability is distinct from old.capability or new.request_fingerprint is distinct from old.request_fingerprint
    or new.max_attempts is distinct from old.max_attempts or new.created_at is distinct from old.created_at or new.created_by is distinct from old.created_by then
  raise exception 'integration_run_identity_is_immutable';
 end if;
 ok:=(old.status='queued' and new.status in ('running','cancelled'))
  or (old.status='running' and new.status in ('running','succeeded','failed'))
  or (old.status='failed' and new.status in ('running','cancelled') and not old.terminal and old.attempt_count<old.max_attempts) ;
 if not ok then raise exception 'illegal_integration_run_transition: % -> %',old.status,new.status; end if;
 if new.status='running' and new.attempt_count<>old.attempt_count+1 then raise exception 'integration_run_attempt_must_increment'; end if;
 if new.status<>'running' and new.attempt_count<>old.attempt_count then raise exception 'integration_run_attempt_is_derived'; end if;
 if new.status='succeeded' then
  if new.error_code is not null or new.terminal then raise exception 'successful run cannot carry an error'; end if;
  if not exists(select 1 from public.integration_run_artifacts a where a.run_id=new.id and a.organization_id=new.organization_id and a.artifact_kind='response_metadata') then raise exception 'success_requires_response_evidence'; end if;
 end if;
 if new.status='failed' and nullif(btrim(new.error_code),'') is null then raise exception 'failed_run_requires_error_code'; end if;
 if new.status in ('succeeded','failed','cancelled') then new.claim_token:=null; new.lease_expires_at:=null; new.finished_at:=coalesce(new.finished_at,now()); end if;
 if new.status='running' then new.finished_at:=null; end if;
 new.updated_at:=now();
 return new;
end $$;
revoke all on function public.guard_integration_run_state() from public,anon,authenticated;
create trigger trg_integration_run_state before insert or update or delete on public.integration_runs for each row execute function public.guard_integration_run_state();

create or replace function public.guard_integration_artifact_write()
returns trigger language plpgsql set search_path='' as $$
declare r record;
begin
 if tg_op<>'INSERT' then raise exception 'integration_artifact_is_append_only'; end if;
 if current_setting('corban.integration_run_rpc',true) is distinct from 'on' then raise exception 'integration_artifact_requires_governed_rpc'; end if;
 if public.integration_content_has_secret(new.payload::text) then raise exception 'integration_artifact_secret_like_content'; end if;
 select organization_id,status into r from public.integration_runs where id=new.run_id;
 if r.organization_id is null or r.organization_id<>new.organization_id then raise exception 'artifact organization mismatch'; end if;
 if r.status<>'running' then raise exception 'artifact_requires_running_run'; end if;
 if octet_length(new.payload::text)>200000 then raise exception 'artifact_payload_too_large'; end if;
 return new;
end $$;
revoke all on function public.guard_integration_artifact_write() from public,anon,authenticated;
create trigger trg_integration_artifact_write before insert or update or delete on public.integration_run_artifacts for each row execute function public.guard_integration_artifact_write();

-- Narrow reads: raw provider payloads and run metadata are supervisor+.
drop policy if exists integration_runs_select_member on public.integration_runs;
drop policy if exists integration_run_artifacts_select_member on public.integration_run_artifacts;
create policy integration_runs_select_supervisor_plus on public.integration_runs for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy integration_run_artifacts_select_supervisor_plus on public.integration_run_artifacts for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));

-- ===== Worker functions (service_role only) =====
-- Fencing is by claim_token only: a slow worker whose lease expired but was NOT taken over may still commit its (real) result,
-- which avoids a second submission to the provider; once another worker takes over, the old token is dead.
-- p_now is injected by the worker clock (deterministic tests, single time source per worker).
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
 if v_run.status='running' and v_run.attempt_count>=v_run.max_attempts then
  -- crashed worker on the last attempt: never assume success, never exceed the bound.
  update public.integration_runs set status='failed',terminal=true,error_code='terminal:lease_expired_attempts_exhausted',error_message='worker lease expired on the last attempt',next_attempt_at=null where id=v_id;
  perform set_config('corban.integration_run_rpc','off',true);
  return query select v_id,'failed_terminal',null::uuid,v_run.attempt_count,'failed'::text,null::timestamptz,null::text,'terminal:lease_expired_attempts_exhausted'; return;
 end if;
 update public.integration_runs set status='running',attempt_count=v_run.attempt_count+1,claim_token=v_token,lease_expires_at=p_now+make_interval(secs=>p_lease_seconds),started_at=p_now,next_attempt_at=null,error_code=null,error_message=null,terminal=false where id=v_id;
 perform set_config('corban.integration_run_rpc','off',true);
 return query select v_id,case when v_run.status='running' then 'takeover' else 'claimed' end,v_token,v_run.attempt_count+1,'running'::text,null::timestamptz,null::text,null::text;
end $$;

create or replace function public.complete_integration_run(p_org uuid,p_run uuid,p_token uuid,p_external_request_id text,p_artifacts jsonb,p_now timestamptz default now())
returns text language plpgsql set search_path='' as $$
declare v_run public.integration_runs%rowtype;a jsonb;
begin
 select * into v_run from public.integration_runs r where r.id=p_run and r.organization_id=p_org for update;
 if not found then raise exception 'run_not_found'; end if;
 if v_run.status='succeeded' then return case when v_run.external_request_id is not distinct from p_external_request_id then 'duplicate_ignored' else 'conflicting_duplicate' end; end if;
 if v_run.status<>'running' or v_run.claim_token is distinct from p_token then return 'lease_lost'; end if;
 if jsonb_typeof(p_artifacts)<>'array' or jsonb_array_length(p_artifacts)>20 then raise exception 'invalid_artifacts'; end if;
 perform set_config('corban.integration_run_rpc','on',true);
 for a in select value from jsonb_array_elements(p_artifacts) loop
  insert into public.integration_run_artifacts(organization_id,run_id,artifact_kind,payload,content_sha256)
  values(p_org,p_run,a->>'kind',coalesce(a->'payload','{}'::jsonb),nullif(a->>'sha256',''))
  on conflict(run_id,artifact_kind,content_sha256) where content_sha256 is not null do nothing;
 end loop;
 update public.integration_runs set status='succeeded',external_request_id=left(p_external_request_id,200),error_code=null,error_message=null,terminal=false where id=p_run;
 perform set_config('corban.integration_run_rpc','off',true);
 return 'succeeded';
end $$;

create or replace function public.fail_integration_run(p_org uuid,p_run uuid,p_token uuid,p_code text,p_message text,p_retryable boolean,p_backoff_seconds integer,p_now timestamptz default now())
returns text language plpgsql set search_path='' as $$
declare v_run public.integration_runs%rowtype;v_terminal boolean;
begin
 select * into v_run from public.integration_runs r where r.id=p_run and r.organization_id=p_org for update;
 if not found then raise exception 'run_not_found'; end if;
 if v_run.status<>'running' or v_run.claim_token is distinct from p_token then return 'lease_lost'; end if;
 v_terminal:=not coalesce(p_retryable,false) or v_run.attempt_count>=v_run.max_attempts;
 perform set_config('corban.integration_run_rpc','on',true);
 update public.integration_runs set status='failed',terminal=v_terminal,error_code=case when not coalesce(p_retryable,false) then 'terminal:'||left(p_code,80) else left(p_code,80) end,error_message=left(p_message,500),
  next_attempt_at=case when v_terminal then null else p_now+make_interval(secs=>greatest(0,least(coalesce(p_backoff_seconds,0),3600))) end where id=p_run;
 perform set_config('corban.integration_run_rpc','off',true);
 return case when v_terminal then 'failed_terminal' else 'retry_scheduled' end;
end $$;

create or replace function public.cancel_integration_run(p_org uuid,p_run uuid,p_actor uuid)
returns text language plpgsql set search_path='' as $$
declare v_run public.integration_runs%rowtype;
begin
 if p_actor is null or not exists(select 1 from public.organization_memberships m where m.organization_id=p_org and m.user_id=p_actor and m.status='active' and m.role in ('admin','manager')) then raise exception 'actor_not_authorized'; end if;
 select * into v_run from public.integration_runs r where r.id=p_run and r.organization_id=p_org for update;
 if not found then raise exception 'run_not_found'; end if;
 if v_run.status not in ('queued','failed') then raise exception 'illegal_integration_run_transition: % -> cancelled',v_run.status; end if;
 perform set_config('corban.integration_run_rpc','on',true);
 update public.integration_runs set status='cancelled',next_attempt_at=null where id=p_run;
 perform set_config('corban.integration_run_rpc','off',true);
 return 'cancelled';
end $$;

revoke all on function public.claim_integration_run(uuid,uuid,text,text,uuid,integer,integer,jsonb,text,timestamptz,text),public.complete_integration_run(uuid,uuid,uuid,text,jsonb,timestamptz),public.fail_integration_run(uuid,uuid,uuid,text,text,boolean,integer,timestamptz),public.cancel_integration_run(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.claim_integration_run(uuid,uuid,text,text,uuid,integer,integer,jsonb,text,timestamptz,text),public.complete_integration_run(uuid,uuid,uuid,text,jsonb,timestamptz),public.fail_integration_run(uuid,uuid,uuid,text,text,boolean,integer,timestamptz),public.cancel_integration_run(uuid,uuid,uuid) to service_role;
