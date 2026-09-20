-- Rollback-only adversarial harness for 20261005_ai_import_metering_v1. Run the migration text first (same transaction until LIVE), then this DO block.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid(); uMg uuid:=gen_random_uuid(); uSv uuid:=gen_random_uuid(); uAg uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid(); uR uuid:=gen_random_uuid();
 fp1 text:=repeat('a',64); fp2 text:=repeat('b',64); m1 uuid; m2 uuid; j1 uuid; j1b uuid; j2 uuid; j3 uuid; bal numeric; r text; k int; n int;
begin
 create temp table t_res(label text, pass boolean) on commit drop;
 create function pg_temp.u(p_uid uuid,q text) returns text language plpgsql as $f$
 declare r text;
 begin
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role','authenticated')::text,true);
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  set local role authenticated;
  begin execute q into r; exception when others then reset role; raise; end;
  reset role; return r;
 end $f$;
 create function pg_temp.expect_err(p_uid uuid,q text,pat text,label text) returns void language plpgsql as $f$
 declare msg text;
 begin
  begin perform pg_temp.u(p_uid,q); msg:=null; exception when others then msg:=sqlerrm; end;
  if msg is null then insert into t_res values(label||' [UNEXPECTED SUCCESS]',false);
  elsif msg !~ pat then insert into t_res values(label||' [got: '||msg||']',false);
  else insert into t_res values(label,true); end if;
 end $f$;
 create function pg_temp.pg_err(q text,pat text,label text) returns void language plpgsql as $f$
 declare msg text;
 begin
  begin execute q; msg:=null; exception when others then msg:=sqlerrm; end;
  if msg is null then insert into t_res values(label||' [UNEXPECTED SUCCESS]',false);
  elsif msg !~ pat then insert into t_res values(label||' [got: '||msg||']',false);
  else insert into t_res values(label,true); end if;
 end $f$;
 create function pg_temp.check_that(cond boolean,label text) returns void language plpgsql as $f$
 begin insert into t_res values(label,coalesce(cond,false)); end $f$;
 create function pg_temp.bal(p_uid uuid,p_org uuid) returns numeric language sql as $f$ select pg_temp.u(p_uid,format('select public.ai_credit_balance(%L)::text',p_org))::numeric $f$;
 create function pg_temp.reserve(p_uid uuid,p_org uuid,p_est text,p_key text,p_cap text default 'import_mapping') returns text language sql as $f$
  select pg_temp.u(p_uid,format('select public.reserve_ai_job(%L,%L,%L,%L,%L,%L,%L,%L)::text',p_org,p_cap,'gemini','fake-model',p_est,'0.5','fp',p_key)) $f$;
 insert into auth.users(id) values(uMg),(uSv),(uAg),(uB),(uR);
 insert into public.organizations(id,name,document) values(o1,'AI-A','doc-'||o1),(o2,'AI-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role,status) values(o1,uMg,'manager','active'),(o1,uSv,'supervisor','active'),(o1,uAg,'agent','active'),(o1,uR,'supervisor','inactive'),(o2,uB,'admin','active');

 -- ---- confirmed mapping memory
 m1:=pg_temp.u(uSv,format($q$select public.confirm_import_mapping(%L,'Banco X',%L,'{"term":"Prazo","coefficient":"Coef"}'::jsonb,'["Obs"]'::jsonb,0.93,'gemini','fake')::text$q$,o1,fp1))::uuid;
 perform pg_temp.check_that((select version=1 and status='confirmed' and confirmed_by=uSv and confidence=0.93 from public.import_layout_mappings where id=m1),'a supervisor confirms a mapping for an origin + layout fingerprint (v1)');
 m2:=pg_temp.u(uMg,format($q$select public.confirm_import_mapping(%L,' banco x ',%L,'{"term":"Prazo","coefficient":"Coeficiente"}'::jsonb,'[]'::jsonb,null,null,null)::text$q$,o1,fp1))::uuid;
 perform pg_temp.check_that((select version=2 and status='confirmed' from public.import_layout_mappings where id=m2) and (select status='superseded' from public.import_layout_mappings where id=m1) and (select count(*) from public.import_layout_mappings where status='confirmed')=1,'confirming again (same origin, case/space-insensitive, same fingerprint) creates v2 and supersedes v1; one confirmed');
 perform pg_temp.check_that(pg_temp.u(uSv,format($q$select public.confirm_import_mapping(%L,'Banco X',%L,'{"term":"Prazo"}'::jsonb,'[]'::jsonb,null,null,null)::text$q$,o1,fp2)) is not null,'a different fingerprint is created');
 perform pg_temp.check_that((select count(*) from public.import_layout_mappings where status='confirmed')=2,'a different fingerprint (the layout changed) is a separate memory');
 perform pg_temp.expect_err(uAg,format($q$select public.confirm_import_mapping(%L,'X',%L,'{"term":"P"}'::jsonb,'[]'::jsonb,null,null,null)$q$,o1,fp1),'not_authorized','an agent cannot confirm a mapping');
 perform pg_temp.expect_err(uR,format($q$select public.confirm_import_mapping(%L,'X',%L,'{"term":"P"}'::jsonb,'[]'::jsonb,null,null,null)$q$,o1,fp1),'not_authorized','an inactive supervisor cannot');
 perform pg_temp.expect_err(uB,format($q$select public.confirm_import_mapping(%L,'X',%L,'{"term":"P"}'::jsonb,'[]'::jsonb,null,null,null)$q$,o1,fp1),'not_authorized','tenant B cannot write into tenant A');
 perform pg_temp.expect_err(uSv,format($q$select public.confirm_import_mapping(%L,'X',%L,'{"salary":"P"}'::jsonb,'[]'::jsonb,null,null,null)$q$,o1,fp1),'invalid_mapping','a field outside the closed canonical list is refused');
 perform pg_temp.expect_err(uSv,format($q$select public.confirm_import_mapping(%L,'X',%L,'{"term":{"a":1}}'::jsonb,'[]'::jsonb,null,null,null)$q$,o1,fp1),'invalid_mapping','a non string column name is refused');
 perform pg_temp.expect_err(uSv,format($q$select public.confirm_import_mapping(%L,'X',%L,'{}'::jsonb,'[]'::jsonb,null,null,null)$q$,o1,fp1),'invalid_mapping','an empty mapping is refused');
 perform pg_temp.expect_err(uSv,format($q$select public.confirm_import_mapping(%L,'X','nothex','{"term":"P"}'::jsonb,'[]'::jsonb,null,null,null)$q$,o1),'invalid_mapping','a bad fingerprint is refused');
 perform pg_temp.expect_err(uSv,format($q$select public.confirm_import_mapping(%L,'X',%L,'{"term":"P"}'::jsonb,'[]'::jsonb,1.5,null,null)$q$,o1,fp1),'invalid_mapping','confidence above 1 refused');
 perform pg_temp.expect_err(uSv,format($q$select public.confirm_import_mapping(%L,'X',%L,'{"term":"P"}'::jsonb,'[1]'::jsonb,null,null,null)$q$,o1,fp1),'invalid_mapping','unknown columns must be strings');
 perform pg_temp.expect_err(uSv,format($q$insert into public.import_layout_mappings(organization_id,source_label,layout_fingerprint,version,mapping) values(%L,'Z',%L,1,'{"term":"P"}')$q$,o1,fp1),'mapping_write_requires_governed_rpc','direct insert refused');
 perform pg_temp.expect_err(uSv,format($q$update public.import_layout_mappings set mapping='{"term":"Hack"}' where id=%L$q$,m2),'mapping_write_requires_governed_rpc','direct update refused');
 perform pg_temp.pg_err(format($q$update public.import_layout_mappings set mapping='{"term":"Hack"}' where id=%L$q$,m2),'mapping_is_immutable','even the platform cannot rewrite a confirmed mapping');
 perform pg_temp.check_that(pg_temp.u(uAg,'select count(*)::text from public.import_layout_mappings')='0' and pg_temp.u(uB,'select count(*)::text from public.import_layout_mappings')='0' and pg_temp.u(uSv,'select count(*)::text from public.import_layout_mappings')='3','agents and other tenants read no mapping; a supervisor reads its own');

 -- ---- metering: AI is OFF by default
 perform pg_temp.expect_err(uMg,format($q$select public.reserve_ai_job(%L,'import_mapping','gemini','m',5,0.1,'fp','key-aaaaaaaa')$q$,o1),'ai_disabled','AI is off by default: no limits row, no reservation');
 perform pg_temp.check_that(pg_temp.bal(uSv,o1)=0,'no credits by default');
 perform pg_temp.expect_err(uMg,format($q$insert into public.ai_credit_ledger(organization_id,kind,credits,idempotency_key) values(%L,'grant',999,'self-grant-1')$q$,o1),'ai_write_requires_governed_rpc','a tenant cannot write its own credits (direct insert refused)');
 perform pg_temp.expect_err(uMg,format($q$select public.platform_grant_ai_credits(%L,100,'self-grant-2','x')$q$,o1),'permission denied','a tenant cannot call the platform grant');
 perform pg_temp.expect_err(uMg,format($q$select public.platform_set_ai_limits(%L,true,1000)$q$,o1),'permission denied','a tenant cannot raise its own ceiling');
 perform pg_temp.check_that(has_function_privilege('service_role','public.platform_grant_ai_credits(uuid,numeric,text,text)','execute') and not has_function_privilege('authenticated','public.platform_grant_ai_credits(uuid,numeric,text,text)','execute') and not has_function_privilege('anon','public.platform_set_ai_limits(uuid,boolean,numeric)','execute'),'only service_role can grant credits or set limits');
 -- the platform switches AI on and grants credits (this block runs as the platform role)
 perform public.platform_set_ai_limits(o1,true,100);
 perform public.platform_grant_ai_credits(o1,50,'grant-o1-0001','pilot');
 perform public.platform_grant_ai_credits(o1,50,'grant-o1-0001','pilot again');
 perform pg_temp.check_that(pg_temp.bal(uSv,o1)=50 and (select count(*) from public.ai_credit_ledger where kind='grant')=1,'the grant is idempotent by key (50 credits, one ledger row)');
 perform pg_temp.check_that(pg_temp.bal(uMg,o1)=50,'managers and supervisors read the balance in credits');
 perform pg_temp.expect_err(uAg,format($q$select public.ai_credit_balance(%L)$q$,o1),'not_authorized','an agent cannot read the balance');
 perform pg_temp.expect_err(uB,format($q$select public.ai_credit_balance(%L)$q$,o1),'not_authorized','tenant B cannot read tenant A balance');
 -- reserve
 j1:=pg_temp.reserve(uSv,o1,'10','job-key-0001')::uuid;
 perform pg_temp.check_that(pg_temp.bal(uSv,o1)=40 and (select status='reserved' and estimated_credits=10 and estimated_provider_cost=0.5 and credits_charged is null from public.ai_usage_jobs where id=j1),'reserving takes the estimate out of the balance; provider cost is stored apart from credits');
 j1b:=pg_temp.reserve(uSv,o1,'10','job-key-0001')::uuid;
 perform pg_temp.check_that(j1b=j1 and pg_temp.bal(uSv,o1)=40 and (select count(*) from public.ai_credit_ledger where kind='reserve')=1,'the same idempotency key returns the same job and reserves once');
 perform pg_temp.expect_err(uSv,format($q$select public.reserve_ai_job(%L,'import_mapping','gemini','m',11,0.5,'fp','job-key-0001')$q$,o1),'idempotency_conflict','the same key with a different estimate is refused');
 perform pg_temp.expect_err(uSv,format($q$select public.reserve_ai_job(%L,'import_mapping','gemini','m',60,0.5,'fp','job-key-0002')$q$,o1),'insufficient_credits','no reservation beyond the balance');
 perform pg_temp.expect_err(uSv,format($q$select public.reserve_ai_job(%L,'import_mapping','gemini','m',95,0.5,'fp','job-key-0003')$q$,o1),'insufficient_credits|monthly_limit_exceeded','no reservation beyond the balance or the ceiling');
 perform public.platform_set_ai_limits(o1,true,15);
 perform pg_temp.expect_err(uSv,format($q$select public.reserve_ai_job(%L,'import_mapping','gemini','m',10,0.5,'fp','job-key-0004')$q$,o1),'monthly_limit_exceeded','the monthly ceiling (10 used + 10 > 15) blocks the second job');
 perform public.platform_set_ai_limits(o1,true,100);
 perform pg_temp.expect_err(uAg,format($q$select public.reserve_ai_job(%L,'import_mapping','gemini','m',1,0.5,'fp','job-key-0005')$q$,o1),'not_authorized','an agent cannot reserve');
 perform pg_temp.expect_err(uB,format($q$select public.reserve_ai_job(%L,'import_mapping','gemini','m',1,0.5,'fp','job-key-0005')$q$,o1),'not_authorized','tenant B cannot reserve on tenant A');
 perform pg_temp.expect_err(uSv,format($q$select public.reserve_ai_job(%L,'import_mapping','gemini','m',0,0.5,'fp','job-key-0006')$q$,o1),'invalid_ai_job','a zero estimate is refused');
 perform pg_temp.expect_err(uSv,format($q$select public.reserve_ai_job(%L,'mystery','gemini','m',1,0.5,'fp','job-key-0007')$q$,o1),'invalid_ai_job','an unknown capability is refused');
 perform pg_temp.expect_err(uSv,format($q$select public.reserve_ai_job(%L,'import_mapping','gemini','m',1,-1,'fp','job-key-0008')$q$,o1),'invalid_ai_job','a negative cost is refused');
 perform pg_temp.expect_err(uSv,format($q$select public.reserve_ai_job(%L,'import_mapping','gemini','m',1,0.5,'fp','short')$q$,o1),'invalid_ai_job','a short idempotency key is refused');
 -- settle
 perform pg_temp.expect_err(uAg,format($q$select public.settle_ai_job(%L,'succeeded',7,0.4,100,50)$q$,j1),'not_authorized|job_not_found','an agent cannot settle');
 perform pg_temp.expect_err(uSv,format($q$select public.settle_ai_job(%L,'succeeded',11,0.4,100,50)$q$,j1),'charge_exceeds_reservation','a charge above the reservation is refused (no overrun)');
 perform pg_temp.check_that(pg_temp.u(uSv,format($q$select public.settle_ai_job(%L,'succeeded',7,0.4,100,50)::text$q$,j1))=j1::text,'settle succeeded with 7 credits');
 perform pg_temp.check_that(pg_temp.bal(uSv,o1)=43 and (select status='succeeded' and credits_charged=7 and actual_provider_cost=0.4 and input_units=100 and output_units=50 and settled_at is not null from public.ai_usage_jobs where id=j1),'reservation released, 7 credits charged (balance 43); real provider cost recorded separately');
 perform pg_temp.check_that(pg_temp.u(uSv,format($q$select public.settle_ai_job(%L,'succeeded',7,0.4,100,50)::text$q$,j1))=j1::text,'settling again returns the job');
 perform pg_temp.check_that((select count(*) from public.ai_credit_ledger where job_id=j1)=3,'settling the same outcome again is a no-op (still 3 ledger rows)');
 perform pg_temp.expect_err(uSv,format($q$select public.settle_ai_job(%L,'failed',0,0,0,0)$q$,j1),'job_already_settled','a settled job cannot change outcome');
 j2:=pg_temp.reserve(uMg,o1,'20','job-key-0010')::uuid;
 perform pg_temp.check_that(pg_temp.bal(uSv,o1)=23,'second reservation of 20 leaves 23');
 perform pg_temp.check_that(pg_temp.u(uMg,format($q$select public.settle_ai_job(%L,'failed',null,null,0,0)::text$q$,j2))=j2::text,'failed settle returns the job');
 perform pg_temp.check_that(pg_temp.bal(uSv,o1)=43 and (select credits_charged=0 from public.ai_usage_jobs where id=j2),'a failed job releases everything: nothing is charged');
 j3:=pg_temp.reserve(uMg,o1,'5','job-key-0011')::uuid;
 perform pg_temp.check_that(pg_temp.u(uMg,format($q$select public.settle_ai_job(%L,'cancelled',null,null,null,null)::text$q$,j3))=j3::text,'cancelled settle returns the job');
 perform pg_temp.check_that(pg_temp.bal(uSv,o1)=43,'a cancelled job releases the reservation');
 perform pg_temp.check_that(pg_temp.u(uSv,format($q$select count(*)::text from public.ai_usage_events where job_id=%L$q$,j1))='2','events record reserved + succeeded');
 -- append-only, immutability
 perform pg_temp.pg_err(format($q$update public.ai_credit_ledger set credits=credits*2 where job_id=%L$q$,j1),'ai_records_are_append_only','the ledger can never be updated, not even by the platform');
 perform pg_temp.pg_err(format($q$delete from public.ai_credit_ledger where job_id=%L$q$,j1),'ai_records_are_append_only','the ledger can never be deleted');
 perform pg_temp.pg_err(format($q$delete from public.ai_usage_events where job_id=%L$q$,j1),'ai_records_are_append_only','events can never be deleted');
 perform pg_temp.pg_err(format($q$update public.ai_usage_jobs set credits_charged=0 where id=%L$q$,j1),'job_already_settled','a settled job cannot be rewritten');
 perform pg_temp.expect_err(uSv,format($q$update public.ai_usage_jobs set status='failed' where id=%L$q$,j1),'ai_write_requires_governed_rpc','direct job update refused');
 perform pg_temp.expect_err(uSv,format($q$delete from public.ai_usage_jobs where id=%L$q$,j1),'permission denied','jobs can never be deleted');
 perform pg_temp.check_that(pg_temp.u(uAg,'select (select count(*) from public.ai_usage_jobs)+(select count(*) from public.ai_credit_ledger)+(select count(*) from public.ai_usage_events)+(select count(*) from public.organization_ai_limits)')::int=0 and pg_temp.u(uB,'select (select count(*) from public.ai_usage_jobs)+(select count(*) from public.ai_credit_ledger)')::int=0,'FAIL CLOSED: agents and other tenants read no job, ledger, event or limit');
 perform pg_temp.check_that(not exists(select 1 from information_schema.columns where table_schema='public' and table_name in ('ai_usage_jobs','ai_credit_ledger','organization_ai_limits','import_layout_mappings') and data_type in ('real','double precision')),'no floating point column');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and p.proname not in ('attach_import_batch_adapter','caller_role_in','commercial_route','import_row_evidence','lead_write','list_import_rows','bootstrap_organization_admin','get_user_organization_id')),'DEFINER inventory unchanged');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p,lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a where p.pronamespace='public'::regnamespace and p.proname in ('confirm_import_mapping','ai_credit_balance','reserve_ai_job','settle_ai_job','platform_grant_ai_credits','platform_set_ai_limits') and (a.grantee=0 or a.grantee=(select oid from pg_roles where rolname='anon'))),'no AI/metering function executable by PUBLIC or anon');
 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED: '||left(r,1500) end;
end $test$;
