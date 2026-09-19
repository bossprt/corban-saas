-- Rollback-only contract for 20260921_integration_run_state_machine_v1.sql (NOT LIVE).
-- Execute the migration earlier in the SAME transaction (this file wraps it in EXECUTE via the __MIG__ placeholder when run from tooling).
-- Ends with RAISE EXCEPTION so nothing persists; pass = message starting with 'RESULTS: ALL PASS'.
-- Concurrency note: true parallel sessions cannot exist inside one transaction. The tests prove the serialization primitives
-- (unique (tenant,binding,fingerprint), SELECT ... FOR UPDATE inside the claim, fencing token, lease takeover) by replaying the
-- exact interleavings a race produces; the JS executor tests cover the same interleavings against the in-memory twin.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid();
 uS uuid:=gen_random_uuid(); uA uuid:=gen_random_uuid(); uM uuid:=gen_random_uuid(); uAd uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid(); uR uuid:=gen_random_uuid(); uX uuid:=gen_random_uuid();
 s1 uuid:=gen_random_uuid(); s2 uuid:=gen_random_uuid(); bA uuid:=gen_random_uuid(); bB uuid:=gen_random_uuid(); ad uuid:=gen_random_uuid();
 f1 text:=repeat('a',64); f2 text:=repeat('b',64); f3 text:=repeat('c',64); f4 text:=repeat('d',64); f5 text:=repeat('e',64); f6 text:=repeat('f',64); f7 text:=repeat('1',64); f8 text:=repeat('2',64);
 t0 timestamptz:='2026-09-21 10:00:00+00'; c record; c2 record; r text; k int; fe int; fc int; runid uuid; tok uuid; tok2 uuid; run2 uuid;
 arts text:='[{"kind":"response_metadata","payload":{"status":"accepted"},"sha256":"h1"}]';
begin
 execute $d$__MIG__$d$;
 create temp table t_res(label text, pass boolean) on commit drop;
 create function pg_temp.as_role(p_role text,p_uid uuid) returns void language plpgsql as $f$
 begin
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role',p_role)::text,true);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  execute 'set local role '||p_role;
 end $f$;
 create function pg_temp.run_as(p_role text,p_uid uuid,q text) returns text language plpgsql as $f$
 declare r text;
 begin
  perform pg_temp.as_role(p_role,p_uid);
  begin execute q into r; exception when others then reset role; raise; end;
  reset role; return r;
 end $f$;
 create function pg_temp.err_of(p_role text,p_uid uuid,q text) returns text language plpgsql as $f$
 declare msg text;
 begin
  begin perform pg_temp.as_role(p_role,p_uid); execute q; reset role; msg:=null;
  exception when others then reset role; msg:=sqlerrm; end;
  return msg;
 end $f$;
 create function pg_temp.expect_err(p_role text,p_uid uuid,q text,pat text,label text) returns void language plpgsql as $f$
 declare msg text:=pg_temp.err_of(p_role,p_uid,q);
 begin
  if msg is null then insert into t_res values(label||' [UNEXPECTED SUCCESS]',false);
  elsif msg !~ pat then insert into t_res values(label||' [got: '||msg||']',false);
  else insert into t_res values(label,true); end if;
 end $f$;
 create function pg_temp.check_that(cond boolean,label text) returns void language plpgsql as $f$
 begin insert into t_res values(label,coalesce(cond,false)); end $f$;
 create function pg_temp.claim(p_org uuid,p_bind uuid,p_fp text,p_actor uuid,p_now timestamptz,p_max int default 3,p_lease int default 60,p_req text default '{"proposal":"100"}') returns record language plpgsql as $f$
 declare r record;
 begin
  perform pg_temp.as_role('service_role',null);
  begin select * into r from public.claim_integration_run(p_org,p_bind,'proposal_status',p_fp,p_actor,p_max,p_lease,p_req::jsonb,'corr-1',p_now); exception when others then reset role; raise; end;
  reset role; return r;
 end $f$;
 create function pg_temp.claim_o(p_org uuid,p_bind uuid,p_fp text,p_actor uuid,p_now timestamptz,p_max int default 3,p_lease int default 60) returns text language plpgsql as $f$
 declare r record;
 begin r:=pg_temp.claim(p_org,p_bind,p_fp,p_actor,p_now,p_max,p_lease); return r.outcome; end $f$;
 create function pg_temp.svc(q text) returns text language plpgsql as $f$
 begin return pg_temp.run_as('service_role',null,q); end $f$;
 create function pg_temp.forge(q text) returns text language plpgsql as $f$
 declare msg text;
 begin
  perform set_config('corban.integration_run_rpc','on',true);
  begin execute q; msg:=null; exception when others then msg:=sqlerrm; end;
  perform set_config('corban.integration_run_rpc','off',true);
  return msg;
 end $f$;
 create function pg_temp.forge_check(q text,pat text,label text) returns void language plpgsql as $f$
 declare msg text:=pg_temp.forge(q);
 begin
  if msg is null then insert into t_res values(label||' [UNEXPECTED SUCCESS]',false);
  elsif msg !~ pat then insert into t_res values(label||' [got: '||msg||']',false);
  else insert into t_res values(label,true); end if;
 end $f$;

 insert into auth.users(id) values(uS),(uA),(uM),(uAd),(uB),(uR),(uX);
 insert into public.organizations(id,name,document) values(o1,'IR-A','doc-'||o1),(o2,'IR-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role,status) values(o1,uS,'supervisor','active'),(o1,uA,'agent','active'),(o1,uM,'manager','active'),(o1,uAd,'admin','active'),(o2,uB,'admin','active'),(o1,uR,'admin','revoked'),(o1,uX,'supervisor','active'),(o2,uX,'admin','active');
 insert into public.import_sources(id,organization_id,name,source_kind) values(s1,o1,'src a','manual'),(s2,o2,'src b','manual');
 insert into public.integration_adapters(id,adapter_key,provider_key,transport,name,contract_version,capabilities) values(ad,'local/fake-'||ad,'local','file','fake','1.0.0','["proposal_status","proposal_submit"]');
 insert into public.integration_source_bindings(id,organization_id,source_id,adapter_id) values(bA,o1,s1,ad),(bB,o2,s2,ad);
 select count(*) into fe from public.financial_events; select count(*) into fc from public.financial_reconciliation_cases;

 -- ===== access surface =====
 perform pg_temp.expect_err('authenticated',uS,format($q$select * from public.claim_integration_run(%L,%L,'proposal_status',%L,%L,3,60,'{}'::jsonb,'c')$q$,o1,bA,f1,uS),'permission denied','authenticated (even supervisor) cannot call claim_integration_run');
 perform pg_temp.expect_err('anon',null,format($q$select * from public.claim_integration_run(%L,%L,'proposal_status',%L,%L,3,60,'{}'::jsonb,'c')$q$,o1,bA,f1,uS),'permission denied','anon cannot call claim_integration_run');
 perform pg_temp.expect_err('authenticated',uAd,format($q$select public.complete_integration_run(%L,%L,%L,'x','[]'::jsonb)$q$,o1,gen_random_uuid(),gen_random_uuid()),'permission denied','authenticated cannot call complete_integration_run');
 perform pg_temp.expect_err('authenticated',uAd,format($q$select public.fail_integration_run(%L,%L,%L,'x','y',true,1)$q$,o1,gen_random_uuid(),gen_random_uuid()),'permission denied','authenticated cannot call fail_integration_run');
 perform pg_temp.expect_err('authenticated',uAd,format($q$select public.cancel_integration_run(%L,%L,%L)$q$,o1,gen_random_uuid(),uAd),'permission denied','authenticated cannot call cancel_integration_run');
 perform pg_temp.expect_err('authenticated',uAd,format($q$insert into public.integration_runs(organization_id,binding_id,adapter_id,capability,request_fingerprint) values(%L,%L,%L,'proposal_status',%L)$q$,o1,bA,ad,f7),'permission denied','authenticated cannot insert runs directly');
 perform pg_temp.expect_err('authenticated',uAd,'update public.integration_runs set status=''succeeded''','permission denied','authenticated cannot update runs directly');
 perform pg_temp.expect_err('authenticated',uAd,'delete from public.integration_runs','permission denied','authenticated cannot delete runs');
 perform pg_temp.expect_err('authenticated',uAd,format($q$insert into public.integration_run_artifacts(organization_id,run_id,artifact_kind) values(%L,%L,'diagnostic')$q$,o1,gen_random_uuid()),'permission denied','authenticated cannot write artifacts');

 -- ===== authorization inside claim =====
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'proposal_status',%L,%L,3,60,'{}'::jsonb,'c')$q$,o1,bA,f1,uA),'actor_not_authorized','agent actor cannot start a run');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'proposal_status',%L,%L,3,60,'{}'::jsonb,'c')$q$,o1,bA,f1,uR),'actor_not_authorized','revoked membership cannot start a run');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'proposal_status',%L,%L,3,60,'{}'::jsonb,'c')$q$,o1,bA,f1,uB),'actor_not_authorized','tenant B user cannot start a run in tenant A');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'proposal_status',%L,%L,3,60,'{}'::jsonb,'c')$q$,o1,bA,f1,gen_random_uuid()),'actor_not_authorized','user without membership cannot start a run');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'proposal_status',%L,%L,3,60,'{}'::jsonb,'c')$q$,o2,bA,f1,uB),'binding_not_found','known binding UUID of tenant A with tenant B org is not found');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'proposal_status',%L,%L,3,60,'{}'::jsonb,'c')$q$,o1,bB,f1,uS),'binding_not_found','tenant B binding UUID with tenant A org is not found');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'proposal_status','nothex',%L,3,60,'{}'::jsonb,'c')$q$,o1,bA,uS),'invalid_fingerprint','malformed fingerprint rejected');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'proposal_status',%L,%L,0,60,'{}'::jsonb,'c')$q$,o1,bA,f1,uS),'invalid_max_attempts','max_attempts bounded');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'proposal_status',%L,%L,3,1,'{}'::jsonb,'c')$q$,o1,bA,f1,uS),'invalid_lease','lease bounded');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'not_a_capability',%L,%L,3,60,'{}'::jsonb,'c')$q$,o1,bA,f1,uS),'capability unavailable','capability not declared by the adapter is refused');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'proposal_status',%L,%L,3,60,'{"apiKey":"sk_live_abcdef123456"}'::jsonb,'c')$q$,o1,bA,f1,uS),'secret_like_content','request metadata carrying a secret is rejected by the database');
 perform pg_temp.check_that((select count(*) from public.integration_runs)=0,'every rejected claim left no run behind');

 -- ===== happy path, idempotency, evidence =====
 c:=pg_temp.claim(o1,bA,f1,uS,t0);
 perform pg_temp.check_that(c.outcome='claimed' and c.attempt_count=1 and c.claim_token is not null and c.status='running','supervisor claims a new run (attempt 1)');
 runid:=c.run_id; tok:=c.claim_token;
 c2:=pg_temp.claim(o1,bA,f1,uM,t0+interval '10 seconds');
 perform pg_temp.check_that(c2.outcome='in_progress' and c2.claim_token is null and c2.run_id=runid,'second worker with the same idempotency key gets in_progress and no token');
 perform pg_temp.check_that((select count(*) from public.integration_runs where request_fingerprint=f1)=1,'one run per (tenant, binding, fingerprint)');
 perform pg_temp.check_that((select correlation_id='corr-1' and created_by=uS and adapter_id=ad and lease_expires_at=t0+interval '60 seconds' from public.integration_runs where id=runid),'correlation, creator, adapter and lease recorded');
 perform pg_temp.expect_err('service_role',null,format($q$update public.integration_runs set status='succeeded' where id=%L$q$,runid),'integration_run_requires_governed_rpc','direct UPDATE cannot fake success (even service_role)');
 perform pg_temp.expect_err('service_role',null,format($q$delete from public.integration_runs where id=%L$q$,runid),'integration_run_cannot_be_deleted|governed','runs cannot be deleted (service_role)');
 perform pg_temp.expect_err('service_role',null,format($q$insert into public.integration_runs(organization_id,binding_id,adapter_id,capability,request_fingerprint,status) values(%L,%L,%L,'proposal_status',%L,'succeeded')$q$,o1,bA,ad,f7),'integration_run_requires_governed_rpc','a run cannot be inserted directly as succeeded');
 perform pg_temp.expect_err('service_role',null,format($q$insert into public.integration_run_artifacts(organization_id,run_id,artifact_kind) values(%L,%L,'response_metadata')$q$,o1,runid),'integration_artifact_requires_governed_rpc','artifacts cannot be forged directly');
 perform pg_temp.expect_err('service_role',null,format($q$select public.complete_integration_run(%L,%L,%L,'ext-1','[]'::jsonb)$q$,o1,runid,tok),'success_requires_response_evidence','success without a response_metadata artifact is impossible');
 perform pg_temp.expect_err('service_role',null,format($q$select public.complete_integration_run(%L,%L,%L,'ext-1','[{"kind":"diagnostic","payload":{}}]'::jsonb)$q$,o1,runid,tok),'success_requires_response_evidence','a diagnostic artifact is not response evidence');
 perform pg_temp.check_that((select status='running' from public.integration_runs where id=runid) and (select count(*) from public.integration_run_artifacts where run_id=runid)=0,'refused completion left the run running and wrote no artifact (atomic)');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.complete_integration_run(%L,%L,%L,'ext-1',%L::jsonb)$q$,o1,runid,gen_random_uuid(),arts))='lease_lost','wrong claim token: result discarded (lease_lost)');
 perform pg_temp.expect_err('service_role',null,format($q$select public.complete_integration_run(%L,%L,%L,'ext-1',%L::jsonb)$q$,o2,runid,tok,arts),'run_not_found','run of tenant A is not found under tenant B org');
 perform pg_temp.expect_err('service_role',null,format($q$select public.complete_integration_run(%L,%L,%L,'ext-1','[{"kind":"response_metadata","payload":{"token":"abcdef123456"}}]'::jsonb)$q$,o1,runid,tok),'secret_like_content','artifact payload with a secret is rejected');
 perform pg_temp.expect_err('service_role',null,format($q$select public.complete_integration_run(%L,%L,%L,'ext-1','[{"kind":"response_metadata","payload":{"note":"Authorization: Bearer abcdefghijklmnop"}}]'::jsonb)$q$,o1,runid,tok),'secret_like_content','bearer token inside a value is rejected');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.complete_integration_run(%L,%L,%L,'ext-1',%L::jsonb)$q$,o1,runid,tok,'[{"kind":"response_metadata","payload":{"status":"accepted","token":"[redacted]"},"sha256":"h1"},{"kind":"response_metadata","payload":{"status":"accepted"},"sha256":"h1"}]'))='succeeded','completion with evidence succeeds (redacted values allowed, duplicate artifact hash collapses)');
 perform pg_temp.check_that((select count(*) from public.integration_run_artifacts where run_id=runid)=1,'duplicate artifact (same run, kind, sha256) stored once');
 perform pg_temp.check_that((select status='succeeded' and claim_token is null and lease_expires_at is null and finished_at is not null and external_request_id='ext-1' and error_code is null from public.integration_runs where id=runid),'final state: succeeded, lease cleared, finished_at set');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.complete_integration_run(%L,%L,%L,'ext-1',%L::jsonb)$q$,o1,runid,tok,arts))='duplicate_ignored','duplicate provider result is ignored');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.complete_integration_run(%L,%L,%L,'ext-OTHER',%L::jsonb)$q$,o1,runid,tok,arts))='conflicting_duplicate','conflicting second result is flagged and never overwrites');
 perform pg_temp.check_that((select external_request_id='ext-1' from public.integration_runs where id=runid),'original provider id preserved');
 c2:=pg_temp.claim(o1,bA,f1,uS,t0+interval '1 hour');
 perform pg_temp.check_that(c2.outcome='replayed' and c2.status='succeeded' and c2.attempt_count=1 and c2.external_request_id='ext-1' and c2.claim_token is null,'claim after success replays the stored result, no new attempt, no token');

 -- ===== state machine: forged transitions (guard token opened to prove the state machine itself) =====
 perform pg_temp.forge_check(format($q$update public.integration_runs set status='running',attempt_count=2,claim_token=gen_random_uuid(),lease_expires_at=now(),started_at=now() where id=%L$q$,runid),'illegal_integration_run_transition','completed -> running is impossible');
 perform pg_temp.forge_check(format($q$update public.integration_runs set status='failed',error_code='x' where id=%L$q$,runid),'illegal_integration_run_transition','succeeded -> failed is impossible');
 perform pg_temp.forge_check(format($q$update public.integration_runs set status='queued' where id=%L$q$,runid),'illegal_integration_run_transition','succeeded -> queued is impossible');
 perform pg_temp.forge_check(format($q$update public.integration_runs set status='cancelled' where id=%L$q$,runid),'illegal_integration_run_transition','succeeded -> cancelled is impossible');
 perform pg_temp.forge_check(format($q$update public.integration_runs set external_request_id='forged' where id=%L$q$,runid),'illegal_integration_run_transition','a succeeded run cannot be rewritten in place');
 perform pg_temp.forge_check(format($q$update public.integration_runs set organization_id=%L where id=%L$q$,o2,runid),'integration_run_identity_is_immutable|invalid or disabled integration binding','tenant A run cannot become tenant B');
 perform pg_temp.forge_check(format($q$update public.integration_runs set binding_id=%L where id=%L$q$,bB,runid),'integration_run_identity_is_immutable|invalid or disabled integration binding','binding cannot change');
 perform pg_temp.forge_check(format($q$update public.integration_runs set adapter_id=gen_random_uuid() where id=%L$q$,runid),'integration_run_identity_is_immutable|invalid or disabled integration binding','adapter/provider cannot change after start');
 perform pg_temp.forge_check(format($q$update public.integration_runs set request_fingerprint=%L where id=%L$q$,f2,runid),'integration_run_identity_is_immutable','fingerprint cannot change');
 perform pg_temp.forge_check(format($q$update public.integration_runs set capability='proposal_submit' where id=%L$q$,runid),'integration_run_identity_is_immutable','capability cannot change');
 perform pg_temp.forge_check(format($q$update public.integration_runs set max_attempts=10 where id=%L$q$,runid),'integration_run_identity_is_immutable','max_attempts cannot be inflated');
 perform pg_temp.forge_check(format($q$delete from public.integration_runs where id=%L$q$,runid),'integration_run_cannot_be_deleted','run cannot be deleted even with the guard token');
 perform pg_temp.forge_check(format($q$update public.integration_run_artifacts set payload='{}' where run_id=%L$q$,runid),'append_only','evidence cannot be updated');
 perform pg_temp.forge_check(format($q$delete from public.integration_run_artifacts where run_id=%L$q$,runid),'append_only','evidence cannot be deleted');
 perform pg_temp.forge_check(format($q$insert into public.integration_run_artifacts(organization_id,run_id,artifact_kind,payload) values(%L,%L,'diagnostic','{}')$q$,o1,runid),'artifact_requires_running_run','no evidence can be appended to a finished run');
 perform pg_temp.forge_check(format($q$insert into public.integration_run_artifacts(organization_id,run_id,artifact_kind,payload) values(%L,%L,'diagnostic','{}')$q$,o2,runid),'artifact organization mismatch','artifact tenant must equal run tenant');
 perform pg_temp.expect_err('service_role',null,format($q$select public.cancel_integration_run(%L,%L,%L)$q$,o1,runid,uAd),'illegal_integration_run_transition','cancel of a succeeded run is refused');

 -- ===== failure, backoff, retry governance =====
 c:=pg_temp.claim(o1,bA,f2,uS,t0,3,60); run2:=c.run_id; tok:=c.claim_token;
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.fail_integration_run(%L,%L,%L,'timeout','provider timed out',true,30,%L)$q$,o1,run2,tok,t0+interval '5 seconds'))='retry_scheduled','transient failure schedules a retry');
 perform pg_temp.check_that((select status='failed' and not terminal and next_attempt_at=t0+interval '35 seconds' and error_code='timeout' from public.integration_runs where id=run2),'failed run records backoff and sanitized error');
 c2:=pg_temp.claim(o1,bA,f2,uS,t0+interval '20 seconds');
 perform pg_temp.check_that(c2.outcome='retry_scheduled' and c2.claim_token is null,'retry before backoff is refused (no early re-execution)');
 c2:=pg_temp.claim(o1,bA,f2,uS,t0+interval '36 seconds'); tok2:=c2.claim_token;
 perform pg_temp.check_that(c2.outcome='claimed' and c2.attempt_count=2,'retry after backoff is a governed claim (attempt 2)');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.fail_integration_run(%L,%L,%L,'Bad request','x',false,0,%L)$q$,o1,run2,tok,t0+interval '40 seconds'))='lease_lost','the previous attempt token cannot fail the newer attempt');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.fail_integration_run(%L,%L,%L,'bad_request','permanent',false,0,%L)$q$,o1,run2,tok2,t0+interval '40 seconds'))='failed_terminal','permanent failure is terminal');
 perform pg_temp.check_that((select terminal and error_code='terminal:bad_request' from public.integration_runs where id=run2),'terminal error code recorded');
 c2:=pg_temp.claim(o1,bA,f2,uS,t0+interval '1 day');
 perform pg_temp.check_that(c2.outcome='failed_terminal' and c2.claim_token is null,'permanently failed run never returns to running without a new governed request');
 perform pg_temp.forge_check(format($q$update public.integration_runs set status='running',attempt_count=3,claim_token=gen_random_uuid(),lease_expires_at=now(),started_at=now() where id=%L$q$,run2),'illegal_integration_run_transition','terminal failed -> running is impossible even forged');
 perform pg_temp.expect_err('service_role',null,format($q$select public.cancel_integration_run(%L,%L,%L)$q$,o1,run2,uAd),'illegal_integration_run_transition','terminal failed run cannot be cancelled to hide history');
 perform pg_temp.forge_check(format($q$update public.integration_runs set error_message='Authorization: Bearer abcdefghijklmnop' where id=%L$q$,run2),'secret_like_content|illegal_integration_run_transition','secret-like error message is rejected');

 -- attempts exhausted
 c:=pg_temp.claim(o1,bA,f3,uS,t0,2,60);
 perform pg_temp.svc(format($q$select public.fail_integration_run(%L,%L,%L,'timeout','x',true,10,%L)$q$,o1,c.run_id,c.claim_token,t0));
 c2:=pg_temp.claim(o1,bA,f3,uS,t0+interval '11 seconds',2,60);
 perform pg_temp.check_that(c2.attempt_count=2,'second and last attempt');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.fail_integration_run(%L,%L,%L,'timeout','x',true,10,%L)$q$,o1,c2.run_id,c2.claim_token,t0+interval '12 seconds'))='failed_terminal','exhausting max_attempts makes a retryable error terminal');
 perform pg_temp.check_that(pg_temp.claim_o(o1,bA,f3,uS,t0+interval '1 day',2,60)='failed_terminal','no attempt beyond max_attempts');
 perform pg_temp.check_that((select attempt_count=2 from public.integration_runs where request_fingerprint=f3),'attempt_count never exceeds max_attempts');

 -- ===== worker crash / lease takeover / fencing =====
 c:=pg_temp.claim(o1,bA,f4,uS,t0,3,60); run2:=c.run_id; tok:=c.claim_token;
 perform pg_temp.check_that(pg_temp.claim_o(o1,bA,f4,uS,t0+interval '59 seconds')='in_progress','live lease: nobody else runs it');
 c2:=pg_temp.claim(o1,bA,f4,uM,t0+interval '61 seconds'); tok2:=c2.claim_token;
 perform pg_temp.check_that(c2.outcome='takeover' and c2.attempt_count=2 and tok2<>tok,'expired lease (worker died after claim): another worker takes over, counts an attempt, gets a NEW token');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.complete_integration_run(%L,%L,%L,'zombie',%L::jsonb)$q$,o1,run2,tok,arts))='lease_lost','zombie worker (old token) cannot commit its result');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.fail_integration_run(%L,%L,%L,'x','y',false,0)$q$,o1,run2,tok))='lease_lost','zombie worker cannot fail the run either');
 perform pg_temp.check_that((select status='running' and claim_token=tok2 and external_request_id is null from public.integration_runs where id=run2),'zombie left no trace; run still belongs to the new worker');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.complete_integration_run(%L,%L,%L,'ext-4',%L::jsonb)$q$,o1,run2,tok2,arts))='succeeded','new worker completes');
 -- late commit without takeover (worker died after the provider call, before commit, then came back): the real result is accepted, no re-submission
 c:=pg_temp.claim(o1,bA,f5,uS,t0,3,60);
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.complete_integration_run(%L,%L,%L,'ext-5',%L::jsonb,%L)$q$,o1,c.run_id,c.claim_token,arts,t0+interval '2 hours'))='succeeded','late commit with an untouched token is accepted (avoids a second provider submission)');
 -- crash on the last attempt
 c:=pg_temp.claim(o1,bA,f6,uS,t0,1,60);
 c2:=pg_temp.claim(o1,bA,f6,uS,t0+interval '61 seconds',1,60);
 perform pg_temp.check_that(c2.outcome='failed_terminal' and c2.error_code='terminal:lease_expired_attempts_exhausted','crash on the last attempt: never assumed successful, never re-run beyond the bound');
 perform pg_temp.check_that((select status='failed' and terminal and attempt_count=1 from public.integration_runs where request_fingerprint=f6),'exhausted crash is a terminal failure with history');

 -- ===== membership revoked during flow =====
 c:=pg_temp.claim(o1,bA,f7,uX,t0,3,60);
 update public.organization_memberships set status='revoked' where organization_id=o1 and user_id=uX;
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.complete_integration_run(%L,%L,%L,'ext-7',%L::jsonb)$q$,o1,c.run_id,c.claim_token,arts))='succeeded','in-flight completion is still recorded after revocation (external effect must not be lost)');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'proposal_status',%L,%L,3,60,'{}'::jsonb,'c')$q$,o1,bA,f8,uX),'actor_not_authorized','revoked actor cannot start new work');
 update public.organization_memberships set status='active' where organization_id=o1 and user_id=uX;
 c:=pg_temp.claim(o1,bA,f8,uX,t0,3,60);
 perform pg_temp.svc(format($q$select public.fail_integration_run(%L,%L,%L,'timeout','x',true,5,%L)$q$,o1,c.run_id,c.claim_token,t0));
 update public.organization_memberships set status='revoked' where organization_id=o1 and user_id=uX;
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'proposal_status',%L,%L,3,60,'{}'::jsonb,'c')$q$,o1,bA,f8,uX),'actor_not_authorized','revoked actor cannot retry a failed run');
 perform pg_temp.expect_err('service_role',null,format($q$select public.cancel_integration_run(%L,%L,%L)$q$,o1,c.run_id,uS),'actor_not_authorized','supervisor cannot cancel (manager+)');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.cancel_integration_run(%L,%L,%L)$q$,o1,c.run_id,uM))='cancelled','manager cancels a non-terminal failed run');
 perform pg_temp.check_that(pg_temp.claim_o(o1,bA,f8,uM,t0+interval '1 day')='cancelled','cancelled run is never resumed');
 perform pg_temp.expect_err('service_role',null,format($q$select public.cancel_integration_run(%L,%L,%L)$q$,o1,c.run_id,uR),'actor_not_authorized','revoked admin cannot cancel');

 -- ===== read RBAC (direct table access) =====
 perform pg_temp.check_that(pg_temp.run_as('authenticated',uA,'select count(*)::text from public.integration_runs')='0','agent reads no runs');
 perform pg_temp.check_that(pg_temp.run_as('authenticated',uA,'select count(*)::text from public.integration_run_artifacts')='0','agent reads no artifacts (raw provider payloads)');
 perform pg_temp.check_that(pg_temp.run_as('authenticated',uS,'select count(*)::text from public.integration_runs')::int>=6,'supervisor reads tenant runs');
 perform pg_temp.check_that(pg_temp.run_as('authenticated',uM,'select count(*)::text from public.integration_run_artifacts')::int>=1,'manager reads tenant artifacts');
 perform pg_temp.check_that(pg_temp.run_as('authenticated',uB,'select count(*)::text from public.integration_runs')='0' and pg_temp.run_as('authenticated',uB,'select count(*)::text from public.integration_run_artifacts')='0','tenant B reads nothing of tenant A');
 perform pg_temp.check_that(pg_temp.run_as('authenticated',uR,'select count(*)::text from public.integration_runs')='0','revoked membership reads nothing');
 perform pg_temp.check_that(pg_temp.run_as('authenticated',gen_random_uuid(),'select count(*)::text from public.integration_runs')='0','user without membership reads nothing');
 perform pg_temp.check_that(pg_temp.run_as('authenticated',uAd,format($q$select count(*)::text from public.integration_runs where id=%L$q$,runid))='1','admin reads a run by id in own tenant');
 perform pg_temp.check_that(pg_temp.run_as('authenticated',uB,format($q$select count(*)::text from public.integration_runs where id=%L$q$,runid))='0','known run UUID of another tenant returns nothing');
 perform pg_temp.expect_err('anon',null,'select * from public.integration_runs','permission denied','anon cannot read runs');
 perform pg_temp.expect_err('anon',null,'select * from public.integration_run_artifacts','permission denied','anon cannot read artifacts');

 -- ===== tenant B works independently, same fingerprint =====
 c:=pg_temp.claim(o2,bB,f1,uB,t0);
 perform pg_temp.check_that(c.outcome='claimed' and c.run_id<>runid,'same fingerprint in another tenant is an independent run');
 perform pg_temp.check_that(pg_temp.run_as('authenticated',uB,'select count(*)::text from public.integration_runs')='1','tenant B sees exactly its own run');

 -- ===== nothing here creates financial truth =====
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe and (select count(*) from public.financial_reconciliation_cases)=fc,'successful provider runs created no financial event and no reconciliation case');
 perform pg_temp.check_that(not exists(select 1 from pg_depend d join pg_class cl on cl.oid=d.refobjid where d.objid in ('public.integration_runs'::regclass,'public.integration_run_artifacts'::regclass) and cl.relname like 'financial%'),'no dependency from integration tables to financial tables');

 -- ===== function surface =====
 perform pg_temp.check_that(not exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('claim_integration_run','complete_integration_run','fail_integration_run','cancel_integration_run','integration_content_has_secret','guard_integration_run_state','guard_integration_artifact_write') and p.prosecdef),'no new SECURITY DEFINER function');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('claim_integration_run','complete_integration_run','fail_integration_run','cancel_integration_run') and (has_function_privilege('authenticated',p.oid,'EXECUTE') or has_function_privilege('anon',p.oid,'EXECUTE'))),'worker functions: no authenticated/anon execute');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p,lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a where p.pronamespace='public'::regnamespace and p.proname in ('claim_integration_run','complete_integration_run','fail_integration_run','cancel_integration_run') and a.grantee=0),'worker functions: not executable by PUBLIC');
 perform pg_temp.check_that((select bool_and(has_function_privilege('service_role',p.oid,'EXECUTE')) from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('claim_integration_run','complete_integration_run','fail_integration_run','cancel_integration_run')),'worker functions: service_role can execute');

 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %
%',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED' end,r;
end $test$;
