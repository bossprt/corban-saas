-- Behavioral contract for 20260919_financial_reversal_paths_v1.sql and 20260919_import_batch_adapter_lineage_v1.sql.
-- SAFE TO RUN AGAINST LIVE: everything happens inside one DO block that ends with RAISE EXCEPTION, so the whole
-- transaction (fixtures included) is rolled back. The exception message carries the result list; a run passes only
-- if the message starts with 'RESULTS: ALL PASS'. Requires the two migrations to be applied (or executed earlier in
-- the same transaction). Fixtures are synthetic and never persisted.
do $test$
declare
 u1 uuid:=gen_random_uuid(); u2 uuid:=gen_random_uuid(); u3 uuid:=gen_random_uuid(); u4 uuid:=gen_random_uuid();
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid();
 p1 uuid:=gen_random_uuid(); p2 uuid:=gen_random_uuid();
 e_exp uuid:=gen_random_uuid(); e_rep uuid:=gen_random_uuid(); e_pay uuid:=gen_random_uuid(); e_o2 uuid:=gen_random_uuid(); e_adj uuid:=gen_random_uuid();
 b1 uuid:=gen_random_uuid(); b2 uuid:=gen_random_uuid(); b3 uuid:=gen_random_uuid(); s1 uuid:=gen_random_uuid(); s2 uuid:=gen_random_uuid();
 r1 text; r2 text; r3 text; r_rev text; n int; fails text:='';
begin
 create temp table t_res(label text, pass boolean) on commit drop;
 -- helpers (created as the fixture role; they switch to `authenticated` only around the statement under test)
 create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
 begin
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role','authenticated')::text,true);
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  set local role authenticated;
 end $f$;
 create function pg_temp.run_as(p_uid uuid,q text) returns text language plpgsql as $f$
 declare r text;
 begin
  perform pg_temp.as_user(p_uid);
  begin execute q into r; exception when others then reset role; raise; end;
  reset role; return r;
 end $f$;
 create function pg_temp.expect_err(p_uid uuid,q text,pat text,label text) returns void language plpgsql as $f$
 declare msg text;
 begin
  begin
   perform pg_temp.as_user(p_uid); execute q; reset role; msg:=null;
  exception when others then reset role; msg:=sqlerrm; end;
  insert into t_res values(label, msg is not null and msg ~ pat);
  if msg is null then insert into t_res values(label||' [UNEXPECTED SUCCESS]',false);
  elsif msg !~ pat then insert into t_res values(label||' [got: '||msg||']',false); end if;
 end $f$;
 create function pg_temp.check_that(cond boolean,label text) returns void language plpgsql as $f$
 begin insert into t_res values(label,coalesce(cond,false)); end $f$;

 -- fixtures (no FK/user triggers for structural rows; guards stay ON for financial_events)
 insert into auth.users(id) values(u1),(u2),(u3),(u4);
 insert into public.organizations(id,name,document) values(o1,'T-A','doc-'||o1),(o2,'T-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role) values
  (o1,u1,'admin'),(o2,u2,'admin'),(o1,u3,'agent'),(o1,u4,'admin'),(o2,u4,'admin');
 insert into public.import_sources(id,organization_id,name,source_kind) values(s1,o1,'src-a','manual'),(s2,o2,'src-b','manual');
 set local session_replication_role='replica';
 insert into public.proposals_v2(id,organization_id,customer_id,product_table_version_id,customer_snapshot,commercial_snapshot) values
  (p1,o1,gen_random_uuid(),gen_random_uuid(),'{}','{}'),(p2,o2,gen_random_uuid(),gen_random_uuid(),'{}','{}');
 insert into public.import_batches(id,organization_id,source_id,original_filename,content_sha256,parser_key,received_by) values
  (b1,o1,s1,'a.csv',repeat('a',64),'2tech/busca_contrato_file',u1),
  (b2,o2,s2,'b.csv',repeat('b',64),'2tech/busca_contrato_file',u2),
  (b3,o1,s1,'c.csv',repeat('c',64),'daycoval-table-offer',u1);
 set local session_replication_role='origin';
 perform set_config('corban.financial_expected_rpc','on',true);
 insert into public.financial_events(id,organization_id,proposal_id,event_type,component_type,amount,occurred_at,idempotency_key,source_kind,source_reference)
  values(e_exp,o1,p1,'commission_expected','upfront',1000,now(),'fx:'||e_exp,'proposal_snapshot','fx');
 perform set_config('corban.financial_expected_rpc','off',true);
 perform set_config('corban.financial_evidence_rpc','on',true);
 insert into public.financial_events(id,organization_id,proposal_id,event_type,component_type,amount,occurred_at,idempotency_key,source_kind,source_reference) values
  (e_rep,o1,p1,'commission_reported','upfront',1000,now(),'fx:'||e_rep,'bank_report','fx'),
  (e_pay,o1,p1,'payment_received','upfront',1000,now(),'fx:'||e_pay,'bank_report','fx'),
  (e_o2,o2,p2,'payment_received','upfront',500,now(),'fx:'||e_o2,'bank_report','fx');
 perform set_config('corban.financial_evidence_rpc','off',true);


 -- ingestion RPC smoke (regression: digest() must resolve; replay by SHA-256; raw hash stored)
 r1:=pg_temp.run_as(u1,format($q$select public.ingest_normalized_import_batch(%L,'f.csv',repeat('d',64),'text/csv','2tech/busca_contrato_file','1.0.0','[{"rowNumber":1,"rawPayload":{"NumeroProposta":"9","ComissaoRepasseValor":""},"normalized":{"recordKind":"proposal","bankKey":null,"externalProposalNumber":"9","normalizedPayload":{}}}]'::jsonb)::text$q$,s1));
 perform pg_temp.check_that(r1 is not null,'ingest RPC works for an authenticated member (digest qualified)');
 r2:=pg_temp.run_as(u1,format($q$select public.ingest_normalized_import_batch(%L,'f.csv',repeat('d',64),'text/csv','2tech/busca_contrato_file','1.0.0','[{"rowNumber":1,"rawPayload":{"x":"y"},"normalized":{"recordKind":"other","normalizedPayload":{}}}]'::jsonb)::text$q$,s1));
 perform pg_temp.check_that(r2=r1,'ingest replay by SHA-256 returns the same batch');
 perform pg_temp.check_that((select count(*) from public.import_raw_rows where batch_id=r1::uuid)=1 and (select raw_hash ~ '^[0-9a-f]{64}$' from public.import_raw_rows where batch_id=r1::uuid),'raw row stored once with sha256 hash');
 r3:=pg_temp.run_as(u1,format($q$with u as (update public.import_raw_rows set raw_payload='{}'::jsonb where batch_id=%L returning 1) select count(*)::text from u$q$,r1::uuid));
 perform pg_temp.check_that(r3='0','members cannot mutate raw rows');

 -- structural: no direct/ungoverned inserts, even for the fixture owner
 perform pg_temp.expect_err(u1,format($q$insert into public.financial_events(organization_id,proposal_id,event_type,component_type,amount,occurred_at,idempotency_key,source_kind,source_reference,created_by) values(%L,%L,'reversal','upfront',1,now(),'d1','manual_review','x',%L)$q$,o1,p1,u1),'financial_reversal_requires_governed_rpc|violates','direct reversal insert blocked');
 perform pg_temp.expect_err(u1,format($q$insert into public.financial_events(organization_id,proposal_id,event_type,component_type,amount,occurred_at,idempotency_key,source_kind,source_reference,created_by) values(%L,%L,'commission_expected','upfront',1,now(),'d2','proposal_snapshot','x',%L)$q$,o1,p1,u1),'expected_commission_requires_governed_rpc','direct expected insert blocked');
 perform pg_temp.expect_err(u1,format($q$insert into public.financial_events(organization_id,proposal_id,event_type,component_type,amount,occurred_at,idempotency_key,source_kind,source_reference,created_by) values(%L,%L,'payment_received','upfront',1,now(),'d3','bank_report','x',%L)$q$,o1,p1,u1),'financial_fact_requires_evidence_rpc','direct payment insert blocked');
 perform pg_temp.expect_err(u1,format($q$insert into public.financial_events(organization_id,proposal_id,event_type,component_type,amount,occurred_at,idempotency_key,source_kind,source_reference,created_by) values(%L,%L,'adjustment','upfront',1,now(),'d4','manual_review','x',%L)$q$,o1,p1,u1),'financial_event_type_not_governed','direct adjustment insert blocked');
 perform pg_temp.expect_err(u1,format($q$insert into public.financial_events(organization_id,proposal_id,event_type,component_type,amount,occurred_at,idempotency_key,source_kind,source_reference,created_by) values(%L,%L,'downstream_payable','upfront',1,now(),'d5','manual_review','x',%L)$q$,o1,p1,u1),'financial_event_type_not_governed','ungoverned event type blocked');

 -- input validation / tenant / role
 perform pg_temp.expect_err(u1,format($q$select public.publish_financial_reversal(%L,100,'r','bank_report','ref')$q$,gen_random_uuid()),'event_not_found','nonexistent event');
 perform pg_temp.expect_err(u1,format($q$select public.publish_financial_reversal(%L,100,'r','bank_report','ref')$q$,e_o2),'event_not_found','other-tenant event (u1 -> tenant B) fails closed');
 perform pg_temp.expect_err(u2,format($q$select public.publish_financial_reversal(%L,100,'r','bank_report','ref')$q$,e_pay),'event_not_found','other-tenant event (u2 -> tenant A) fails closed');
 perform pg_temp.expect_err(u3,format($q$select public.publish_financial_reversal(%L,100,'r','bank_report','ref')$q$,e_pay),'event_not_found|forbidden','agent role cannot reverse');
 perform pg_temp.expect_err(null,format($q$select public.publish_financial_reversal(%L,100,'r','bank_report','ref')$q$,e_pay),'forbidden|event_not_found','anonymous cannot reverse');
 perform pg_temp.expect_err(u1,format($q$select public.publish_financial_reversal(%L,100,'r',null,'ref')$q$,e_pay),'reversal_source_required','source missing');
 perform pg_temp.expect_err(u1,format($q$select public.publish_financial_reversal(%L,100,'r','import','ref')$q$,e_pay),'reversal_source_required','source import rejected (no lineage)');
 perform pg_temp.expect_err(u1,format($q$select public.publish_financial_reversal(%L,100,'r','bank_report','  ')$q$,e_pay),'reversal_reference_required','reference missing');
 perform pg_temp.expect_err(u1,format($q$select public.publish_financial_reversal(%L,100,'','bank_report','ref')$q$,e_pay),'reversal_reason_required','reason missing');
 perform pg_temp.expect_err(u1,format($q$select public.publish_financial_reversal(%L,0,'r','bank_report','ref')$q$,e_pay),'invalid_reversal_amount','zero amount');
 perform pg_temp.expect_err(u1,format($q$select public.publish_financial_reversal(%L,-5,'r','bank_report','ref')$q$,e_pay),'invalid_reversal_amount','negative amount');

 -- partial reversals of payment_received (1000): 300 + 200, replay, overflow, exact remainder
 r1:=pg_temp.run_as(u1,format($q$select public.publish_financial_reversal(%L,300,'partial 1','bank_report','ref1')::text$q$,e_pay));
 perform pg_temp.check_that(r1 is not null,'partial reversal #1 accepted');
 select settled_amount::text into r2 from public.financial_reconciliation_cases where proposal_id=p1;
 perform pg_temp.check_that(r2::numeric=700,'settled = 1000-300 after partial #1 (reconciliation subtracts)');
 r2:=pg_temp.run_as(u1,format($q$select public.publish_financial_reversal(%L,200,'partial 2','bank_report','ref2')::text$q$,e_pay));
 perform pg_temp.check_that(r2 is not null and r2<>r1,'second partial reversal accepted (no UNIQUE per original)');
 perform pg_temp.check_that((select settled_amount from public.financial_reconciliation_cases where proposal_id=p1)=500,'settled = 500 after two partials');
 r3:=pg_temp.run_as(u1,format($q$select public.publish_financial_reversal(%L,300,'partial 1','bank_report','ref1')::text$q$,e_pay));
 perform pg_temp.check_that(r3=r1,'replay returns the same event (idempotent)');
 select count(*) into n from public.financial_events where reverses_event_id=e_pay;
 perform pg_temp.check_that(n=2,'replay created no extra event');
 perform pg_temp.expect_err(u1,format($q$select public.publish_financial_reversal(%L,600,'over','bank_report','ref3')$q$,e_pay),'reversal_exceeds_original','cumulative overflow (500+600>1000) rejected');
 r_rev:=pg_temp.run_as(u1,format($q$select public.publish_financial_reversal(%L,500,'rest','bank_report','ref4')::text$q$,e_pay));
 perform pg_temp.check_that(r_rev is not null,'exact remainder accepted (total reversal in 3 steps)');
 perform pg_temp.check_that((select settled_amount from public.financial_reconciliation_cases where proposal_id=p1)=0,'settled = 0 after full reversal');
 perform pg_temp.expect_err(u1,format($q$select public.publish_financial_reversal(%L,0.01,'over','bank_report','ref5')$q$,e_pay),'reversal_exceeds_original','any amount beyond fully reversed original rejected');
 perform pg_temp.check_that(r1::uuid=(select id from public.financial_events where id=r1::uuid and event_type='reversal' and reverses_event_id=e_pay),'reversal is an append-only compensating event linked to original');

 -- reported bucket / expected bucket / total reversal
 perform pg_temp.run_as(u1,format($q$select public.publish_financial_reversal(%L,400,'r','partner_report','rep1')::text$q$,e_rep));
 perform pg_temp.check_that((select reported_amount from public.financial_reconciliation_cases where proposal_id=p1)=600,'reported = 1000-400 (correct bucket)');
 perform pg_temp.check_that((select settled_amount from public.financial_reconciliation_cases where proposal_id=p1)=0,'reported reversal did not touch settled');
 perform pg_temp.run_as(u1,format($q$select public.publish_financial_reversal(%L,1000,'cancelled','manual_review','cancel-1')::text$q$,e_exp));
 perform pg_temp.check_that((select expected_amount from public.financial_reconciliation_cases where proposal_id=p1)=0,'expected = 0 after total reversal of expected');
 perform pg_temp.check_that(not exists(select 1 from public.financial_reconciliation_cases where expected_amount<0 or reported_amount<0 or settled_amount<0),'no bucket is ever negative');

 -- reversal of reversal / adjustment
 perform pg_temp.expect_err(u1,format($q$select public.publish_financial_reversal(%L,10,'r','bank_report','rr')$q$,r1::uuid),'cannot_reverse_a_reversal_or_adjustment','reversal of reversal rejected');
 alter table public.financial_events disable trigger financial_event_insert_guard;
 insert into public.financial_events(id,organization_id,proposal_id,event_type,component_type,amount,occurred_at,idempotency_key,source_kind,source_reference,metadata)
  values(e_adj,o1,p1,'adjustment','upfront',50,now(),'fx:'||e_adj,'manual_review','fx','{"affects":"settled"}');
 alter table public.financial_events enable trigger financial_event_insert_guard;
 perform pg_temp.expect_err(u1,format($q$select public.publish_financial_reversal(%L,10,'r','bank_report','ra')$q$,e_adj),'cannot_reverse_a_reversal_or_adjustment','reversal of adjustment rejected');
 perform pg_temp.check_that((select settled_amount from public.financial_reconciliation_cases where proposal_id=p1)=0,'ungoverned adjustment row is ignored by reconciliation');

 -- guard-level defence in depth (bypassing the RPC with the token set by hand still fails closed)
 perform set_config('corban.financial_reversal_rpc','on',true);
 begin
  insert into public.financial_events(organization_id,proposal_id,event_type,component_type,amount,occurred_at,idempotency_key,source_kind,source_reference,reverses_event_id)
   values(o1,p1,'reversal','upfront',1,now(),'g1','manual_review','x',e_o2);
  perform pg_temp.check_that(false,'guard: cross-tenant reverses_event_id must fail');
 exception when others then perform pg_temp.check_that(sqlerrm ~ 'reversal_target_mismatch','guard: cross-tenant reverses_event_id fails closed ('||sqlerrm||')'); end;
 begin
  insert into public.financial_events(organization_id,proposal_id,event_type,component_type,amount,occurred_at,idempotency_key,source_kind,source_reference,reverses_event_id)
   values(o1,p1,'reversal','upfront',1,now(),'g2','manual_review','x',e_pay);
  perform pg_temp.check_that(false,'guard: reversal past fully-reversed original must fail');
 exception when others then perform pg_temp.check_that(sqlerrm ~ 'reversal_exceeds_original','guard: overflow blocked even without the RPC'); end;
 perform set_config('corban.financial_reversal_rpc','off',true);

 -- concurrency (structural: real concurrent transactions cannot be committed in a rollback-only harness)
 perform pg_temp.check_that(position('pg_advisory_xact_lock' in pg_get_functiondef('public.guard_financial_event_insert'::regproc)) between 1 and position('sum(amount)' in pg_get_functiondef('public.guard_financial_event_insert'::regproc)),'guard takes the advisory lock BEFORE reading the cumulative sum');
 perform pg_temp.check_that(pg_get_functiondef('public.guard_financial_event_insert'::regproc) like '%reversal_requires_read_committed%','guard rejects non-READ-COMMITTED isolation');
 perform pg_temp.check_that(position('pg_advisory_xact_lock' in pg_get_functiondef('public.publish_financial_reversal(uuid,numeric,text,text,text)'::regprocedure)) between 1 and position('idempotency_key=v_key' in pg_get_functiondef('public.publish_financial_reversal(uuid,numeric,text,text,text)'::regprocedure)),'RPC locks before idempotency lookup (concurrent replays converge)');
 perform pg_temp.check_that(not exists(select 1 from pg_indexes where indexname='financial_events_single_reversal_uidx'),'no UNIQUE(reverses_event_id) that would forbid partial reversals');

 -- multi-organization user: tenant comes from the resource, never from LIMIT 1
 perform pg_temp.run_as(u4,format($q$select public.publish_financial_reversal(%L,100,'r','bank_report','mo-o2')::text$q$,e_o2));
 perform pg_temp.check_that((select settled_amount from public.financial_reconciliation_cases where proposal_id=p2)=400,'multi-org admin reverses in tenant B (event decides tenant)');
 perform pg_temp.run_as(u4,format($q$select public.publish_financial_reversal(%L,50,'r','bank_report','mo-o1')::text$q$,e_rep));
 perform pg_temp.check_that((select reported_amount from public.financial_reconciliation_cases where proposal_id=p1)=550,'multi-org admin reverses in tenant A');

 -- attach_import_batch_adapter: batch is the tenant authority
 perform pg_temp.run_as(u1,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')::text$q$,b1));
 perform pg_temp.check_that((select adapter_id is not null and adapter_contract_version is not null from public.import_batches where id=b1),'attach sets adapter and contract version');
 perform pg_temp.run_as(u1,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')::text$q$,b1));
 perform pg_temp.check_that(true,'attach replay is a no-op');
 perform pg_temp.expect_err(u1,format($q$select public.attach_import_batch_adapter(%L,'bevi/webservice_agente')$q$,b1),'adapter_parser_mismatch|batch_adapter_immutable','different adapter cannot replace lineage');
 perform pg_temp.expect_err(u1,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')$q$,b2),'batch_not_found_or_forbidden','cross-tenant batch (forged batch id) fails closed');
 perform pg_temp.expect_err(u3,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')$q$,b1),'batch_not_found_or_forbidden','non-receiver agent cannot attach');
 perform pg_temp.expect_err(u1,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')$q$,gen_random_uuid()),'batch_not_found_or_forbidden','nonexistent batch');
 perform pg_temp.expect_err(u1,format($q$select public.attach_import_batch_adapter(%L,'nope/none')$q$,b3),'adapter_not_found','forged adapter key');
 perform pg_temp.expect_err(u1,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')$q$,b3),'adapter_parser_mismatch','adapter must match the batch parser (forged lineage)');
 perform pg_temp.expect_err(null,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')$q$,b1),'batch_not_found_or_forbidden','anonymous cannot attach');
 perform pg_temp.run_as(u4,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')::text$q$,b2));
 perform pg_temp.check_that((select adapter_id is not null from public.import_batches where id=b2),'multi-org admin attaches in the batch tenant (not LIMIT 1)');
 r2:=pg_temp.run_as(u1,format($q$with u as (update public.import_batches set adapter_id=null where id=%L returning 1) select count(*)::text from u$q$,b1));
 perform pg_temp.check_that(r2='0' and (select adapter_id is not null from public.import_batches where id=b1),'members cannot rewrite lineage directly (no UPDATE policy)');

 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label) into r1 from t_res;
 select count(*) filter (where not pass) into n from t_res;
 raise exception 'RESULTS: %
%',case when n=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else n||' FAILED' end,r1;
end $test$;
