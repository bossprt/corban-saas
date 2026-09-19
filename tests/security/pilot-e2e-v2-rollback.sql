-- Pilot E2E v2, rollback-only. The v1 journey (pilot-e2e-rollback.sql) plus everything added after it:
--   governed simulations (20260926, NOT LIVE: run its text first in the same transaction until it is LIVE), attempt history, re-execution lineage,
--   cross-tenant attacks over the whole chain, and a revoked user who must be refused everywhere.
-- The team lifecycle (20260925) is LIVE. Ends with RAISE EXCEPTION; pass = 'RESULTS: ALL PASS'. Every row is synthetic and rolled back.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid();
 uAd uuid:=gen_random_uuid(); uAg uuid:=gen_random_uuid(); uSv uuid:=gen_random_uuid(); uMg uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid();
 s1 uuid:=gen_random_uuid(); s2 uuid:=gen_random_uuid(); bind1 uuid:=gen_random_uuid(); bindB uuid:=gen_random_uuid(); adp uuid:=gen_random_uuid();
 pt uuid:=gen_random_uuid(); ptB uuid:=gen_random_uuid(); pver uuid:=gen_random_uuid(); pverB uuid:=gen_random_uuid(); st1 uuid:=gen_random_uuid(); st2 uuid:=gen_random_uuid(); st3 uuid:=gen_random_uuid();
 lead uuid; cust uuid; custB uuid:=gen_random_uuid(); sim uuid; simB uuid; prop uuid; ocase uuid; mAg uuid; child uuid; fe int; fc int; r text; k int; c record; c2 record; t0 timestamptz:='2026-09-24 10:00:00+00';
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
 create function pg_temp.accept(p_uid uuid,p_email text) returns text language sql as $f$
  select pg_temp.svc(format($q$select coalesce(string_agg(x.outcome||':'||x.role,','),'') from public.accept_organization_invitations(%L,%L) x$q$,p_uid,p_email)) $f$;
 create function pg_temp.claim(p_org uuid,p_bind uuid,p_fp text,p_actor uuid,p_now timestamptz,p_key text) returns record language plpgsql as $f$
 declare r record;
 begin
  perform pg_temp.as_role('service_role',null);
  begin select * into r from public.claim_integration_run(p_org,p_bind,'status',p_fp,p_actor,2,60,'{"proposal":"redacted-ref"}'::jsonb,'corr-pilot2',p_now,p_key); exception when others then reset role; raise; end;
  reset role; return r;
 end $f$;
 create function pg_temp.fail(p_org uuid,p_run uuid,p_tok uuid,p_msg text,p_now timestamptz) returns text language sql as $f$
  select pg_temp.svc(format($q$select public.fail_integration_run(%L,%L,%L,'timeout',%L,true,5,%L)$q$,p_org,p_run,p_tok,p_msg,p_now)) $f$;

 insert into auth.users(id) values(uAd),(uAg),(uSv),(uMg),(uB);
 insert into public.organizations(id,name,document) values(o1,'P2-A','doc-'||o1),(o2,'P2-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role,status) values(o1,uAd,'admin','active'),(o2,uB,'admin','active');
 set local session_replication_role='replica';
 insert into public.product_tables(id,organization_id,route_id,code,name,status) values(pt,o1,gen_random_uuid(),'T-P2','Tabela sintetica','active'),(ptB,o2,gen_random_uuid(),'T-P2B','Tabela B','active');
 insert into public.product_table_versions(id,organization_id,product_table_id,version,status,rate,coefficient,term_min,term_max,published_at) values(pver,o1,pt,1,'published',1.5,0.02,12,84,now()),(pverB,o2,ptB,1,'published',1.9,0.03,12,84,now());
 insert into public.operational_stages(id,organization_id,code,name,canonical_state,sort_order,sla_minutes,is_active) values(st1,o1,'dq','Fila','digitization_queue',0,60,true),(st2,o1,'dg','Digitando','digitizing',1,60,true),(st3,o1,'sb','Enviada','submitted',2,60,true);
 insert into public.clients(id,organization_id,full_name,cpf) values(custB,o2,'Cliente Sintetico B','00000000009');
 set local session_replication_role='origin';
 select count(*) into fe from public.financial_events; select count(*) into fc from public.financial_reconciliation_cases;

 -- ===== 1. team (LIVE lifecycle) =====
 perform pg_temp.u(uAd,format($q$select public.create_organization_invitation(%L,'op@p2.example','agent')$q$,o1));
 perform pg_temp.u(uAd,format($q$select public.create_organization_invitation(%L,'sup@p2.example','supervisor')$q$,o1));
 perform pg_temp.u(uAd,format($q$select public.create_organization_invitation(%L,'mgr@p2.example','manager')$q$,o1));
 perform pg_temp.check_that(pg_temp.accept(uAg,'op@p2.example')='joined:agent' and pg_temp.accept(uSv,'sup@p2.example')='joined:supervisor' and pg_temp.accept(uMg,'mgr@p2.example')='joined:manager','invited team accepts and joins with the invited roles');

 -- ===== 2. agent: lead -> customer -> GOVERNED simulation =====
 lead:=pg_temp.u(uAg,format($q$select public.create_lead(%L::uuid,'whatsapp','Cliente P2','5511900000002',null,'camp-p2','wa-p2-1')::text$q$,o1))::uuid;
 cust:=pg_temp.u(uAg,format($q$select public.convert_lead_to_customer(%L,'22233344455')::text$q$,lead))::uuid;
 sim:=pg_temp.u(uAg,format($q$select public.create_simulation(%L,%L,10000,36)::text$q$,cust,pver))::uuid;
 perform pg_temp.check_that((select organization_id=o1 and created_by=uAg and status='calculated' and installment_amount=200 and expected_commission_amount is null from public.simulations where id=sim),'agent creates a simulation through the governed RPC (tenant derived, installment computed, no commission)');
 perform pg_temp.expect_err('authenticated',uAg,format($q$insert into public.simulations(organization_id,customer_id,product_table_version_id,status,requested_amount) values(%L,%L,%L,'calculated',1)$q$,o1,cust,pver),'governed_rpc','direct INSERT of a simulation is refused');
 perform pg_temp.expect_err('authenticated',uAg,format($q$update public.simulations set expected_commission_amount=999999 where id=%L$q$,sim),'permission denied','forged commission on a simulation is refused');

 -- ===== 3. cross-tenant attacks over the chain =====
 simB:=pg_temp.u(uB,format($q$select public.create_simulation(%L,%L,5000,24)::text$q$,custB,pverB))::uuid;
 perform pg_temp.expect_err('authenticated',uAg,format($q$select public.create_simulation(%L,%L,1000,24)$q$,custB,pver),'customer_not_found_or_forbidden','simulation A -> customer B');
 perform pg_temp.expect_err('authenticated',uAg,format($q$select public.create_simulation(%L,%L,1000,24)$q$,cust,pverB),'published_table_version_not_available','simulation A -> table version B');
 perform pg_temp.expect_err('authenticated',uSv,format($q$select public.create_proposal_from_simulation(%L)$q$,simB),'simulation_not_found_or_forbidden','proposal A -> simulation B');
 perform pg_temp.expect_err('authenticated',uAd,format($q$select public.set_member_role((select id from public.organization_memberships where user_id=%L),'agent')$q$,uB),'membership_not_found','membership A -> manage B');
 perform pg_temp.expect_err('authenticated',uAd,format($q$select public.create_organization_invitation(%L,'x@p2.example','agent')$q$,o2),'not_authorized','invite A -> tenant B');

 -- ===== 4. supervisor: proposal -> esteira =====
 prop:=pg_temp.u(uSv,format($q$select public.create_proposal_from_simulation(%L)::text$q$,sim))::uuid;
 perform pg_temp.check_that((select status='draft' and expected_commission_amount is null from public.proposals_v2 where id=prop),'proposal from the governed simulation: draft, no commission');
 set local session_replication_role='replica';
 update public.proposals_v2 set status='ready_for_digitization' where id=prop;
 set local session_replication_role='origin';
 perform pg_temp.u(uSv,format($q$select public.send_proposal_to_digitization(%L)::text$q$,prop));
 ocase:=(select id from public.operational_cases where proposal_id=prop);
 perform pg_temp.check_that(pg_temp.u(uAg,format($q$select public.transition_operational_case(%L,'digitizing')$q$,ocase))='digitizing' and pg_temp.u(uSv,format($q$select public.transition_operational_case(%L,'submitted')$q$,ocase))='submitted','esteira: digitizing (agent) then submitted (supervisor)');
 perform pg_temp.expect_err('authenticated',uB,format($q$select public.transition_operational_case(%L,'approved')$q$,ocase),'operational_case_not_found_or_forbidden','operational case A -> update by B');
 perform pg_temp.expect_err('authenticated',uSv,format($q$select public.transition_operational_case(%L,'paid')$q$,ocase),'paid_requires_confirmed_financial_source','PAID is not reachable through the esteira');

 -- ===== 5. integration: attempts, history, re-execution =====
 insert into public.import_sources(id,organization_id,name,source_kind) values(s1,o1,'src p2','manual'),(s2,o2,'src p2b','manual');
 insert into public.integration_adapters(id,adapter_key,provider_key,transport,name,contract_version,capabilities) values(adp,'local/p2','local','api','fake p2','1.0.0','["status"]');
 insert into public.integration_source_bindings(id,organization_id,source_id,adapter_id) values(bind1,o1,s1,adp),(bindB,o2,s2,adp);
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'status',%L,%L,2,60,'{}'::jsonb,'c',now(),'local/p2')$q$,o1,bindB,repeat('9',64),uSv),'binding_not_found','run A -> provider binding B');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'status',%L,%L,2,60,'{}'::jsonb,'c',now(),'local/p2')$q$,o1,bind1,repeat('8',64),uAg),'actor_not_authorized','an agent cannot start a run');
 c:=pg_temp.claim(o1,bind1,repeat('a',64),uSv,t0,'local/p2');
 perform pg_temp.check_that(pg_temp.fail(o1,c.run_id,c.claim_token,'provider timed out',t0+interval '1 second')='retry_scheduled','attempt 1 fails (retry scheduled)');
 c2:=pg_temp.claim(o1,bind1,repeat('a',64),uSv,t0+interval '10 seconds','local/p2');
 perform pg_temp.check_that(c2.run_id=c.run_id and c2.attempt_count=2,'RETRY continues the SAME run');
 perform pg_temp.check_that(pg_temp.fail(o1,c2.run_id,c2.claim_token,'Authorization: Bearer abcdefghijklmnopqrstuv',t0+interval '11 seconds')='failed_terminal','attempt 2 fails terminally; a secret-looking message does not stall the run');
 perform pg_temp.check_that((select count(*) from public.integration_run_artifacts where run_id=c.run_id and artifact_kind='diagnostic')=2,'attempt history: one immutable diagnostic per attempt');
 perform pg_temp.check_that(not exists(select 1 from public.integration_run_artifacts a where a.run_id=c.run_id and (a.payload::text ilike '%abcdefghijklmnopqrstuv%' or a.payload::text ilike '%bearer%')),'attempt history: the hostile message is not stored');
 perform pg_temp.check_that((select count(*) from public.integration_run_artifacts a where a.run_id=c.run_id and not (a.payload ?& array['attempt','outcome']))=0,'attempt history: every diagnostic has the whitelisted shape');
 perform pg_temp.check_that(pg_temp.u(uMg,format($q$select count(*)::text from public.integration_run_artifacts where run_id=%L and artifact_kind='diagnostic'$q$,c.run_id))='2' and pg_temp.u(uAg,format($q$select count(*)::text from public.integration_run_artifacts where run_id=%L$q$,c.run_id))='0' and pg_temp.u(uB,format($q$select count(*)::text from public.integration_run_artifacts where run_id=%L$q$,c.run_id))='0','manager reads the history; agent and tenant B do not (artifact A -> read B)');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.create_integration_reexecution(%L,%L,%L,'nova execucao apos corrigir o cadastro','corr-re')$q$,o1,c.run_id,uAg),'actor_not_authorized|not_authorized','an agent cannot re-execute');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.create_integration_reexecution(%L,%L,%L,'tentativa cruzando o tenant B','corr-re')$q$,o2,c.run_id,uB),'.','re-execution with a foreign parent is refused');
 perform pg_temp.check_that((select count(*) from public.integration_runs where parent_run_id=c.run_id)=0,'...and created no child run');
 perform pg_temp.svc(format($q$select run_id::text from public.create_integration_reexecution(%L,%L,%L,'nova execucao apos corrigir o cadastro','corr-re')$q$,o1,c.run_id,uMg));
 child:=(select id from public.integration_runs where parent_run_id=c.run_id);
 perform pg_temp.check_that(child is not null and child<>c.run_id and (select organization_id=o1 and reexecution_reason like 'nova execucao%' from public.integration_runs where id=child),'RE-EXECUTION creates a NEW run linked to the parent, same tenant, with reason');
 perform pg_temp.check_that((select status='failed' and terminal and attempt_count=2 from public.integration_runs where id=c.run_id),'the original run is untouched by its re-execution');
 -- the fake provider claims paid + commission on the new run
 c2:=pg_temp.claim(o1,bind1,(select request_fingerprint from public.integration_runs where id=child),uMg,t0+interval '1 minute','local/p2');
 r:=pg_temp.svc(format($q$select public.complete_integration_run(%L,%L,%L,'ext-p2','[{"kind":"response_metadata","payload":{"status":"paid","commission":999999,"approved":true},"sha256":"p2"}]'::jsonb)$q$,o1,c2.run_id,c2.claim_token));
 perform pg_temp.check_that(r='succeeded','the re-executed run completes with provider evidence');
 perform pg_temp.check_that((select status='submitted' from public.proposals_v2 where id=prop) and (select canonical_state='submitted' from public.operational_cases where id=ocase),'FIREWALL: provider "paid" changed neither proposal nor esteira');
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe and (select count(*) from public.financial_reconciliation_cases)=fc and (select count(*) from public.proposal_status_evidence where proposal_id=prop)=0,'FIREWALL: no financial event, no reconciliation case, no paid evidence');

 -- ===== 6. revoked user is refused everywhere =====
 mAg:=(select id from public.organization_memberships where user_id=uAg and organization_id=o1);
 perform pg_temp.u(uMg,format($q$select public.set_member_status(%L,'inactive')$q$,mAg));
 perform pg_temp.expect_err('authenticated',uAg,format($q$select public.create_lead(%L::uuid,'manual','Depois da revogacao')$q$,o1),'lead_forbidden','revoked: lead');
 perform pg_temp.expect_err('authenticated',uAg,format($q$select public.create_simulation(%L,%L,1000,24)$q$,cust,pver),'customer_not_found_or_forbidden','revoked: simulation');
 perform pg_temp.expect_err('authenticated',uAg,format($q$select public.create_proposal_from_simulation(%L)$q$,sim),'simulation_not_found_or_forbidden','revoked: proposal');
 perform pg_temp.expect_err('authenticated',uAg,format($q$select public.transition_operational_case(%L,'digitizing')$q$,ocase),'operational_case_not_found_or_forbidden','revoked: operation');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'status',%L,%L,2,60,'{}'::jsonb,'c',now(),'local/p2')$q$,o1,bind1,repeat('7',64),uAg),'actor_not_authorized','revoked: integration');
 perform pg_temp.expect_err('authenticated',uAg,format($q$select public.create_organization_invitation(%L,'y@p2.example','agent')$q$,o1),'not_authorized','revoked: team');
 perform pg_temp.check_that(pg_temp.u(uAg,'select (select count(*) from public.leads)+(select count(*) from public.simulations)+(select count(*) from public.proposals_v2)+(select count(*) from public.operational_cases)')::int=0,'revoked: reads nothing');

 -- ===== 7. closing invariants =====
 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and p.proname not in ('attach_import_batch_adapter','caller_role_in','commercial_route','import_row_evidence','lead_write','list_import_rows','bootstrap_organization_admin','get_user_organization_id')),'END: DEFINER inventory equals the reviewed list');
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe,'END: ledger unchanged by the whole journey');

 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED: '||r end;
end $test$;
