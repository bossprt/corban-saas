-- Rollback-only contract for 20260922_worker_governance_v1.sql. That migration is LIVE (worker_governance_v1): run this file as is.
-- Ends with RAISE EXCEPTION;
-- pass = 'RESULTS: ALL PASS'. Covers: esteira transition regression, proposals_v2 governance, customer timeline governance, enqueue /
-- dispatch selection, lease + fencing, re-execution lineage, cancel, and "provider says paid" isolation from financial truth.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid();
 uAg uuid:=gen_random_uuid(); uS uuid:=gen_random_uuid(); uM uuid:=gen_random_uuid(); uAd uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid(); uR uuid:=gen_random_uuid(); uN uuid:=gen_random_uuid();
 s1 uuid:=gen_random_uuid(); s2 uuid:=gen_random_uuid(); b1 uuid:=gen_random_uuid(); b2 uuid:=gen_random_uuid(); adp uuid:=gen_random_uuid();
 lead uuid; cust uuid; sim uuid:=gen_random_uuid(); ptab uuid:=gen_random_uuid(); pver uuid:=gen_random_uuid(); rt uuid:=gen_random_uuid(); prop uuid; case_id uuid;
 tpl uuid:=gen_random_uuid(); stq uuid:=gen_random_uuid(); std uuid:=gen_random_uuid(); sts uuid:=gen_random_uuid();
 fe int; fc int; r text; k int; c record; c2 record; hb text; t0 timestamptz:='2026-09-22 10:00:00+00';
 fa text:=repeat('a',64); fb text:=repeat('b',64); fc_ text:=repeat('c',64); fd text:=repeat('d',64); fe_ text:=repeat('e',64); ff text:=repeat('f',64); f1 text:=repeat('1',64);
 dt uuid:=gen_random_uuid(); rid1 uuid; rid2 uuid; rid3 uuid; child record; tokA uuid; tokB uuid; cust2 uuid;
 arts text:='[{"kind":"response_metadata","payload":{"status":"paid","commission":999999,"approved":true},"sha256":"w1"}]';
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
 create function pg_temp.forge_check(q text,pat text,label text) returns void language plpgsql as $f$
 declare msg text;
 begin
  perform set_config('corban.integration_run_rpc','on',true);
  begin execute q; msg:=null; exception when others then msg:=sqlerrm; end;
  perform set_config('corban.integration_run_rpc','off',true);
  if msg is null then insert into t_res values(label||' [UNEXPECTED SUCCESS]',false);
  elsif msg !~ pat then insert into t_res values(label||' [got: '||msg||']',false);
  else insert into t_res values(label,true); end if;
 end $f$;
 create function pg_temp.enq(p_org uuid,p_bind uuid,p_fp text,p_actor uuid,p_req text default '{"ref":"p1"}') returns record language plpgsql as $f$
 declare r record;
 begin
  perform pg_temp.as_role('service_role',null);
  begin select * into r from public.enqueue_integration_run(p_org,p_bind,'status',p_fp,p_actor,3,p_req::jsonb,'corr-w','local/wg'); exception when others then reset role; raise; end;
  reset role; return r;
 end $f$;
 create function pg_temp.claim(p_org uuid,p_bind uuid,p_fp text,p_actor uuid,p_now timestamptz,p_lease int default 60) returns record language plpgsql as $f$
 declare r record;
 begin
  perform pg_temp.as_role('service_role',null);
  begin select * into r from public.claim_integration_run(p_org,p_bind,'status',p_fp,p_actor,3,p_lease,'{"ref":"p1"}'::jsonb,'corr-w',p_now,'local/wg'); exception when others then reset role; raise; end;
  reset role; return r;
 end $f$;
 create function pg_temp.claim_o(p_org uuid,p_bind uuid,p_fp text,p_actor uuid,p_now timestamptz) returns text language plpgsql as $f$
 declare r record;
 begin r:=pg_temp.claim(p_org,p_bind,p_fp,p_actor,p_now); return r.outcome; end $f$;
 create function pg_temp.disp(p_now timestamptz) returns text language plpgsql as $f$
 declare r text;
 begin
  perform pg_temp.as_role('service_role',null);
  begin select coalesce(string_agg(x.fingerprint,',' order by x.fingerprint),'') into r from public.list_dispatchable_integration_runs(50,p_now) x; exception when others then reset role; raise; end;
  reset role; return r;
 end $f$;

 insert into auth.users(id) values(uAg),(uS),(uM),(uAd),(uB),(uR),(uN);
 insert into public.organizations(id,name,document) values(o1,'WG-A','doc-'||o1),(o2,'WG-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role,status) values(o1,uAg,'agent','active'),(o1,uS,'supervisor','active'),(o1,uM,'manager','active'),(o1,uAd,'admin','active'),(o2,uB,'admin','active'),(o1,uR,'admin','revoked');
 select count(*) into fe from public.financial_events; select count(*) into fc from public.financial_reconciliation_cases;

 -- ===== fixtures: lead -> customer -> simulation -> proposal =====
 lead:=pg_temp.u(uAg,format($q$select public.create_lead(%L::uuid,'whatsapp','Cliente Worker','5511900000001',null,'wg','wa-wg-1')::text$q$,o1))::uuid;
 cust:=pg_temp.u(uAg,format($q$select public.convert_lead_to_customer(%L,'11122233344')::text$q$,lead))::uuid;
 perform pg_temp.check_that((select count(*) from public.customer_timeline_events where customer_id=cust and event_type='customer.created')=1,'lead conversion still writes its timeline event (definer owner path unaffected)');
 insert into public.document_types(id,code,name) values(dt,'wg-'||dt,'WG doc');
 set local session_replication_role='replica';
 insert into public.product_tables(id,organization_id,route_id,code,name,status) values(ptab,o1,rt,'T-WG','Tabela WG','active');
 insert into public.product_table_versions(id,organization_id,product_table_id,version,status,rate,coefficient,published_at) values(pver,o1,ptab,1,'published',1.5,0.02,now());
 insert into public.simulations(id,organization_id,customer_id,product_table_version_id,status,requested_amount,released_amount,installment_amount,term,rate,coefficient,expected_commission_amount) values(sim,o1,cust,pver,'calculated',10000,9500,400,36,1.5,0.02,500);
 insert into public.operational_stages(id,organization_id,code,name,canonical_state,sort_order,sla_minutes,is_active) values(stq,o1,'q','Fila','digitization_queue',0,60,true),(std,o1,'d','Digitando','digitizing',1,60,true),(sts,o1,'s','Enviada','submitted',2,60,true);
 insert into public.document_checklist_templates(id,organization_id,route_id,version,status,name,published_at) values(tpl,o1,rt,1,'published','chk',now());
 insert into public.document_checklist_items(organization_id,template_id,document_type_id,label,is_required,sort_order) values(o1,tpl,dt,'RG',true,0);
 set local session_replication_role='origin';

 -- ===== proposals_v2 governance =====
 prop:=pg_temp.u(uS,format($q$select public.create_proposal_from_simulation(%L)::text$q$,sim))::uuid;
 perform pg_temp.check_that((select status='draft' and created_by=uS from public.proposals_v2 where id=prop),'governed RPC still creates proposals (token path)');
 r:=pg_temp.u(uS,format($q$select public.prepare_proposal_documents(%L)::text$q$,prop));
 perform pg_temp.check_that(r='1' and (select status='documents_pending' from public.proposals_v2 where id=prop),'prepare_proposal_documents still moves the status (token path)');
 for k in 1..4 loop
  perform pg_temp.expect_err('authenticated',(array[uAg,uS,uM,uAd])[k],format($q$update public.proposals_v2 set expected_commission_amount=999999 where id=%L$q$,prop),'proposal_write_requires_governed_rpc','no member role can rewrite proposal commission by direct UPDATE ('||k||')');
  perform pg_temp.expect_err('authenticated',(array[uAg,uS,uM,uAd])[k],format($q$update public.proposals_v2 set status='cancelled' where id=%L$q$,prop),'proposal_write_requires_governed_rpc','no member role can change proposal status by direct UPDATE ('||k||')');
  perform pg_temp.expect_err('authenticated',(array[uAg,uS,uM,uAd])[k],format($q$update public.proposals_v2 set organization_id=%L where id=%L$q$,o2,prop),'proposal_write_requires_governed_rpc','no member role can move a proposal to another tenant ('||k||')');
  perform pg_temp.expect_err('authenticated',(array[uAg,uS,uM,uAd])[k],format($q$update public.proposals_v2 set simulation_id=gen_random_uuid(),created_by=%L where id=%L$q$,uAg,prop),'proposal_write_requires_governed_rpc','no member role can repoint simulation or forge created_by ('||k||')');
  perform pg_temp.expect_err('authenticated',(array[uAg,uS,uM,uAd])[k],'delete from public.proposals_v2','permission denied','no member role can DELETE proposals ('||k||')');
 end loop;
 perform pg_temp.expect_err('authenticated',uAd,format($q$update public.proposals_v2 set commercial_snapshot='{}' where id=%L$q$,prop),'proposal_write_requires_governed_rpc','commercial snapshot column cannot be rewritten directly');
 perform pg_temp.expect_err('authenticated',uS,format($q$update public.proposals_v2 set customer_id=%L where id=%L$q$,gen_random_uuid(),prop),'proposal_write_requires_governed_rpc','customer_id cannot be repointed directly');
 perform pg_temp.expect_err('authenticated',uS,format($q$insert into public.proposals_v2(organization_id,customer_id,product_table_version_id,customer_snapshot,commercial_snapshot,status) values(%L,%L,%L,'{}','{}','approved')$q$,o1,cust,pver),'proposal_write_requires_governed_rpc','direct INSERT of a proposal (even pre-approved) is impossible');
 perform pg_temp.expect_err('service_role',null,format($q$update public.proposals_v2 set status='approved' where id=%L$q$,prop),'proposal_write_requires_governed_rpc','the worker role cannot write proposals directly either');
 perform pg_temp.check_that(pg_temp.u(uB,format($q$with u as (update public.proposals_v2 set status='cancelled' where id=%L returning 1) select count(*)::text from u$q$,prop))='0','tenant B update of a tenant A proposal by known UUID touches nothing');
 perform pg_temp.check_that(pg_temp.u(uN,format($q$with u as (update public.proposals_v2 set status='cancelled' where id=%L returning 1) select count(*)::text from u$q$,prop))='0' and pg_temp.u(uR,format($q$with u as (update public.proposals_v2 set status='cancelled' where id=%L returning 1) select count(*)::text from u$q$,prop))='0','no-membership and revoked users touch nothing');
 perform pg_temp.expect_err('anon',null,format($q$update public.proposals_v2 set status='cancelled' where id=%L$q$,prop),'permission denied','anon cannot write proposals');
 perform pg_temp.expect_err('anon',null,'delete from public.proposals_v2','permission denied','anon cannot delete proposals');
 begin
  perform set_config('corban.proposal_rpc','on',true);
  update public.proposals_v2 set customer_id=gen_random_uuid() where id=prop;
  perform pg_temp.check_that(false,'identity immutability must hold even with the token');
 exception when others then perform pg_temp.check_that(sqlerrm ~ 'proposal_identity_is_immutable','proposal identity columns are immutable even with the governed token'); end;
 perform set_config('corban.proposal_rpc','off',true);
 perform pg_temp.check_that((select status='documents_pending' and expected_commission_amount=500 from public.proposals_v2 where id=prop),'after every attack the proposal is unchanged');

 -- ===== esteira transition regression (LIVE 20260921 hardening broke transition_operational_case) =====
 set local session_replication_role='replica';
 update public.proposals_v2 set status='ready_for_digitization' where id=prop;
 update public.proposal_document_requirements set status='validated' where proposal_id=prop;
 set local session_replication_role='origin';
 perform pg_temp.u(uS,format($q$select public.send_proposal_to_digitization(%L)::text$q$,prop));
 select id into case_id from public.operational_cases where proposal_id=prop;
 perform pg_temp.check_that((select status='digitization' from public.proposals_v2 where id=prop),'send_proposal_to_digitization works with the proposal token');
 perform pg_temp.check_that((select count(*) from public.operational_events where operational_case_id=case_id)=1,'send_proposal_to_digitization wrote its esteira event');
 perform pg_temp.check_that(pg_temp.u(uAg,format($q$select public.transition_operational_case(%L,'digitizing')$q$,case_id))='digitizing','agent can move a case to digitizing through the governed RPC');
 perform pg_temp.check_that((select canonical_state='digitizing' from public.operational_cases where id=case_id) and (select status='in_progress' from public.digitization_jobs where proposal_id=prop) and (select count(*) from public.operational_events where operational_case_id=case_id)=2,'transition updates case, job and history atomically');
 perform pg_temp.expect_err('authenticated',uAg,format($q$select public.transition_operational_case(%L,'approved')$q$,case_id),'invalid_operational_state_transition|operational_decision_requires_privileged_role','agent still cannot take a privileged decision');
 perform pg_temp.expect_err('authenticated',uS,format($q$select public.transition_operational_case(%L,'paid')$q$,case_id),'paid_requires_confirmed_financial_source','no RPC path to paid on the esteira');
 perform pg_temp.expect_err('authenticated',uS,format($q$select public.transition_operational_case(%L,'digitization_queue')$q$,case_id),'invalid_operational_state_transition','backwards transition is invalid');
 perform pg_temp.expect_err('authenticated',uB,format($q$select public.transition_operational_case(%L,'submitted')$q$,case_id),'operational_case_not_found_or_forbidden','tenant B cannot transition a tenant A case by UUID');
 r:=pg_temp.u(uS,format($q$select public.transition_operational_case(%L,'submitted','synthetic-status')$q$,case_id));
 perform pg_temp.check_that(r='submitted' and (select status='submitted' from public.proposals_v2 where id=prop),'supervisor transition to submitted moves the proposal too');
 perform pg_temp.expect_err('authenticated',uAd,format($q$update public.operational_cases set canonical_state='paid' where id=%L$q$,case_id),'operational_write_requires_governed_rpc','direct esteira UPDATE still blocked');
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe,'esteira transitions create no financial truth');

 -- ===== customer timeline governance =====
 for k in 1..4 loop
  perform pg_temp.expect_err('authenticated',(array[uAg,uS,uM,uAd])[k],format($q$insert into public.customer_timeline_events(organization_id,customer_id,event_type,source) values(%L,%L,'customer.paid','corban_os')$q$,o1,cust),'timeline_write_requires_governed_rpc','no member role can forge a timeline event ('||k||')');
  perform pg_temp.expect_err('authenticated',(array[uAg,uS,uM,uAd])[k],format($q$insert into public.customer_timeline_events(organization_id,customer_id,event_type,source,actor_user_id) values(%L,%L,'proposal.approved','corban_os',%L)$q$,o1,cust,uAd),'timeline_write_requires_governed_rpc','no member role can forge a proposal event with a forged actor ('||k||')');
 end loop;
 perform pg_temp.expect_err('authenticated',uB,format($q$insert into public.customer_timeline_events(organization_id,customer_id,event_type,source) values(%L,%L,'x','corban_os')$q$,o1,cust),'timeline_write_requires_governed_rpc|row-level security','tenant B cannot write a timeline on a tenant A customer UUID');
 perform pg_temp.expect_err('authenticated',uB,format($q$insert into public.customer_timeline_events(organization_id,customer_id,event_type,source) values(%L,%L,'x','corban_os')$q$,o2,cust),'timeline_write_requires_governed_rpc|row-level security|violates foreign key','tenant B cannot attach an event to a foreign customer under its own org');
 perform pg_temp.expect_err('authenticated',uR,format($q$insert into public.customer_timeline_events(organization_id,customer_id,event_type,source) values(%L,%L,'x','corban_os')$q$,o1,cust),'timeline_write_requires_governed_rpc|row-level security','revoked membership cannot write a timeline');
 perform pg_temp.expect_err('anon',null,format($q$insert into public.customer_timeline_events(organization_id,customer_id,event_type,source) values(%L,%L,'x','corban_os')$q$,o1,cust),'permission denied','anon cannot write a timeline');
 perform pg_temp.expect_err('service_role',null,format($q$insert into public.customer_timeline_events(organization_id,customer_id,event_type,source) values(%L,%L,'x','corban_os')$q$,o1,cust),'timeline_write_requires_governed_rpc','the worker role cannot write a timeline directly');
 perform pg_temp.expect_err('authenticated',uAd,'update public.customer_timeline_events set event_type=''x''','permission denied','no UPDATE privilege on the timeline');
 perform pg_temp.expect_err('authenticated',uAd,'delete from public.customer_timeline_events','permission denied','no DELETE privilege on the timeline');
 begin update public.customer_timeline_events set event_type='rewritten' where customer_id=cust; perform pg_temp.check_that(false,'timeline UPDATE must fail even for the owner');
 exception when others then perform pg_temp.check_that(sqlerrm ~ 'append_only','timeline is append-only even for owner-level UPDATE'); end;
 cust2:=pg_temp.u(uAg,format($q$select public.create_customer_with_timeline(%L::uuid,'Cliente Dois','55566677788')::text$q$,o1))::uuid;
 perform pg_temp.check_that((select count(*) from public.customer_timeline_events where customer_id=cust2 and actor_user_id=uAg)=1,'create_customer_with_timeline still records the event with the real actor');
 perform pg_temp.expect_err('authenticated',uB,format($q$select public.create_customer_with_timeline(%L::uuid,'Cross','99988877766')$q$,o1),'active_membership_required','tenant B cannot create a customer (and timeline) in tenant A');

 -- ===== worker support: enqueue =====
 insert into public.import_sources(id,organization_id,name,source_kind) values(s1,o1,'src wg','manual'),(s2,o2,'src wg b','manual');
 insert into public.integration_adapters(id,adapter_key,provider_key,transport,name,contract_version,capabilities) values(adp,'local/wg','local','api','fake wg','1.0.0','["submit","status"]');
 insert into public.integration_source_bindings(id,organization_id,source_id,adapter_id) values(b1,o1,s1,adp),(b2,o2,s2,adp);
 perform pg_temp.expect_err('authenticated',uS,format($q$select * from public.enqueue_integration_run(%L,%L,'status',%L,%L,3,'{}'::jsonb,'c')$q$,o1,b1,fa,uS),'permission denied','authenticated cannot call enqueue_integration_run');
 perform pg_temp.expect_err('authenticated',uS,format($q$select * from public.list_dispatchable_integration_runs(10)$q$),'permission denied','authenticated cannot list dispatchable runs');
 perform pg_temp.expect_err('anon',null,format($q$select * from public.create_integration_reexecution(%L,%L,%L,'a valid reason here','c')$q$,o1,gen_random_uuid(),uM),'permission denied','anon cannot call create_integration_reexecution');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.enqueue_integration_run(%L,%L,'status',%L,%L,3,'{}'::jsonb,'c')$q$,o1,b1,fa,uAg),'actor_not_authorized','agent cannot enqueue');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.enqueue_integration_run(%L,%L,'status',%L,%L,3,'{}'::jsonb,'c')$q$,o1,b1,fa,uR),'actor_not_authorized','revoked membership cannot enqueue');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.enqueue_integration_run(%L,%L,'status',%L,%L,3,'{}'::jsonb,'c')$q$,o1,b1,fa,uB),'actor_not_authorized','tenant B cannot enqueue in tenant A');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.enqueue_integration_run(%L,%L,'status',%L,%L,3,'{}'::jsonb,'c')$q$,o1,b2,fa,uS),'binding_not_found','tenant B binding UUID under tenant A is not found');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.enqueue_integration_run(%L,%L,'status',%L,%L,3,'{}'::jsonb,'c','x/y')$q$,o1,b1,fa,uS),'adapter_mismatch','adapter key mismatch refused at enqueue');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.enqueue_integration_run(%L,%L,'status',%L,%L,3,'{"password":"hunter2hunter2"}'::jsonb,'c')$q$,o1,b1,fa,uS),'secret_like_content','secret in the request is rejected by the database');
 c:=pg_temp.enq(o1,b1,fa,uS); rid1:=c.run_id;
 perform pg_temp.check_that(c.status='queued' and c.created,'supervisor enqueues a queued run');
 c2:=pg_temp.enq(o1,b1,fa,uM);
 perform pg_temp.check_that(c2.run_id=rid1 and not c2.created,'enqueue is idempotent (same fingerprint = same run)');
 perform pg_temp.check_that((select count(*) from public.integration_runs)=1 and (select status='queued' and attempt_count=0 from public.integration_runs where id=rid1),'enqueue creates exactly one queued run with zero attempts');

 -- ===== dispatch selection =====
 perform pg_temp.check_that(pg_temp.disp(t0)=fa,'queued run is dispatchable');
 c:=pg_temp.claim(o1,b1,fa,uS,t0);
 tokA:=c.claim_token;
 perform pg_temp.check_that(c.outcome='claimed' and pg_temp.disp(t0+interval '30 seconds')='','running with a valid lease is NOT dispatchable (B cannot execute)');
 perform pg_temp.check_that(pg_temp.claim_o(o1,b1,fa,uM,t0+interval '30 seconds')='in_progress','worker B claim while the lease is valid gets in_progress');
 perform pg_temp.check_that(pg_temp.disp(t0+interval '61 seconds')=fa,'running with an EXPIRED lease becomes dispatchable');
 c2:=pg_temp.claim(o1,b1,fa,uM,t0+interval '61 seconds'); tokB:=c2.claim_token;
 perform pg_temp.check_that(c2.outcome='takeover' and c2.attempt_count=2 and tokB<>tokA,'worker B takes over with a NEW fencing token');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.complete_integration_run(%L,%L,%L,'ext-old',%L::jsonb)$q$,o1,rid1,tokA,arts))='lease_lost','old worker returning later is fenced (result rejected)');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.complete_integration_run(%L,%L,%L,'ext-new',%L::jsonb)$q$,o1,rid1,tokB,arts))='succeeded','worker B completes; provider payload says paid');
 perform pg_temp.check_that(pg_temp.disp(t0+interval '1 day')='' and pg_temp.claim_o(o1,b1,fa,uS,t0+interval '1 day')='replayed','succeeded run is neither dispatchable nor re-executed (replay)');
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe and (select count(*) from public.financial_reconciliation_cases)=fc and (select status='submitted' from public.proposals_v2 where id=prop),'provider "paid" moved no proposal, wrote no ledger event and resolved no reconciliation');
 perform pg_temp.check_that((select count(*) from public.proposal_status_evidence where proposal_id=prop)=0,'provider "paid" fabricated no status evidence');

 -- retry due / backoff / terminal / disabled binding
 c:=pg_temp.enq(o1,b1,fb,uS); rid2:=c.run_id;
 c2:=pg_temp.claim(o1,b1,fb,uS,t0);
 perform pg_temp.svc(format($q$select public.fail_integration_run(%L,%L,%L,'timeout','x',true,30,%L)$q$,o1,rid2,c2.claim_token,t0));
 perform pg_temp.check_that(pg_temp.disp(t0+interval '29 seconds')='' and pg_temp.disp(t0+interval '30 seconds')=fb,'retryable failure is dispatchable only once its backoff elapsed');
 c2:=pg_temp.claim(o1,b1,fb,uS,t0+interval '31 seconds');
 perform pg_temp.svc(format($q$select public.fail_integration_run(%L,%L,%L,'bad','permanent',false,0,%L)$q$,o1,rid2,c2.claim_token,t0+interval '32 seconds'));
 perform pg_temp.check_that(pg_temp.disp(t0+interval '1 day')='','terminal failure is never dispatchable');
 c:=pg_temp.enq(o1,b1,fc_,uS);
 update public.integration_source_bindings set enabled=false where id=b1;
 perform pg_temp.check_that(pg_temp.disp(t0)='','runs of a disabled binding are not dispatchable');
 update public.integration_source_bindings set enabled=true where id=b1;
 c:=pg_temp.enq(o2,b2,fa,uB);
 perform pg_temp.check_that(pg_temp.disp(t0) like '%'||fc_||'%' and (select count(*) from public.list_dispatchable_integration_runs(50,t0))=2,'each tenant work item is listed with its own organization');
 perform pg_temp.check_that((select bool_and(organization_id=(select ir.organization_id from public.integration_runs ir where ir.id=x.run_id)) from public.list_dispatchable_integration_runs(50,t0) x),'dispatch rows carry the run''s own tenant (never derived by LIMIT 1)');

 -- ===== re-execution lineage =====
 hb:=(select md5(ir::text) from public.integration_runs ir where id=rid2);
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.create_integration_reexecution(%L,%L,%L,'operator fixed the payload','c')$q$,o1,rid2,uS),'actor_not_authorized','supervisor cannot re-execute (manager+)');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.create_integration_reexecution(%L,%L,%L,'operator fixed the payload','c')$q$,o1,rid2,uAg),'actor_not_authorized','agent cannot re-execute');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.create_integration_reexecution(%L,%L,%L,'operator fixed the payload','c')$q$,o1,rid2,uR),'actor_not_authorized','revoked admin cannot re-execute');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.create_integration_reexecution(%L,%L,%L,'operator fixed the payload','c')$q$,o2,rid2,uB),'run_not_found','tenant B cannot re-execute a tenant A run by UUID');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.create_integration_reexecution(%L,%L,%L,'short','c')$q$,o1,rid2,uM),'reexecution_reason_length_invalid','reason is mandatory (10..500)');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.create_integration_reexecution(%L,%L,%L,'reason with password=hunter2hunter2','c')$q$,o1,rid2,uM),'secret_like_content','reason with a secret is rejected');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.create_integration_reexecution(%L,%L,%L,'run again please, retry not allowed','c')$q$,o1,rid1,uM),'parent_not_reexecutable','a SUCCEEDED run cannot be re-executed');
 c:=pg_temp.enq(o1,b1,fd,uS);
 c2:=pg_temp.claim(o1,b1,fd,uS,t0);
 perform pg_temp.expect_err('service_role',null,format($q$select public.cancel_integration_run(%L,%L,%L)$q$,o1,c.run_id,uM),'illegal_integration_run_transition','a RUNNING run cannot be cancelled (explicit)');
 perform pg_temp.svc(format($q$select public.fail_integration_run(%L,%L,%L,'timeout','x',true,30,%L)$q$,o1,c.run_id,c2.claim_token,t0));
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.create_integration_reexecution(%L,%L,%L,'skip the governed backoff please','c')$q$,o1,c.run_id,uM),'parent_not_reexecutable','a still-retryable run must use RETRY, not re-execution');
 perform pg_temp.svc(format($q$select run_id::text||'|'||fingerprint||'|'||created::text from public.create_integration_reexecution(%L,%L,%L,'operator fixed the payload','ui-1')$q$,o1,rid2,uM));
 select ir.id into rid3 from public.integration_runs ir where ir.parent_run_id=rid2;
 perform pg_temp.check_that(rid3 is not null and (select status='queued' and attempt_count=0 and reexecution_reason='operator fixed the payload' and binding_id=b1 and adapter_id=adp and created_by=uM and request_fingerprint<>fb and correlation_id='ui-1' from public.integration_runs where id=rid3),'re-execution creates a NEW queued run with lineage, reason, actor and a new fingerprint');
 perform pg_temp.check_that((select md5(ir::text) from public.integration_runs ir where id=rid2)=hb,'the parent run is byte-for-byte unchanged (history preserved)');
 perform pg_temp.check_that(pg_temp.svc(format($q$select created::text from public.create_integration_reexecution(%L,%L,%L,'operator fixed the payload','ui-1')$q$,o1,rid2,uM))='false' and (select count(*) from public.integration_runs where parent_run_id=rid2)=1,'re-execution is idempotent per parent');
 perform pg_temp.check_that(exists(select 1 from public.integration_runs where id=rid3 and request_fingerprint=encode(extensions.digest(fb||':reexec:'||rid2::text,'sha256'),'hex')),'child fingerprint is deterministic from the parent');
 perform pg_temp.check_that(pg_temp.disp(t0) like '%'||(select request_fingerprint from public.integration_runs where id=rid3)||'%','the child is dispatchable like any queued run');
 perform pg_temp.check_that(pg_temp.claim_o(o1,b1,(select request_fingerprint from public.integration_runs where id=rid3),uS,t0)='claimed','the child is claimed through the normal governed path');
 perform pg_temp.forge_check(format($q$update public.integration_runs set parent_run_id=%L where id=%L$q$,rid1,rid3),'integration_run_identity_is_immutable','lineage cannot be rewritten');
 perform pg_temp.forge_check(format($q$update public.integration_runs set reexecution_reason='rewritten history reason' where id=%L$q$,rid3),'integration_run_identity_is_immutable','re-execution reason cannot be rewritten');
 perform pg_temp.forge_check(format($q$insert into public.integration_runs(organization_id,binding_id,adapter_id,capability,status,request_fingerprint,parent_run_id,reexecution_reason) select %L,binding_id,adapter_id,capability,'queued',%L,%L,'cross tenant parent attempt' from public.integration_runs where id=%L$q$,o2,f1,rid1,rid1),'integration_run_parent_tenant_mismatch|invalid or disabled integration binding','a run cannot point at a parent of another tenant');
 perform pg_temp.forge_check(format($q$insert into public.integration_runs(organization_id,binding_id,adapter_id,capability,status,request_fingerprint,parent_run_id,reexecution_reason) select organization_id,binding_id,adapter_id,capability,'queued',%L,%L,'second child same parent' from public.integration_runs where id=%L$q$,ff,rid2,rid2),'duplicate key|integration_runs_parent_uidx','a parent can have only one child');
 perform pg_temp.forge_check(format($q$update public.integration_runs set parent_run_id=id where id=%L$q$,rid3),'integration_run_identity_is_immutable|not_own_parent','a run cannot be its own parent');

 -- ===== cancel keeps governing =====
 c:=pg_temp.enq(o1,b1,fe_,uS);
 perform pg_temp.expect_err('service_role',null,format($q$select public.cancel_integration_run(%L,%L,%L)$q$,o1,c.run_id,uS),'actor_not_authorized','supervisor cannot cancel');
 perform pg_temp.check_that(pg_temp.svc(format($q$select public.cancel_integration_run(%L,%L,%L)$q$,o1,c.run_id,uM))='cancelled' and pg_temp.disp(t0+interval '1 day') not like '%'||fe_||'%','manager cancels; a cancelled run is not dispatchable');
 perform pg_temp.check_that((select status='cancelled' and finished_at is not null from public.integration_runs where id=c.run_id),'cancellation is recorded on the run itself (auditable, not deleted)');
 perform pg_temp.expect_err('service_role',null,format($q$select public.cancel_integration_run(%L,%L,%L)$q$,o1,c.run_id,uM),'illegal_integration_run_transition','cancelling twice is an explicit error, not silent');
 perform pg_temp.expect_err('service_role',null,format($q$select public.cancel_integration_run(%L,%L,%L)$q$,o1,rid1,uM),'illegal_integration_run_transition','a SUCCEEDED run cannot be cancelled');
 perform pg_temp.expect_err('service_role',null,format($q$select public.cancel_integration_run(%L,%L,%L)$q$,o1,rid2,uM),'illegal_integration_run_transition','a terminally FAILED run cannot be cancelled to hide it');
 perform pg_temp.check_that(pg_temp.svc(format($q$select created::text from public.create_integration_reexecution(%L,%L,%L,'cancelled by mistake, run it again','ui-2')$q$,o1,c.run_id,uAd))='true','a cancelled run can only be superseded by a re-execution, never reopened');

 -- ===== read RBAC over lineage columns / no financial dependency =====
 perform pg_temp.check_that(pg_temp.u(uAg,'select count(*)::text from public.integration_runs')='0','agent sees no runs (incl. lineage)');
 perform pg_temp.check_that(pg_temp.u(uB,format($q$select count(*)::text from public.integration_runs where id in (%L,%L)$q$,rid1,rid3))='0','tenant B cannot see tenant A runs by UUID');
 perform pg_temp.check_that(pg_temp.u(uM,format($q$select count(*)::text from public.integration_runs where id=%L and parent_run_id=%L$q$,rid3,rid2))='1','manager can read the lineage');
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe and (select count(*) from public.financial_reconciliation_cases)=fc,'END: the whole worker/governance flow left the ledger and reconciliation untouched');

 -- ===== function surface =====
 perform pg_temp.check_that(not exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('enqueue_integration_run','list_dispatchable_integration_runs','create_integration_reexecution','guard_proposal_write','guard_customer_timeline_write','transition_operational_case','create_proposal_from_simulation','prepare_proposal_documents','send_proposal_to_digitization','create_customer_with_timeline') and p.prosecdef),'no new or changed function is SECURITY DEFINER');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('enqueue_integration_run','list_dispatchable_integration_runs','create_integration_reexecution') and (has_function_privilege('authenticated',p.oid,'EXECUTE') or has_function_privilege('anon',p.oid,'EXECUTE'))),'worker functions: no authenticated/anon execute');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p,lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a where p.pronamespace='public'::regnamespace and p.proname in ('enqueue_integration_run','list_dispatchable_integration_runs','create_integration_reexecution') and a.grantee=0),'worker functions: not executable by PUBLIC');
 perform pg_temp.check_that((select bool_and(has_function_privilege('service_role',p.oid,'EXECUTE')) from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('enqueue_integration_run','list_dispatchable_integration_runs','create_integration_reexecution')),'worker functions: service_role can execute');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and p.proname not in ('attach_import_batch_adapter','caller_role_in','commercial_route','import_row_evidence','lead_write','list_import_rows','bootstrap_organization_admin','get_user_organization_id')),'DEFINER inventory equals the reviewed list (nothing new)');

 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %
%',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED' end,case when k=0 then '' else r end;
end $test$;
