-- Rollback-only harness for the revoked-actor dispatch starvation (fix: 20260928_revoked_actor_dispatch_v1).
-- Set `fixed` below: false = run against a database WITHOUT the migration (proves the bug: expected to report the starvation as present);
-- true = run after the migration text (same transaction) or when it is LIVE. Ends with RAISE EXCEPTION; pass = 'RESULTS: ALL PASS'.
do $test$
declare
 fixed boolean:=__FIXED__;
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid(); uS uuid:=gen_random_uuid(); uM uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid(); uAg uuid:=gen_random_uuid();
 s1 uuid:=gen_random_uuid(); s2 uuid:=gen_random_uuid(); b1 uuid:=gen_random_uuid(); b2 uuid:=gen_random_uuid(); ad uuid:=gen_random_uuid();
 valid uuid; zr uuid; runrun uuid; child uuid; i int; c record; c2 record; r text; k int; fe int; fc int; listed text; n int; t0 timestamptz:='2026-09-25 10:00:00+00';
begin
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
 create function pg_temp.enq(p_org uuid,p_bind uuid,p_fp text,p_actor uuid) returns uuid language plpgsql as $f$
 declare r record;
 begin
  perform pg_temp.as_role('service_role',null);
  begin select * into r from public.enqueue_integration_run(p_org,p_bind,'status',p_fp,p_actor,3,'{"ref":"x"}'::jsonb,'corr-orphan','local/orphan'); exception when others then reset role; raise; end;
  reset role; return r.run_id;
 end $f$;
 create function pg_temp.list(p_limit int,p_now timestamptz) returns text language plpgsql as $f$
 declare r text;
 begin
  perform pg_temp.as_role('service_role',null);
  begin select coalesce(string_agg(x.run_id::text,',' order by x.run_id),'') into r from public.list_dispatchable_integration_runs(p_limit,p_now,array['local/orphan']) x; exception when others then reset role; raise; end;
  reset role; return r;
 end $f$;

 insert into auth.users(id) values(uS),(uM),(uB),(uAg);
 insert into public.organizations(id,name,document) values(o1,'OR-A','doc-'||o1),(o2,'OR-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role,status) values(o1,uS,'supervisor','active'),(o1,uM,'manager','active'),(o1,uAg,'agent','active'),(o2,uB,'admin','active');
 insert into public.import_sources(id,organization_id,name,source_kind) values(s1,o1,'a','manual'),(s2,o2,'b','manual');
 insert into public.integration_adapters(id,adapter_key,provider_key,transport,name,contract_version,capabilities) values(ad,'local/orphan','local','api','orphan','1.0.0','["status"]');
 insert into public.integration_source_bindings(id,organization_id,source_id,adapter_id) values(b1,o1,s1,ad),(b2,o2,s2,ad);
 select count(*) into fe from public.financial_events; select count(*) into fc from public.financial_reconciliation_cases;

 -- 12 runs created by the supervisor while active, then the supervisor is deactivated; one run created by an active manager; one by tenant B's admin
 for i in 1..12 loop perform pg_temp.enq(o1,b1,lpad(i::text,64,'a'),uS); end loop;
 valid:=pg_temp.enq(o1,b1,repeat('f',64),uM);
 runrun:=pg_temp.enq(o2,b2,repeat('e',64),uB);
 set local session_replication_role='replica';
 update public.integration_runs set created_at=now()-interval '2 hours' where created_by=uS;
 update public.organization_memberships set status='inactive' where user_id=uS;
 set local session_replication_role='origin';

 -- ---- the starvation, measured with the worker's own pass size (10)
 listed:=pg_temp.list(10,t0);
 if fixed then
  perform pg_temp.check_that(position(valid::text in listed)>0,'FIXED: the valid run is listed although 12 older orphans exist');
  perform pg_temp.check_that((select count(*) from unnest(string_to_array(listed,',')) x where x::uuid in (select id from public.integration_runs where created_by=uS))=0,'FIXED: no orphan of the revoked actor is listed');
 else
  perform pg_temp.check_that(position(valid::text in listed)=0 and array_length(string_to_array(listed,','),1)=10,'BUG CONFIRMED (unfixed schema): 10 orphans of the revoked actor fill the whole pass; the valid run is starved');
 end if;
 perform pg_temp.check_that(position(runrun::text in pg_temp.list(50,t0))>0,'tenant B run by an active admin is listed');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'status',%L,%L,3,60,'{}'::jsonb,'c',now(),'local/orphan')$q$,o1,b1,lpad('1',64,'a'),uS),'actor_not_authorized','claim by the revoked actor is refused (both schemas)');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'status',%L,%L,3,60,'{}'::jsonb,'c',now(),'local/orphan')$q$,o1,b1,repeat('9',64),uS),'actor_not_authorized','a NEW run by the revoked actor is refused');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'status',%L,%L,3,60,'{}'::jsonb,'c',now(),'local/orphan')$q$,o1,b1,repeat('8',64),uAg),'actor_not_authorized','a NEW run by an agent is refused');
 perform pg_temp.check_that(pg_temp.err_of('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'status',%L,%L,3,60,'{}'::jsonb,'c',now(),'local/orphan')$q$,o1,b1,repeat('7',64),uM)) is null,'the valid manager claims normally');

 if fixed then
  perform pg_temp.expect_err('authenticated',uM,'select public.sweep_orphaned_integration_runs(10)','permission denied','a manager cannot call the sweep');
  perform pg_temp.expect_err('anon',null,'select public.sweep_orphaned_integration_runs(10)','permission denied','anon cannot call the sweep');
  perform pg_temp.check_that(not (select prosecdef from pg_proc where proname='sweep_orphaned_integration_runs'),'the sweep is SECURITY INVOKER');
  -- an orphan that was RUNNING (lease expired) before the actor was revoked
  set local session_replication_role='replica';
  update public.organization_memberships set status='active' where user_id=uS;
  set local session_replication_role='origin';
  zr:=pg_temp.enq(o1,b1,repeat('d',64),uS);
  c:=null;
  perform pg_temp.as_role('service_role',null);
  select * into c from public.claim_integration_run(o1,b1,'status',repeat('d',64),uS,3,60,'{}'::jsonb,'c',t0,'local/orphan');
  reset role;
  set local session_replication_role='replica';
  update public.organization_memberships set status='inactive' where user_id=uS;
  set local session_replication_role='origin';
  perform pg_temp.check_that((select status='running' from public.integration_runs where id=zr),'setup: an orphan in state running');
  n:=pg_temp.svc(format($q$select public.sweep_orphaned_integration_runs(200,%L)$q$,t0+interval '10 minutes'))::int;
  perform pg_temp.check_that(n=13,'sweep handled the 12 queued orphans and the running one (13)');
  perform pg_temp.check_that((select count(*)=12 and bool_and(error_code='actor_no_longer_authorized' and finished_at is not null) from public.integration_runs where created_by=uS and status='cancelled'),'queued orphans are CANCELLED with a sanitized code');
  perform pg_temp.check_that((select status='failed' and terminal and error_code='terminal:actor_no_longer_authorized' from public.integration_runs where id=zr),'the running orphan is terminally FAILED, not left running');
  perform pg_temp.check_that((select bool_and(status='queued') from public.integration_runs where id in (valid,runrun)),'valid runs (manager, tenant B admin) are untouched');
  perform pg_temp.check_that((select count(*)=13 and bool_and(error_message='the member who created this run no longer has access') from public.integration_runs where created_by=uS),'every orphan carries the fixed sanitized message');
  perform pg_temp.check_that(pg_temp.svc(format($q$select public.sweep_orphaned_integration_runs(200,%L)$q$,t0+interval '11 minutes'))='0','sweep is idempotent (second pass = 0)');
  perform pg_temp.check_that(position(valid::text in pg_temp.list(10,t0))>0 and pg_temp.list(10,t0) not like '%'||zr::text||'%','after the sweep the valid run is dispatched first');
  perform pg_temp.svc(format($q$select run_id::text from public.create_integration_reexecution(%L,%L,%L,'nova execucao criada por um gerente ativo','corr-re')$q$,o1,(select id from public.integration_runs where created_by=uS and status='cancelled' limit 1),uM));
  perform pg_temp.check_that((select count(*)=1 and bool_and(created_by=uM and organization_id=o1) from public.integration_runs where parent_run_id in (select id from public.integration_runs where created_by=uS)),'a manager can re-execute an orphan: new run, same tenant, owned by the manager');
  perform pg_temp.expect_err('authenticated',uM,format($q$update public.integration_runs set status='queued' where id=%L$q$,zr),'permission denied','an orphan cannot be revived by direct UPDATE');
 end if;
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe and (select count(*) from public.financial_reconciliation_cases)=fc,'no financial truth created');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and p.proname not in ('attach_import_batch_adapter','caller_role_in','commercial_route','import_row_evidence','lead_write','list_import_rows','bootstrap_organization_admin','get_user_organization_id')),'DEFINER inventory equals the 8 reviewed functions');
 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED: '||r end;
end $test$;
