-- Rollback-only contract for 20260923_worker_dispatch_hardening_v1.sql (NOT LIVE). __MIG__ = the migration text, executed first in the same
-- transaction; everything else it depends on is LIVE. Covers: adapter-scoped dispatch (starvation), eligibility ordering, immutable attempt
-- history across retry / takeover / exhausted crash, hostile failure messages, and that the lifecycle guarantees still hold.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid();
 uS uuid:=gen_random_uuid(); uM uuid:=gen_random_uuid(); uAg uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid();
 s1 uuid:=gen_random_uuid(); s2 uuid:=gen_random_uuid(); s3 uuid:=gen_random_uuid(); b1 uuid:=gen_random_uuid(); b2 uuid:=gen_random_uuid(); b3 uuid:=gen_random_uuid(); ad1 uuid:=gen_random_uuid(); ad2 uuid:=gen_random_uuid();
 fa text:=repeat('a',64); fb text:=repeat('b',64); fc_ text:=repeat('c',64); fd text:=repeat('d',64); fe_ text:=repeat('e',64); ff text:=repeat('f',64);
 t0 timestamptz:='2026-09-23 10:00:00+00'; c record; c2 record; r text; k int; fe int; fc int; rid uuid; tok uuid; n int;
 arts text:='[{"kind":"response_metadata","payload":{"status":"paid","commission":999999,"approved":true},"sha256":"h1"}]';
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
 create function pg_temp.u(p_uid uuid,q text) returns text language plpgsql as $f$
 begin return pg_temp.run_as('authenticated',p_uid,q); end $f$;
 create function pg_temp.svc(q text) returns text language plpgsql as $f$
 begin return pg_temp.run_as('service_role',null,q); end $f$;
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
 create function pg_temp.enq(p_org uuid,p_bind uuid,p_fp text,p_actor uuid,p_key text) returns record language plpgsql as $f$
 declare r record;
 begin
  perform pg_temp.as_role('service_role',null);
  begin select * into r from public.enqueue_integration_run(p_org,p_bind,'status',p_fp,p_actor,3,'{"ref":"p1"}'::jsonb,'corr-h',p_key); exception when others then reset role; raise; end;
  reset role; return r;
 end $f$;
 create function pg_temp.claim(p_org uuid,p_bind uuid,p_fp text,p_actor uuid,p_now timestamptz,p_key text,p_lease int default 60,p_max int default 3) returns record language plpgsql as $f$
 declare r record;
 begin
  perform pg_temp.as_role('service_role',null);
  begin select * into r from public.claim_integration_run(p_org,p_bind,'status',p_fp,p_actor,p_max,p_lease,'{"ref":"p1"}'::jsonb,'corr-h',p_now,p_key); exception when others then reset role; raise; end;
  reset role; return r;
 end $f$;
 create function pg_temp.disp(p_now timestamptz,p_keys text[]) returns text language plpgsql as $f$
 declare r text;
 begin
  perform pg_temp.as_role('service_role',null);
  begin select coalesce(string_agg(x.fingerprint,',' order by x.fingerprint),'') into r from public.list_dispatchable_integration_runs(50,p_now,p_keys) x; exception when others then reset role; raise; end;
  reset role; return r;
 end $f$;
 create function pg_temp.hist(p_run uuid) returns text language sql as $f$
  select coalesce(string_agg((a.payload->>'attempt')||':'||(a.payload->>'outcome'),',' order by (a.payload->>'attempt')::int,a.created_at),'') from public.integration_run_artifacts a where a.run_id=p_run and a.artifact_kind='diagnostic'
 $f$;

 insert into auth.users(id) values(uS),(uM),(uAg),(uB);
 insert into public.organizations(id,name,document) values(o1,'DH-A','doc-'||o1),(o2,'DH-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role,status) values(o1,uS,'supervisor','active'),(o1,uM,'manager','active'),(o1,uAg,'agent','active'),(o2,uB,'admin','active');
 insert into public.import_sources(id,organization_id,name,source_kind) values(s1,o1,'a','manual'),(s2,o1,'b','manual'),(s3,o2,'c','manual');
 insert into public.integration_adapters(id,adapter_key,provider_key,transport,name,contract_version,capabilities) values(ad1,'local/dh-a','local','api','a','1.0.0','["status"]'),(ad2,'local/dh-b','local','api','b','1.0.0','["status"]');
 insert into public.integration_source_bindings(id,organization_id,source_id,adapter_id) values(b1,o1,s1,ad1),(b2,o1,s2,ad2),(b3,o2,s3,ad1);
 select count(*) into fe from public.financial_events; select count(*) into fc from public.financial_reconciliation_cases;

 -- ===== adapter-scoped dispatch =====
 perform pg_temp.expect_err('authenticated',uS,'select * from public.list_dispatchable_integration_runs(10,now(),null)','permission denied','authenticated cannot call the new signature');
 perform pg_temp.expect_err('anon',null,'select * from public.list_dispatchable_integration_runs(10,now(),null)','permission denied','anon cannot call the new signature');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='list_dispatchable_integration_runs' and pg_get_function_identity_arguments(p.oid) not like '%p_adapter_keys%'),'the old 2-argument overload no longer exists');
 c:=pg_temp.enq(o1,b1,fa,uS,'local/dh-a'); rid:=c.run_id;
 perform pg_temp.enq(o1,b2,fb,uS,'local/dh-b');
 perform pg_temp.enq(o2,b3,fc_,uB,'local/dh-a');
 perform pg_temp.check_that(pg_temp.disp(t0,null)=fa||','||fb||','||fc_,'no filter: every eligible run of every tenant (service_role sees all)');
 perform pg_temp.check_that(pg_temp.disp(t0,array['local/dh-a'])=fa||','||fc_,'only adapters the worker can run are returned');
 perform pg_temp.check_that(pg_temp.disp(t0,array['local/dh-b'])=fb,'a different worker capability set gets a different slice');
 perform pg_temp.check_that(pg_temp.disp(t0,array[]::text[])='' and pg_temp.disp(t0,array['nope/x'])='','no runnable adapter = nothing dispatched');
 perform pg_temp.check_that((select count(*) from public.list_dispatchable_integration_runs(50,t0,array['local/dh-a']) x where x.adapter_key<>'local/dh-a')=0,'rows never carry an adapter outside the filter');
 perform pg_temp.check_that((select bool_and(x.organization_id=(select ir.organization_id from public.integration_runs ir where ir.id=x.run_id)) from public.list_dispatchable_integration_runs(50,t0,null) x),'dispatch rows carry the run''s own tenant');

 -- ===== ordering by the moment the run became eligible =====
 c:=pg_temp.enq(o1,b2,repeat('7',64),uS,'local/dh-b'); c2:=pg_temp.claim(o1,b2,repeat('7',64),uS,t0,'local/dh-b');
 perform pg_temp.svc(format($q$select public.fail_integration_run(%L,%L,%L,'timeout','x',true,9,%L)$q$,o1,c.run_id,c2.claim_token,t0));
 c:=pg_temp.enq(o1,b2,repeat('8',64),uS,'local/dh-b'); c2:=pg_temp.claim(o1,b2,repeat('8',64),uS,t0,'local/dh-b');
 perform pg_temp.svc(format($q$select public.fail_integration_run(%L,%L,%L,'timeout','x',true,3,%L)$q$,o1,c.run_id,c2.claim_token,t0));
 perform pg_temp.check_that((select array_agg(x.fingerprint) from public.list_dispatchable_integration_runs(50,t0+interval '20 seconds',array['local/dh-b']) x)=array[fb,repeat('8',64),repeat('7',64)],'a run eligible since creation first, then retries in the order they became due');
 perform pg_temp.check_that((select array_agg(x.fingerprint) from public.list_dispatchable_integration_runs(50,t0+interval '5 seconds',array['local/dh-b']) x)=array[fb,repeat('8',64)],'a retry that is not yet due is not listed');

 -- ===== attempt history survives retry / takeover / exhausted crash =====
 c:=pg_temp.claim(o1,b1,fa,uS,t0,'local/dh-a'); tok:=c.claim_token;
 perform pg_temp.check_that(pg_temp.hist(rid)='','a first claim writes no diagnostic (nothing failed yet)');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.fail_integration_run(%L,%L,%L,'timeout','provider timed out',true,30,%L)$q$,o1,rid,tok,t0+interval '5 seconds'))='retry_scheduled','attempt 1 fails (retryable)');
 perform pg_temp.check_that(pg_temp.hist(rid)='1:retry_scheduled','failure recorded as an immutable diagnostic artifact');
 c2:=pg_temp.claim(o1,b1,fa,uS,t0+interval '40 seconds','local/dh-a');
 perform pg_temp.check_that(c2.outcome='claimed' and c2.attempt_count=2 and (select error_code is null from public.integration_runs where id=rid),'retry starts attempt 2 and clears the live error columns');
 perform pg_temp.check_that(pg_temp.hist(rid)='1:retry_scheduled','...but attempt 1 is still on record');
 perform pg_temp.check_that((select payload->>'code'='timeout' and payload->>'message'='provider timed out' and (payload->>'retryable')::boolean from public.integration_run_artifacts where run_id=rid and artifact_kind='diagnostic'),'the diagnostic keeps code, message and retryability');
 -- crash on attempt 2: lease expires, another worker takes over
 c:=pg_temp.claim(o1,b1,fa,uM,t0+interval '200 seconds','local/dh-a');
 perform pg_temp.check_that(c.outcome='takeover' and c.attempt_count=3,'takeover after an expired lease');
 perform pg_temp.check_that(pg_temp.hist(rid)='1:retry_scheduled,2:lease_expired','the dead attempt is recorded as lease_expired');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.fail_integration_run(%L,%L,%L,'timeout','again',true,30,%L)$q$,o1,rid,c.claim_token,t0+interval '210 seconds'))='failed_terminal','attempts exhausted: terminal');
 perform pg_temp.check_that(pg_temp.hist(rid)='1:retry_scheduled,2:lease_expired,3:failed_terminal','full history preserved through retry, crash and terminal failure');
 perform pg_temp.check_that((select count(*) from public.integration_run_artifacts where run_id=rid)=3,'exactly one diagnostic per attempt');
 perform pg_temp.check_that((select fingerprint_ok from (select request_fingerprint=fa and capability='status' and organization_id=o1 and adapter_id=ad1 and binding_id=b1 as fingerprint_ok from public.integration_runs where id=rid) z),'retries never changed fingerprint, capability, tenant, adapter or binding');
 begin update public.integration_run_artifacts set payload='{}' where run_id=rid; perform pg_temp.check_that(false,'history must be immutable');
 exception when others then perform pg_temp.check_that(sqlerrm ~ 'append_only|governed','history cannot be rewritten'); end;
 begin delete from public.integration_run_artifacts where run_id=rid; perform pg_temp.check_that(false,'history must not be deletable');
 exception when others then perform pg_temp.check_that(sqlerrm ~ 'append_only|governed','history cannot be deleted'); end;
 -- exhausted crash
 c:=pg_temp.claim(o1,b1,fd,uS,t0,'local/dh-a',60,1);
 c2:=pg_temp.claim(o1,b1,fd,uS,t0+interval '61 seconds','local/dh-a',60,1);
 perform pg_temp.check_that(c2.outcome='failed_terminal' and pg_temp.hist(c.run_id)='1:lease_expired','crash on the last attempt is terminal and leaves its trace');
 -- hostile messages must not stall a run
 c:=pg_temp.enq(o1,b1,fe_,uS,'local/dh-a');
 c2:=pg_temp.claim(o1,b1,fe_,uS,t0,'local/dh-a');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.fail_integration_run(%L,%L,%L,'api_key=abcdef123456','Authorization: Bearer abcdefghijklmnopqrstuv',true,10,%L)$q$,o1,c.run_id,c2.claim_token,t0))='retry_scheduled','a secret-looking failure message no longer raises (run is not stuck in running)');
 perform pg_temp.check_that((select status='failed' and error_message='[redacted by database guard]' and error_code='redacted_code' from public.integration_runs where id=c.run_id),'the row stores fixed markers, never the hostile text');
 perform pg_temp.check_that(not exists(select 1 from public.integration_run_artifacts a where a.run_id=c.run_id and (a.payload::text ilike '%abcdefghijklmnopqrstuv%' or a.payload::text ilike '%abcdef123456%')),'nor does the diagnostic artifact');

 -- ===== lifecycle guarantees still hold; provider "paid" is not truth =====
 c:=pg_temp.enq(o1,b1,ff,uS,'local/dh-a'); c2:=pg_temp.claim(o1,b1,ff,uS,t0,'local/dh-a');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.complete_integration_run(%L,%L,%L,'ext-ok',%L::jsonb)$q$,o1,c.run_id,c2.claim_token,arts))='succeeded','success path unchanged');
 perform pg_temp.check_that(pg_temp.hist(c.run_id)='' and (select count(*) from public.integration_run_artifacts where run_id=c.run_id)=1,'a clean success adds no diagnostics');
 perform pg_temp.check_that((pg_temp.claim(o1,b1,ff,uS,t0+interval '1 hour','local/dh-a')).outcome='replayed','replay unchanged');
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe and (select count(*) from public.financial_reconciliation_cases)=fc,'provider {"status":"paid","commission":999999,"approved":true} created no financial event and no reconciliation case');

 -- ===== read RBAC over the history =====
 perform pg_temp.check_that(pg_temp.u(uAg,'select count(*)::text from public.integration_run_artifacts')='0','agent reads no diagnostics');
 perform pg_temp.check_that(pg_temp.u(uB,format($q$select count(*)::text from public.integration_run_artifacts where run_id=%L$q$,rid))='0','tenant B cannot read tenant A history by run UUID');
 perform pg_temp.check_that(pg_temp.u(uM,format($q$select count(*)::text from public.integration_run_artifacts where run_id=%L$q$,rid))='3','manager reads the history');

 -- ===== surface =====
 perform pg_temp.check_that(not exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('claim_integration_run','fail_integration_run','list_dispatchable_integration_runs') and (p.prosecdef or has_function_privilege('authenticated',p.oid,'EXECUTE') or has_function_privilege('anon',p.oid,'EXECUTE'))),'replaced functions: still INVOKER and not executable by authenticated/anon');
 perform pg_temp.check_that((select bool_and(has_function_privilege('service_role',p.oid,'EXECUTE')) from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('claim_integration_run','fail_integration_run','list_dispatchable_integration_runs')),'replaced functions: service_role can execute');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p,lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a where p.pronamespace='public'::regnamespace and p.proname in ('claim_integration_run','fail_integration_run','list_dispatchable_integration_runs') and a.grantee=0),'replaced functions: not executable by PUBLIC');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and p.proname not in ('attach_import_batch_adapter','caller_role_in','commercial_route','import_row_evidence','lead_write','list_import_rows','bootstrap_organization_admin','get_user_organization_id')),'DEFINER inventory equals the reviewed list');

 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %
%',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED' end,case when k=0 then '' else r end;
end $test$;
