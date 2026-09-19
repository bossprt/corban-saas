-- Pilot E2E, rollback-only: the day-one journey of a promotora, driven through the same RPCs and RLS the product uses.
-- admin invites the team -> invitees accept -> operator works lead -> customer -> (simulation) -> supervisor proposal -> esteira ->
-- integration run (fake provider CLAIMING "paid" and commission 999999) -> manager reads the numbers the dashboard shows ->
-- admin deactivates the supervisor MID-FLOW and the very next action is refused -> reactivation -> financial truth untouched.
-- Needs migration 20260925_team_access_lifecycle_v1: run its text first in the same transaction until it is LIVE. Ends with RAISE EXCEPTION.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid();
 uAd uuid:=gen_random_uuid(); uOp uuid:=gen_random_uuid(); uSv uuid:=gen_random_uuid(); uMg uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid(); uNew uuid:=gen_random_uuid();
 s1 uuid:=gen_random_uuid(); bind1 uuid:=gen_random_uuid(); adp uuid:=gen_random_uuid(); ptab uuid:=gen_random_uuid(); pver uuid:=gen_random_uuid(); sim uuid:=gen_random_uuid();
 st1 uuid:=gen_random_uuid(); st2 uuid:=gen_random_uuid(); st3 uuid:=gen_random_uuid(); st4 uuid:=gen_random_uuid();
 lead uuid; cust uuid; prop uuid; job uuid; ocase uuid; mSv uuid; fe int; fc int; r text; k int; c record; t0 timestamptz:='2026-09-24 10:00:00+00';
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
  select pg_temp.run_as('service_role',null,format($q$select coalesce(string_agg(x.outcome||':'||x.role,','),'') from public.accept_organization_invitations(%L,%L) x$q$,p_uid,p_email)) $f$;
 create function pg_temp.claim(p_org uuid,p_bind uuid,p_fp text,p_actor uuid,p_now timestamptz) returns record language plpgsql as $f$
 declare r record;
 begin
  perform pg_temp.as_role('service_role',null);
  begin select * into r from public.claim_integration_run(p_org,p_bind,'status',p_fp,p_actor,3,60,'{"proposal":"redacted-ref"}'::jsonb,'corr-pilot',p_now,'local/pilot'); exception when others then reset role; raise; end;
  reset role; return r;
 end $f$;

 -- fixtures: the organization exists and has one admin (PLATFORM BOOTSTRAP is not what is under test); everyone else joins by invitation
 insert into auth.users(id) values(uAd),(uOp),(uSv),(uMg),(uB),(uNew);
 insert into public.organizations(id,name,document) values(o1,'PILOTO-A','doc-'||o1),(o2,'PILOTO-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role,status) values(o1,uAd,'admin','active'),(o2,uB,'admin','active');
 set local session_replication_role='replica';
 insert into public.product_tables(id,organization_id,route_id,code,name,status) values(ptab,o1,gen_random_uuid(),'T-PILOT','Tabela sintetica','active');
 insert into public.product_table_versions(id,organization_id,product_table_id,version,status,rate,coefficient,published_at) values(pver,o1,ptab,1,'published',1.5,0.02,now());
 insert into public.operational_stages(id,organization_id,code,name,canonical_state,sort_order,sla_minutes,is_active) values(st1,o1,'dq','Fila','digitization_queue',0,60,true),(st2,o1,'dg','Digitando','digitizing',1,60,true),(st3,o1,'sb','Enviada','submitted',2,60,true),(st4,o1,'ap','Aprovada','approved',3,60,true);
 set local session_replication_role='origin';
 select count(*) into fe from public.financial_events; select count(*) into fc from public.financial_reconciliation_cases;

 -- ===== 1. ADMIN builds the team =====
 perform pg_temp.check_that(pg_temp.u(uAd,format($q$select public.create_organization_invitation(%L,'operador@pilot.example','agent')::text$q$,o1)) is not null,'admin invites the operator');
 perform pg_temp.check_that(pg_temp.u(uAd,format($q$select public.create_organization_invitation(%L,'supervisor@pilot.example','supervisor')::text$q$,o1)) is not null,'admin invites the supervisor');
 perform pg_temp.check_that(pg_temp.u(uAd,format($q$select public.create_organization_invitation(%L,'gerente@pilot.example','manager')::text$q$,o1)) is not null,'admin invites the manager');
 perform pg_temp.check_that(pg_temp.accept(uOp,'operador@pilot.example')='joined:agent','operator accepts (joins as agent)');
 perform pg_temp.check_that(pg_temp.accept(uSv,'supervisor@pilot.example')='joined:supervisor','supervisor accepts');
 perform pg_temp.check_that(pg_temp.accept(uMg,'gerente@pilot.example')='joined:manager','manager accepts');
 perform pg_temp.check_that(pg_temp.accept(uNew,'operador@pilot.example')='','a stranger cannot reuse an accepted invitation');
 perform pg_temp.check_that(pg_temp.u(uNew,'select count(*)::text from public.leads')='0' and pg_temp.u(uNew,'select count(*)::text from public.organizations')='0','FIRST LOGIN of a user without membership: sees nothing (the app routes to access-pending)');
 perform pg_temp.check_that(pg_temp.u(uOp,'select count(*)::text from public.organization_memberships')='1','the invited operator sees only their own membership');
 perform pg_temp.expect_err('authenticated',uOp,format($q$select public.create_organization_invitation(%L,'x@pilot.example','agent')$q$,o1),'not_authorized','operator cannot invite');
 perform pg_temp.expect_err('authenticated',uSv,format($q$select public.create_organization_invitation(%L,'x@pilot.example','agent')$q$,o1),'not_authorized','supervisor cannot invite');
 perform pg_temp.expect_err('authenticated',uMg,format($q$select public.create_organization_invitation(%L,'x@pilot.example','admin')$q$,o1),'role_change_not_permitted','manager cannot invite an admin');
 perform pg_temp.expect_err('authenticated',uB,format($q$select public.create_organization_invitation(%L,'x@pilot.example','agent')$q$,o1),'not_authorized','admin of another organization cannot invite here');

 -- ===== 2. OPERATOR: lead -> customer =====
 lead:=pg_temp.u(uOp,format($q$select public.create_lead(%L::uuid,'whatsapp','Cliente Piloto','5511900000001',null,'camp-pilot','wa-pilot-1')::text$q$,o1))::uuid;
 cust:=pg_temp.u(uOp,format($q$select public.convert_lead_to_customer(%L,'11122233344')::text$q$,lead))::uuid;
 perform pg_temp.check_that((select organization_id=o1 from public.clients where id=cust),'the invited operator created a lead and converted it inside the organization');
 set local session_replication_role='replica';
 insert into public.simulations(id,organization_id,customer_id,product_table_version_id,status,requested_amount,released_amount,installment_amount,term,rate,coefficient,expected_commission_amount) values(sim,o1,cust,pver,'calculated',10000,9500,400,36,1.5,0.02,500);
 set local session_replication_role='origin';

 -- ===== 3. SUPERVISOR: proposal -> esteira =====
 prop:=pg_temp.u(uSv,format($q$select public.create_proposal_from_simulation(%L)::text$q$,sim))::uuid;
 perform pg_temp.check_that((select status='draft' from public.proposals_v2 where id=prop),'supervisor creates the proposal (draft)');
 set local session_replication_role='replica';
 update public.proposals_v2 set status='ready_for_digitization' where id=prop;
 set local session_replication_role='origin';
 job:=pg_temp.u(uSv,format($q$select public.send_proposal_to_digitization(%L)::text$q$,prop))::uuid;
 ocase:=(select id from public.operational_cases where proposal_id=prop);
 perform pg_temp.check_that((select canonical_state='digitization_queue' from public.operational_cases where id=ocase),'proposal enters the esteira');
 perform pg_temp.check_that(pg_temp.u(uOp,format($q$select public.transition_operational_case(%L,'digitizing')$q$,ocase))='digitizing','operator starts digitizing (allowed for every role)');
 perform pg_temp.check_that(pg_temp.u(uSv,format($q$select public.transition_operational_case(%L,'submitted')$q$,ocase))='submitted','supervisor submits');
 perform pg_temp.expect_err('authenticated',uOp,format($q$select public.transition_operational_case(%L,'approved')$q$,ocase),'operational_decision_requires_privileged_role','operator cannot approve');
 perform pg_temp.expect_err('authenticated',uSv,format($q$select public.transition_operational_case(%L,'paid')$q$,ocase),'paid_requires_confirmed_financial_source','nobody moves the esteira to PAID');
 perform pg_temp.expect_err('authenticated',uMg,format($q$select public.transition_operational_case(%L,'digitizing')$q$,ocase),'invalid_operational_state_transition','invalid transitions are refused');
 perform pg_temp.expect_err('authenticated',uB,format($q$select public.transition_operational_case(%L,'approved')$q$,ocase),'operational_case_not_found_or_forbidden','another organization cannot touch the case');

 -- ===== 4. INTEGRATION (fake provider claims paid + commission) =====
 insert into public.import_sources(id,organization_id,name,source_kind) values(s1,o1,'src pilot','manual');
 insert into public.integration_adapters(id,adapter_key,provider_key,transport,name,contract_version,capabilities) values(adp,'local/pilot','local','api','fake pilot','1.0.0','["status"]');
 insert into public.integration_source_bindings(id,organization_id,source_id,adapter_id) values(bind1,o1,s1,adp);
 c:=pg_temp.claim(o1,bind1,repeat('a',64),uSv,t0);
 perform pg_temp.check_that(c.outcome='claimed','supervisor triggers an integration run');
 r:=pg_temp.run_as('service_role',null,format($q$select public.complete_integration_run(%L,%L,%L,'ext-pilot','[{"kind":"response_metadata","payload":{"status":"paid","commission":999999,"approved":true},"sha256":"pilot1"}]'::jsonb)$q$,o1,c.run_id,c.claim_token));
 perform pg_temp.check_that(r='succeeded','the provider result is stored as evidence of the run');
 perform pg_temp.check_that((select status='submitted' from public.proposals_v2 where id=prop) and (select canonical_state='submitted' from public.operational_cases where id=ocase),'FIREWALL: provider "paid" changed neither the proposal nor the esteira');
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe and (select count(*) from public.financial_reconciliation_cases)=fc,'FIREWALL: provider "paid"/commission 999999 created no financial truth');

 -- ===== 5. MANAGER reads what the dashboard shows =====
 perform pg_temp.check_that(pg_temp.u(uMg,format($q$select count(*)::text from public.leads where organization_id=%L and status in ('new','contacted','qualified')$q$,o1))='0','dashboard: open leads = 0 (the only lead was converted)');
 perform pg_temp.check_that(pg_temp.u(uMg,'select count(*)::text from public.proposals_v2')='1','dashboard: proposals = 1');
 perform pg_temp.check_that(pg_temp.u(uMg,$q$select count(*)::text from public.operational_cases where canonical_state not in ('paid','cancelled','rejected')$q$)='1','dashboard: cases in the esteira = 1');
 perform pg_temp.check_that(pg_temp.u(uMg,$q$select count(*)::text from public.integration_runs where status='failed' and terminal=true$q$)='0','dashboard: integrations needing attention = 0');
 perform pg_temp.check_that(pg_temp.u(uOp,'select count(*)::text from public.integration_runs')='0' and pg_temp.u(uOp,'select count(*)::text from public.financial_events')='0','operator sees no integration runs and no financial data');

 -- ===== 6. REVOCATION mid-flow =====
 mSv:=(select id from public.organization_memberships where user_id=uSv and organization_id=o1);
 perform pg_temp.expect_err('authenticated',uSv,format($q$select public.set_member_status(%L,'inactive')$q$,mSv),'not_authorized|membership_not_found','the supervisor cannot deactivate themselves or anyone');
 perform pg_temp.expect_err('authenticated',uMg,format($q$select public.set_member_status(%L,'inactive')$q$,(select id from public.organization_memberships where user_id=uAd)),'role_change_not_permitted','manager cannot deactivate the admin');
 perform pg_temp.check_that(pg_temp.u(uMg,format($q$select public.set_member_status(%L,'inactive')::text$q$,mSv))='','manager deactivates the supervisor');
 perform pg_temp.expect_err('authenticated',uSv,format($q$select public.transition_operational_case(%L,'approved')$q$,ocase),'operational_case_not_found_or_forbidden','the very next esteira action of the deactivated supervisor is refused');
 perform pg_temp.check_that(pg_temp.u(uSv,'select (select count(*) from public.proposals_v2)+(select count(*) from public.leads)+(select count(*) from public.operational_cases)+(select count(*) from public.integration_runs)')::int=0,'the deactivated supervisor reads nothing');
 perform pg_temp.expect_err('authenticated',uSv,format($q$select public.create_proposal_from_simulation(%L)$q$,sim),'simulation_not_found_or_forbidden|forbidden|not_found','and cannot start new work');
 perform pg_temp.check_that(pg_temp.accept(uSv,'supervisor@pilot.example')='','accepting an old, already used invitation does not bring the person back');
 perform pg_temp.check_that(pg_temp.u(uAd,format($q$select public.set_member_status(%L,'active')::text$q$,mSv))='','admin reactivates the supervisor');
 perform pg_temp.check_that(pg_temp.u(uSv,format($q$select public.transition_operational_case(%L,'approved')$q$,ocase))='approved','after reactivation the supervisor approves');
 perform pg_temp.check_that((select status='approved' from public.proposals_v2 where id=prop),'the proposal is approved by the esteira (NOT paid)');

 -- ===== 7. financial truth stays separate; no residue of authority =====
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe and (select count(*) from public.financial_reconciliation_cases)=fc,'END: no financial event and no reconciliation case in the whole journey');
 perform pg_temp.check_that((select count(*) from public.proposal_status_evidence where proposal_id=prop)=0,'END: no paid evidence exists');
 perform pg_temp.check_that((select count(*) from public.organization_admin_events where organization_id=o1)>=8,'END: every access change is on the audit trail');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and p.proname not in ('attach_import_batch_adapter','caller_role_in','commercial_route','import_row_evidence','lead_write','list_import_rows','bootstrap_organization_admin','get_user_organization_id')),'END: DEFINER inventory equals the reviewed list');

 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED: '||r end;
end $test$;
