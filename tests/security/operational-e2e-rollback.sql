-- Operational E2E, rollback-only: Lead -> Customer -> Simulation -> Proposal -> Esteira -> Integration Run (fake provider result)
-- -> Evidence -> Financial Truth guard -> Reconciliation, attacked with every role. Proves that CRM / operational / provider
-- success NEVER create financial truth by themselves.
-- Requires the LIVE closure-wave objects plus 20260921_integration_run_state_machine_v1 executed earlier in the same transaction
-- (the __MIG__ placeholder is replaced by the migration text when run from tooling; __MIG2__ = 20260921_operational_pipeline_write_hardening_v1). Ends with RAISE EXCEPTION; pass = 'RESULTS: ALL PASS'.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid();
 uAg uuid:=gen_random_uuid(); uS uuid:=gen_random_uuid(); uM uuid:=gen_random_uuid(); uAd uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid(); uR uuid:=gen_random_uuid(); uX uuid:=gen_random_uuid(); uN uuid:=gen_random_uuid();
 s1 uuid:=gen_random_uuid(); bind1 uuid:=gen_random_uuid(); adp uuid:=gen_random_uuid();
 lead uuid; cust uuid; sim uuid:=gen_random_uuid(); ptab uuid:=gen_random_uuid(); pver uuid:=gen_random_uuid(); prop uuid; job uuid; stage uuid:=gen_random_uuid();
 fe int; fc int; fp int; r text; k int; c record; fpr text:=repeat('a',64); t0 timestamptz:='2026-09-21 10:00:00+00';
 lead_b uuid;
begin
 execute $d$__MIG__$d$;
 execute $d$__MIG2__$d$;
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
 create function pg_temp.claim(p_org uuid,p_bind uuid,p_fp text,p_actor uuid,p_now timestamptz) returns record language plpgsql as $f$
 declare r record;
 begin
  perform pg_temp.as_role('service_role',null);
  begin select * into r from public.claim_integration_run(p_org,p_bind,'status',p_fp,p_actor,3,60,'{"proposal":"redacted-ref"}'::jsonb,'corr-e2e',p_now,'local/e2e'); exception when others then reset role; raise; end;
  reset role; return r;
 end $f$;

 insert into auth.users(id) values(uAg),(uS),(uM),(uAd),(uB),(uR),(uX),(uN);
 insert into public.organizations(id,name,document) values(o1,'OP-A','doc-'||o1),(o2,'OP-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role,status) values(o1,uAg,'agent','active'),(o1,uS,'supervisor','active'),(o1,uM,'manager','active'),(o1,uAd,'admin','active'),(o2,uB,'admin','active'),(o1,uR,'admin','revoked'),(o1,uX,'agent','active'),(o2,uX,'agent','active');
 select count(*) into fe from public.financial_events; select count(*) into fc from public.financial_reconciliation_cases;

 -- ===== 1. Lead =====
 lead:=pg_temp.u(uAg,format($q$select public.create_lead(%L::uuid,'whatsapp','Cliente Sintetico','5511900000000',null,'camp-e2e','wa-e2e-1')::text$q$,o1))::uuid;
 lead_b:=pg_temp.u(uB,format($q$select public.create_lead(%L::uuid,'manual','Outro Tenant')::text$q$,o2))::uuid;
 perform pg_temp.check_that((select status='new' from public.leads where id=lead),'lead created as new');
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe and (select count(*) from public.financial_reconciliation_cases)=fc and (select count(*) from public.proposals_v2)=0,'Lead creates no commission, no financial event, no proposal');
 perform pg_temp.expect_err('authenticated',uB,format($q$select public.set_lead_status(%L,'contacted')$q$,lead),'lead_forbidden','tenant B cannot touch tenant A lead by UUID');
 perform pg_temp.expect_err('authenticated',uN,format($q$select public.create_lead(%L::uuid,'manual','No Member')$q$,o1),'lead_forbidden','user without membership cannot create a lead');
 perform pg_temp.expect_err('authenticated',uR,format($q$select public.create_lead(%L::uuid,'manual','Revoked')$q$,o1),'lead_forbidden','revoked membership cannot create a lead');
 perform pg_temp.expect_err('anon',null,format($q$select public.create_lead(%L::uuid,'manual','Anon')$q$,o1),'permission denied','anon cannot call create_lead');
 perform pg_temp.expect_err('anon',null,'select * from public.leads','permission denied','anon cannot read leads');

 -- ===== 2. Customer =====
 cust:=pg_temp.u(uAg,format($q$select public.convert_lead_to_customer(%L,'98765432100')::text$q$,lead))::uuid;
 perform pg_temp.check_that((select organization_id=o1 and original_source='lead:whatsapp' from public.clients where id=cust),'Lead -> Customer in the lead tenant with provenance');
 perform pg_temp.check_that(pg_temp.u(uAg,format($q$select public.convert_lead_to_customer(%L,'98765432100')::text$q$,lead))::uuid=cust,'conversion is idempotent');
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe and (select count(*) from public.financial_reconciliation_cases)=fc,'Customer creates no commission and no financial truth');

 -- ===== 3. Simulation (fixtures: catalog rows are not what is under test) =====
 set local session_replication_role='replica';
 insert into public.product_tables(id,organization_id,route_id,code,name,status) values(ptab,o1,gen_random_uuid(),'T-E2E','Tabela sintetica','active');
 insert into public.product_table_versions(id,organization_id,product_table_id,version,status,rate,coefficient,published_at) values(pver,o1,ptab,1,'published',1.5,0.02,now());
 insert into public.simulations(id,organization_id,customer_id,product_table_version_id,status,requested_amount,released_amount,installment_amount,term,rate,coefficient,expected_commission_amount) values(sim,o1,cust,pver,'calculated',10000,9500,400,36,1.5,0.02,500);
 insert into public.operational_stages(id,organization_id,code,name,canonical_state,sort_order,sla_minutes,is_active) values(stage,o1,'dq','Fila de digitacao','digitization_queue',0,60,true);
 set local session_replication_role='origin';
 perform pg_temp.check_that((select expected_commission_amount=500 from public.simulations where id=sim) and (select count(*) from public.financial_events)=fe,'Simulation carries an EXPECTED commission estimate but creates no ledger event (no received money)');
 perform pg_temp.expect_err('authenticated',uB,format($q$select public.create_proposal_from_simulation(%L)$q$,sim),'simulation_not_found_or_forbidden','tenant B cannot create a proposal from a tenant A simulation UUID');

 -- ===== 4. Proposal =====
 prop:=pg_temp.u(uS,format($q$select public.create_proposal_from_simulation(%L)::text$q$,sim))::uuid;
 perform pg_temp.check_that((select status='draft' and organization_id=o1 and simulation_id=sim from public.proposals_v2 where id=prop),'Proposal created as draft (not paid, not approved)');
 perform pg_temp.check_that((select status='selected' from public.simulations where id=sim),'simulation consumed by the proposal');
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe and (select count(*) from public.financial_reconciliation_cases)=fc,'Proposal creation creates no financial truth');
 perform pg_temp.expect_err('authenticated',uS,format($q$update public.proposals_v2 set status='paid' where id=%L$q$,prop),'invalid_proposal_status_transition|paid_requires|proposal_write_requires_governed_rpc','a proposal cannot be marked PAID by UPDATE');
 perform pg_temp.expect_err('authenticated',uAd,format($q$update public.proposals_v2 set status='paid' where id=%L$q$,prop),'invalid_proposal_status_transition|paid_requires|permission denied|proposal_write_requires_governed_rpc','not even admin can mark PAID by UPDATE');

 -- ===== 5. Esteira =====
 set local session_replication_role='replica';
 update public.proposals_v2 set status='ready_for_digitization' where id=prop;
 set local session_replication_role='origin';
 perform pg_temp.expect_err('authenticated',uB,format($q$select public.send_proposal_to_digitization(%L)$q$,prop),'proposal_not_found_or_forbidden','tenant B cannot push a tenant A proposal into the esteira');
 job:=pg_temp.u(uS,format($q$select public.send_proposal_to_digitization(%L)::text$q$,prop))::uuid;
 perform pg_temp.check_that((select canonical_state='digitization_queue' from public.operational_cases where proposal_id=prop) and (select status='digitization' from public.proposals_v2 where id=prop),'operational case created in digitization_queue; proposal in digitization');
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe,'Esteira creates no financial truth');

 -- ===== 6. Integration run with the fake provider contract =====
 insert into public.import_sources(id,organization_id,name,source_kind) values(s1,o1,'src e2e','manual');
 insert into public.integration_adapters(id,adapter_key,provider_key,transport,name,contract_version,capabilities) values(adp,'local/e2e','local','api','fake e2e','1.0.0','["submit","status"]');
 insert into public.integration_source_bindings(id,organization_id,source_id,adapter_id) values(bind1,o1,s1,adp);
 c:=pg_temp.claim(o1,bind1,fpr,uS,t0);
 perform pg_temp.check_that(c.outcome='claimed','supervisor starts an integration run for the proposal status check');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'status',%L,%L,3,60,'{}'::jsonb,'c',now(),'local/e2e')$q$,o1,bind1,repeat('b',64),uAg),'actor_not_authorized','agent cannot start an integration run');
 perform pg_temp.expect_err('service_role',null,format($q$select * from public.claim_integration_run(%L,%L,'status',%L,%L,3,60,'{}'::jsonb,'c',now(),'local/e2e')$q$,o1,bind1,repeat('c',64),uB),'actor_not_authorized','tenant B user cannot start a run on tenant A binding');
 -- the provider SAYS the proposal is paid and that money arrived
 r:=pg_temp.run_as('service_role',null,format($q$select public.complete_integration_run(%L,%L,%L,'ext-e2e','[{"kind":"response_metadata","payload":{"status":"paid","commissionPaid":500,"note":"provider claims payment"},"sha256":"e2e1"}]'::jsonb)$q$,o1,c.run_id,c.claim_token));
 perform pg_temp.check_that(r='succeeded' and (select status='succeeded' from public.integration_runs where id=c.run_id),'provider success is recorded as a succeeded RUN with evidence');
 perform pg_temp.check_that((select status='digitization' from public.proposals_v2 where id=prop),'provider saying "paid" does NOT change the proposal status');
 perform pg_temp.check_that((select canonical_state='digitization_queue' from public.operational_cases where proposal_id=prop),'provider saying "paid" does NOT move the operational case');
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe and (select count(*) from public.financial_reconciliation_cases)=fc,'provider success is NOT revenue: no financial event, no reconciliation case');
 perform pg_temp.check_that((select count(*) from public.proposal_status_evidence where proposal_id=prop)=0,'no paid status evidence was fabricated from a provider run');
 perform pg_temp.expect_err('authenticated',uS,format($q$insert into public.financial_events(organization_id,proposal_id,event_type,amount,occurred_at,idempotency_key,source_kind) values(%L,%L,'payment_received',500,now(),'forge','integration')$q$,o1,prop),'permission denied|financial_fact_requires_evidence_rpc|row-level security','direct insert of a received-payment event is impossible for members (governed RPC only)');
 perform pg_temp.expect_err('authenticated',uS,format($q$select public.publish_financial_evidence_event(%L,'payment_received','upfront',500,now(),'integration','run:%s')$q$,prop,c.run_id),'confirmed_evidence_source_required|frozen_commercial_snapshot_required','an integration run is not an accepted financial evidence source');
 perform pg_temp.expect_err('authenticated',uS,format($q$select public.confirm_proposal_paid_from_import(%L)$q$,gen_random_uuid()),'approved_decision_not_found_or_forbidden','PAID confirmation needs an approved import decision, not a provider claim');
 perform pg_temp.expect_err('authenticated',uAg,format($q$select public.publish_expected_commission(%L)$q$,prop),'forbidden','agent cannot publish expected commission');
 perform pg_temp.expect_err('authenticated',uB,format($q$select public.publish_expected_commission(%L)$q$,prop),'forbidden','tenant B cannot publish expected commission on a tenant A proposal');

 -- ===== 7. Reconciliation cannot fabricate received money =====
 begin
  perform pg_temp.u(uS,format($q$select public.refresh_financial_reconciliation(%L,'upfront')::text$q$,prop));
  perform pg_temp.check_that((select settled_amount=0 and reported_amount=0 and status in ('open','human_required') from public.financial_reconciliation_cases where proposal_id=prop),'reconciliation over a proposal with only operational history settles nothing (settled=0, reported=0)');
 exception when others then perform pg_temp.check_that(sqlerrm ~ 'frozen|snapshot|forbidden','reconciliation refused without governed commercial data ('||sqlerrm||')'); end;
 perform pg_temp.expect_err('authenticated',uS,format($q$update public.financial_reconciliation_cases set settled_amount=500 where proposal_id=%L$q$,prop),'reconciliation_amounts_are_derived|permission denied','reconciliation amounts cannot be typed in');
 perform pg_temp.expect_err('authenticated',uS,format($q$insert into public.financial_reconciliation_cases(organization_id,proposal_id,component_type,expected_amount,reported_amount,settled_amount,status) values(%L,%L,'x',500,500,500,'matched')$q$,o1,prop),'reconciliation_case_requires_governed_rpc|permission denied|violates','a matched case cannot be fabricated');
 perform pg_temp.expect_err('authenticated',uB,format($q$select public.refresh_financial_reconciliation(%L,'upfront')$q$,prop),'proposal_not_found','tenant B cannot recompute tenant A reconciliation');

 -- ===== 8. RBAC / tenant matrix over the whole flow (RPC and direct tables) =====
 perform pg_temp.check_that(pg_temp.u(uAg,'select count(*)::text from public.integration_runs')='0' and pg_temp.u(uAg,'select count(*)::text from public.integration_run_artifacts')='0','agent reads no integration runs/artifacts');
 perform pg_temp.check_that(pg_temp.u(uAg,'select count(*)::text from public.financial_events')='0' and pg_temp.u(uAg,'select count(*)::text from public.financial_reconciliation_cases')='0','agent reads no financial truth');
 for k in 1..3 loop
  perform pg_temp.check_that(pg_temp.u((array[uS,uM,uAd])[k],'select count(*)::text from public.integration_runs')='1','supervisor/manager/admin read the run ('||k||')');
 end loop;
 perform pg_temp.check_that(pg_temp.u(uAg,format($q$select count(*)::text from public.leads where id=%L$q$,lead))='1','agent sees the tenant lead');
 perform pg_temp.check_that(pg_temp.u(uB,format($q$select (select count(*) from public.leads where id=%L)+(select count(*) from public.clients where id=%L)+(select count(*) from public.simulations where id=%L)+(select count(*) from public.proposals_v2 where id=%L)+(select count(*) from public.operational_cases where proposal_id=%L)+(select count(*) from public.integration_runs)+(select count(*) from public.financial_events)$q$,lead,cust,sim,prop,prop))::int=0,'tenant B sees NOTHING of tenant A across lead, customer, simulation, proposal, esteira, runs, ledger by known UUID');
 perform pg_temp.check_that(pg_temp.u(uR,'select (select count(*) from public.leads)+(select count(*) from public.proposals_v2)+(select count(*) from public.integration_runs)+(select count(*) from public.operational_cases)::int')::int=0,'revoked membership sees nothing');
 perform pg_temp.check_that(pg_temp.u(uN,'select (select count(*) from public.leads)+(select count(*) from public.proposals_v2)+(select count(*) from public.integration_runs)+(select count(*) from public.operational_cases)::int')::int=0,'user without membership sees nothing');
 perform pg_temp.check_that(pg_temp.u(uX,'select count(*)::text from public.leads')='2','multi-org user sees exactly the leads of ITS two organizations');
 perform pg_temp.check_that(pg_temp.u(uX,'select count(*)::text from public.integration_runs')='0','multi-org agent still cannot read runs');
 perform pg_temp.expect_err('anon',null,'select * from public.proposals_v2','permission denied','anon cannot read proposals');
 perform pg_temp.expect_err('anon',null,'select * from public.operational_cases','permission denied','anon cannot read the esteira');
 perform pg_temp.expect_err('anon',null,'select * from public.integration_runs','permission denied','anon cannot read runs');
 perform pg_temp.expect_err('anon',null,'select * from public.financial_events','permission denied','anon cannot read the ledger');
 perform pg_temp.expect_err('authenticated',uAd,format($q$delete from public.operational_events where operational_case_id in (select id from public.operational_cases where proposal_id=%L)$q$,prop),'permission denied','esteira history cannot be deleted even by admin');
 -- ===== 8b. Esteira write hardening (20260921_operational_pipeline_write_hardening_v1) =====
 for k in 1..4 loop
  perform pg_temp.expect_err('authenticated',(array[uAg,uS,uM,uAd])[k],format($q$update public.operational_cases set canonical_state='paid' where proposal_id=%L$q$,prop),'operational_write_requires_governed_rpc','nobody can jump an esteira case to paid by direct UPDATE ('||k||')');
 end loop;
 perform pg_temp.expect_err('authenticated',uAg,format($q$insert into public.operational_events(organization_id,operational_case_id,event_type,to_state,source) select organization_id,id,'forged','paid','corban_os' from public.operational_cases where proposal_id=%L$q$,prop),'operational_write_requires_governed_rpc','agent cannot forge esteira history');
 perform pg_temp.expect_err('authenticated',uS,format($q$update public.digitization_jobs set status='completed' where proposal_id=%L$q$,prop),'operational_write_requires_governed_rpc','a digitization job outcome cannot be rewritten directly');
 perform pg_temp.expect_err('authenticated',uS,format($q$insert into public.digitization_jobs(organization_id,proposal_id,status,priority) values(%L,%L,'queued',0)$q$,o1,prop),'operational_write_requires_governed_rpc|proposal_not_ready_for_digitization','a digitization job cannot be inserted directly');
 perform pg_temp.expect_err('authenticated',uAd,'delete from public.operational_cases','permission denied','no DELETE privilege on esteira cases');
 perform pg_temp.expect_err('authenticated',uAd,'delete from public.digitization_jobs','permission denied','no DELETE privilege on digitization jobs');
 perform pg_temp.expect_err('authenticated',uAd,'update public.operational_events set event_type=''x''','permission denied','esteira history has no UPDATE privilege');
 perform pg_temp.expect_err('authenticated',uAd,'update public.customer_timeline_events set event_type=''x''','permission denied','customer timeline has no UPDATE privilege');
 perform pg_temp.expect_err('authenticated',uAd,'delete from public.customer_timeline_events','permission denied','customer timeline has no DELETE privilege');
 perform pg_temp.check_that((select canonical_state='digitization_queue' from public.operational_cases where proposal_id=prop) and (select count(*) from public.operational_events where operational_case_id=(select id from public.operational_cases where proposal_id=prop))=1,'after every attack the esteira is exactly what the governed RPC wrote');
 perform pg_temp.check_that(exists(select 1 from pg_trigger t where t.tgrelid='public.operational_events'::regclass and t.tgname='trg_operational_events_write'),'append-only trigger installed on operational_events');
 perform pg_temp.expect_err('authenticated',uAd,format($q$update public.integration_runs set status='failed',error_code='x' where id=%L$q$,c.run_id),'permission denied','admin cannot rewrite a run by UPDATE');
 perform pg_temp.expect_err('authenticated',uAd,'delete from public.integration_run_artifacts','permission denied','admin cannot erase provider evidence');

 -- ===== 9. Closing invariants =====
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe,'END: the ledger is exactly as before the whole operational flow');
 perform pg_temp.check_that(not exists(select 1 from public.financial_reconciliation_cases where settled_amount>0 or reported_amount>0),'END: no reconciliation case has received or reported money');

 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and p.proname in ('claim_integration_run','complete_integration_run','fail_integration_run','cancel_integration_run','integration_content_has_secret','guard_integration_run_state','guard_integration_artifact_write','guard_operational_pipeline_write','send_proposal_to_digitization')),'END: none of the new/changed functions is SECURITY DEFINER');

 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %
%',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED' end,r;
end $test$;
