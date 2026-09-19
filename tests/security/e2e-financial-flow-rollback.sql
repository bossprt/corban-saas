-- Rollback-only E2E: import -> match -> decision -> apply -> evidence -> expected/reported/received -> reconciliation
-- -> reversal -> recalculation -> human resolution, with tenant A/B and RBAC attacks. Uses the LIVE functions as deployed.
-- Fixtures are synthetic and never persisted: the whole DO block ends with RAISE EXCEPTION.
-- Pass = message starting with 'RESULTS: ALL PASS'. Requires 20260919_financial_read_rbac_v1.sql (applied or executed
-- earlier in the same transaction) for the agent-read checks, plus 20260919_fix_import_matching_uuid_aggregate_v1.sql and
-- 20260919_import_apply_rls_v1.sql and 20260919_import_identity_case_normalization_v1.sql (live matching/apply are broken
-- without them: min(uuid), missing INSERT policy, case-sensitive identity lookup creating duplicates).
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid();
 uS uuid:=gen_random_uuid(); uA uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid();
 pA uuid:=gen_random_uuid(); pB uuid:=gen_random_uuid();
 sc uuid:=gen_random_uuid(); sp uuid:=gen_random_uuid(); so uuid:=gen_random_uuid(); ch uuid:=gen_random_uuid();
 b_c text; b_p text; b_o text; b_dup text; n_c uuid; n_p uuid; n_o uuid; c_c uuid; c_p uuid; c_o uuid; d_c uuid; d_p uuid; d_o uuid;
 ev_rep text; ev_pay text; ev_rep2 text; r text; k int; case_id uuid; m text; uM uuid:=gen_random_uuid(); uR uuid:=gen_random_uuid(); s2b uuid:=gen_random_uuid(); bM1 text; bM2 text; cu1 uuid; cu2 uuid;
begin
 create temp table t_res(label text, pass boolean) on commit drop;
 create function pg_temp.as_user(p_uid uuid) returns void language plpgsql as $f$
 begin
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role','authenticated')::text,true);
  perform set_config('request.jwt.claim.sub',coalesce(p_uid::text,''),true);
  set local role authenticated;
 end $f$;
 create function pg_temp.run_as(p_uid uuid,q text) returns text language plpgsql as $f$
 declare r text;
 begin
  perform pg_temp.as_user(p_uid);
  begin execute q into r; exception when others then reset role; raise; end;
  reset role; return r;
 end $f$;
 create function pg_temp.err_of(p_uid uuid,q text) returns text language plpgsql as $f$
 declare msg text;
 begin
  begin perform pg_temp.as_user(p_uid); execute q; reset role; msg:=null;
  exception when others then reset role; msg:=sqlerrm; end;
  return msg;
 end $f$;
 create function pg_temp.expect_err(p_uid uuid,q text,pat text,label text) returns void language plpgsql as $f$
 declare msg text:=pg_temp.err_of(p_uid,q);
 begin
  if msg is null then insert into t_res values(label||' [UNEXPECTED SUCCESS]',false);
  elsif msg !~ pat then insert into t_res values(label||' [got: '||msg||']',false);
  else insert into t_res values(label,true); end if;
 end $f$;
 create function pg_temp.check_that(cond boolean,label text) returns void language plpgsql as $f$
 begin insert into t_res values(label,coalesce(cond,false)); end $f$;

 -- ---------- synthetic fixtures ----------
 insert into auth.users(id) values(uS),(uA),(uB),(uM),(uR);
 insert into public.organizations(id,name,document) values(o1,'E2E-A','doc-'||o1),(o2,'E2E-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role) values(o1,uS,'supervisor'),(o1,uA,'agent'),(o2,uB,'admin');
 insert into public.organization_memberships(organization_id,user_id,role,status) values(o1,uM,'supervisor','active'),(o2,uM,'admin','active'),(o1,uR,'admin','revoked');
 insert into public.import_sources(id,organization_id,name,source_kind) values(s2b,o2,'src-b','manual');
 insert into public.import_sources(id,organization_id,name,source_kind,financial_semantic) values
  (sc,o1,'commission statement','bank','commission_statement'),(sp,o1,'payment statement','bank','payment_statement'),(so,o1,'table offer','bank','commercial_offer');
 set local session_replication_role='replica';
 insert into public.proposals_v2(id,organization_id,customer_id,product_table_version_id,customer_snapshot,commercial_snapshot) values
  (pA,o1,gen_random_uuid(),gen_random_uuid(),'{}','{}'),(pB,o2,gen_random_uuid(),gen_random_uuid(),'{}','{}');
 insert into public.commercial_channels(id,organization_id,bank_id,name) values(ch,o1,gen_random_uuid(),'synthetic channel');
 insert into public.proposal_commercial_snapshots(proposal_id,organization_id,channel_id,snapshot,commission_rule_version_id)
  values(pA,o1,ch,'{"calculation_base_amount":"1000"}',gen_random_uuid());
 insert into public.proposal_commercial_component_snapshots(organization_id,proposal_id,component_type,commission_component_id,upstream_share,downstream_share,gross_percentage)
  values(o1,pA,'upfront',gen_random_uuid(),1,0,10);
 insert into public.proposal_external_identities(organization_id,proposal_id,institution_key,external_proposal_number) values(o1,pA,'daycoval','100');
 set local session_replication_role='origin';

 -- ---------- expected commission (governed publisher) ----------
 perform pg_temp.expect_err(uA,format($q$select public.publish_expected_commission(%L)$q$,pA),'forbidden','agent cannot publish expected commission');
 perform pg_temp.expect_err(uB,format($q$select public.publish_expected_commission(%L)$q$,pA),'forbidden','tenant B cannot publish for tenant A proposal');
 perform pg_temp.check_that(pg_temp.run_as(uS,format($q$select public.publish_expected_commission(%L)::text$q$,pA))='1','supervisor publishes expected commission (1 component)');
 perform pg_temp.check_that(pg_temp.run_as(uS,format($q$select public.publish_expected_commission(%L)::text$q$,pA))='0','replay publishes nothing (idempotent)');
 perform pg_temp.check_that((select amount from public.financial_events where proposal_id=pA and event_type='commission_expected')=100,'expected = 10% of 1000 = 100');

 -- ---------- commission statement import chain ----------
 b_c:=pg_temp.run_as(uS,format($q$select public.ingest_normalized_import_batch(%L,'c.csv',repeat('a',64),'text/csv','generic-commission-statement','1.0.0','[{"rowNumber":1,"rawPayload":{"Proposta":"100","Valor":"120,00"},"normalized":{"recordKind":"commission","bankKey":"Daycoval","externalProposalNumber":"100","amount":"120.00","normalizedPayload":{"componentType":"upfront","occurredAt":"2026-01-10T00:00:00Z","currency":"BRL"}}}]'::jsonb)::text$q$,sc));
 b_dup:=pg_temp.run_as(uS,format($q$select public.ingest_normalized_import_batch(%L,'renamed.csv',repeat('a',64),'text/csv','generic-commission-statement','1.0.0','[{"rowNumber":1,"rawPayload":{"x":"y"},"normalized":{"recordKind":"other","normalizedPayload":{}}}]'::jsonb)::text$q$,sc));
 perform pg_temp.check_that(b_dup=b_c,'duplicate file (same SHA-256) reuses the batch');
 perform pg_temp.check_that((select count(*) from public.import_raw_rows where batch_id=b_c::uuid)=1,'raw row preserved exactly once');
 perform pg_temp.expect_err(uB,format($q$select public.ingest_normalized_import_batch(%L,'x.csv',repeat('b',64),'text/csv','p','1','[{"rowNumber":1,"rawPayload":{},"normalized":{"recordKind":"other","normalizedPayload":{}}}]'::jsonb)$q$,sc),'source_not_found','tenant B cannot ingest into tenant A source');
 perform pg_temp.check_that(pg_temp.run_as(uS,format($q$select public.generate_import_match_candidates(%L)::text$q$,b_c))='1','matching generated one candidate');
 select c.id,c.normalized_row_id into c_c,n_c from public.import_match_candidates c join public.import_raw_rows rr on true join public.import_normalized_rows nr on nr.raw_row_id=rr.id and nr.id=c.normalized_row_id where rr.batch_id=b_c::uuid limit 1;
 perform pg_temp.check_that((select match_strength='exact' and proposal_id=pA from public.import_match_candidates where id=c_c),'exact match by institution (case-insensitive) + external number');
 perform pg_temp.expect_err(uB,format($q$select public.generate_import_match_candidates(%L)$q$,b_c),'batch_not_found_or_forbidden','tenant B cannot match tenant A batch');
 perform pg_temp.expect_err(uS,format($q$select public.publish_financial_fact_from_import_decision(%L)$q$,gen_random_uuid()),'approved_decision_not_found_or_forbidden','no financial fact without an approved decision');
 d_c:=gen_random_uuid();
 perform pg_temp.run_as(uS,format($q$with i as (insert into public.import_decisions(id,organization_id,batch_id,normalized_row_id,candidate_id,decision,decided_by) values(%L,%L,%L,%L,%L,'approve',%L) returning 1) select count(*)::text from i$q$,d_c,o1,b_c::uuid,n_c,c_c,uS));
 perform pg_temp.expect_err(uS,format($q$select public.publish_financial_fact_from_import_decision(%L)$q$,d_c),'identity_match_must_be_applied_first','financial fact requires the identity match to be applied first');
 perform pg_temp.expect_err(uB,format($q$select public.apply_approved_import_match(%L)$q$,d_c),'approved_decision_required','tenant B cannot apply tenant A decision');
 perform pg_temp.run_as(uS,format($q$select public.apply_approved_import_match(%L)::text$q$,d_c));
 perform pg_temp.check_that((select count(*) from public.proposal_external_identities where proposal_id=pA)=1,'apply did not duplicate the identity when only the bank spelling differs in case');
 ev_rep:=pg_temp.run_as(uS,format($q$select public.publish_financial_fact_from_import_decision(%L)::text$q$,d_c));
 perform pg_temp.check_that((select event_type='commission_reported' and amount=120 and source_kind='import' from public.financial_events where id=ev_rep::uuid),'commission statement publishes commission_reported 120 with import evidence');
 perform pg_temp.check_that((select count(*) from public.financial_evidence_links where financial_event_id=ev_rep::uuid)=1,'evidence lineage link recorded');
 perform pg_temp.check_that(pg_temp.run_as(uS,format($q$select public.publish_financial_fact_from_import_decision(%L)::text$q$,d_c))=ev_rep,'replay of the same decision returns the same event');
 perform pg_temp.check_that((select count(*) from public.financial_events where proposal_id=pA and event_type='commission_reported')=1,'no duplicate reported event');
 select status into m from public.financial_reconciliation_cases where proposal_id=pA;
 perform pg_temp.check_that(m='divergent','expected 100 vs reported 120, nothing received: divergent');

 -- ---------- payment statement import chain ----------
 b_p:=pg_temp.run_as(uS,format($q$select public.ingest_normalized_import_batch(%L,'p.csv',repeat('c',64),'text/csv','generic-payment-statement','1.0.0','[{"rowNumber":1,"rawPayload":{"Proposta":"100","Valor":"100,00"},"normalized":{"recordKind":"payment","bankKey":"daycoval","externalProposalNumber":"100","amount":"100.00","normalizedPayload":{"componentType":"upfront","occurredAt":"2026-02-01T00:00:00Z"}}}]'::jsonb)::text$q$,sp));
 perform pg_temp.run_as(uS,format($q$select public.generate_import_match_candidates(%L)::text$q$,b_p));
 select c.id,c.normalized_row_id into c_p,n_p from public.import_match_candidates c join public.import_normalized_rows nr on nr.id=c.normalized_row_id join public.import_raw_rows rr on rr.id=nr.raw_row_id where rr.batch_id=b_p::uuid limit 1;
 d_p:=gen_random_uuid();
 perform pg_temp.run_as(uS,format($q$with i as (insert into public.import_decisions(id,organization_id,batch_id,normalized_row_id,candidate_id,decision,decided_by) values(%L,%L,%L,%L,%L,'approve',%L) returning 1) select count(*)::text from i$q$,d_p,o1,b_p::uuid,n_p,c_p,uS));
 perform pg_temp.run_as(uS,format($q$select public.apply_approved_import_match(%L)::text$q$,d_p));
 ev_pay:=pg_temp.run_as(uS,format($q$select public.publish_financial_fact_from_import_decision(%L)::text$q$,d_p));
 perform pg_temp.check_that((select event_type='payment_received' and amount=100 from public.financial_events where id=ev_pay::uuid),'payment statement publishes payment_received 100');
 perform pg_temp.check_that((select expected_amount=100 and reported_amount=120 and settled_amount=100 and status='matched' from public.financial_reconciliation_cases where proposal_id=pA),'reconciliation: expected 100 / reported 120 / settled 100 -> matched on settled=expected');

 -- ---------- commercial offer can never prove money ----------
 b_o:=pg_temp.run_as(uS,format($q$select public.ingest_normalized_import_batch(%L,'o.csv',repeat('d',64),'text/csv','daycoval-table-offer','1.0.0','[{"rowNumber":1,"rawPayload":{"Proposta":"100","Valor":"999"},"normalized":{"recordKind":"commission","bankKey":"daycoval","externalProposalNumber":"100","amount":"999.00","normalizedPayload":{"componentType":"upfront","occurredAt":"2026-02-02T00:00:00Z"}}}]'::jsonb)::text$q$,so));
 perform pg_temp.run_as(uS,format($q$select public.generate_import_match_candidates(%L)::text$q$,b_o));
 select c.id,c.normalized_row_id into c_o,n_o from public.import_match_candidates c join public.import_normalized_rows nr on nr.id=c.normalized_row_id join public.import_raw_rows rr on rr.id=nr.raw_row_id where rr.batch_id=b_o::uuid limit 1;
 d_o:=gen_random_uuid();
 perform pg_temp.run_as(uS,format($q$with i as (insert into public.import_decisions(id,organization_id,batch_id,normalized_row_id,candidate_id,decision,decided_by) values(%L,%L,%L,%L,%L,'approve',%L) returning 1) select count(*)::text from i$q$,d_o,o1,b_o::uuid,n_o,c_o,uS));
 perform pg_temp.run_as(uS,format($q$select public.apply_approved_import_match(%L)::text$q$,d_o));
 perform pg_temp.expect_err(uS,format($q$select public.publish_financial_fact_from_import_decision(%L)$q$,d_o),'source_does_not_prove_financial_fact','commercial_offer evidence cannot create financial truth');

 -- ---------- reversals and recalculation ----------
 perform pg_temp.run_as(uS,format($q$select public.publish_financial_reversal(%L,20,'bank corrected statement','bank_report','stmt-2026-02')::text$q$,ev_rep));
 perform pg_temp.run_as(uS,format($q$select public.publish_financial_reversal(%L,40,'chargeback','payment_evidence','cb-77')::text$q$,ev_pay));
 perform pg_temp.check_that((select expected_amount=100 and reported_amount=100 and settled_amount=60 from public.financial_reconciliation_cases where proposal_id=pA),'reversals subtract from the right buckets: reported 100, settled 60');
 perform pg_temp.check_that((select amount=120 from public.financial_events where id=ev_rep::uuid) and (select amount=100 from public.financial_events where id=ev_pay::uuid),'original events are unchanged');
 perform pg_temp.check_that((select expected_amount+0=expected_amount and status in ('divergent','matched','open','human_required') from public.financial_reconciliation_cases where proposal_id=pA),'case status stays within the derived set');
 perform pg_temp.check_that((select settled_amount<>expected_amount and status='divergent' from public.financial_reconciliation_cases where proposal_id=pA),'after the chargeback the case is divergent again');

 -- ---------- human resolution ----------
 select id into case_id from public.financial_reconciliation_cases where proposal_id=pA;
 perform pg_temp.expect_err(uS,format($q$update public.financial_reconciliation_cases set settled_amount=100 where id=%L$q$,case_id),'reconciliation_amounts_are_derived','human cannot rewrite settled_amount');
 perform pg_temp.expect_err(uS,format($q$update public.financial_reconciliation_cases set status='matched' where id=%L$q$,case_id),'reconciliation_status_is_derived','human cannot forge matched');
 perform pg_temp.run_as(uS,format($q$with u as (update public.financial_reconciliation_cases set status='resolved',resolution_note='chargeback confirmed with the bank',resolved_by=%L where id=%L returning 1) select count(*)::text from u$q$,uA,case_id));
 perform pg_temp.check_that((select status='resolved' and resolved_by=uS and resolved_at is not null and settled_amount=60 from public.financial_reconciliation_cases where id=case_id),'resolution stamped by server (not the client-sent user); amounts intact');

 -- ---------- RBAC + tenant isolation reads ----------
 perform pg_temp.check_that(pg_temp.run_as(uA,$q$select count(*)::text from public.financial_events$q$)='0','agent reads no financial events (read RBAC)');
 perform pg_temp.check_that(pg_temp.run_as(uA,$q$select count(*)::text from public.financial_reconciliation_cases$q$)='0','agent reads no reconciliation cases');
 perform pg_temp.check_that(pg_temp.run_as(uS,$q$select count(*)::text from public.financial_events$q$)::int>=5,'supervisor reads tenant events');
 perform pg_temp.check_that(pg_temp.run_as(uB,$q$select count(*)::text from public.financial_events$q$)='0','tenant B reads no tenant A events');
 perform pg_temp.check_that(pg_temp.run_as(uB,$q$select count(*)::text from public.financial_reconciliation_cases$q$)='0','tenant B reads no tenant A cases');
 perform pg_temp.check_that(pg_temp.run_as(uB,$q$select count(*)::text from public.import_normalized_rows$q$)='0','tenant B reads no tenant A import rows');
 perform pg_temp.expect_err(uB,format($q$select public.publish_financial_reversal(%L,1,'x','bank_report','r')$q$,ev_pay),'event_not_found','tenant B cannot reverse tenant A event');
 perform pg_temp.expect_err(uB,format($q$select public.refresh_financial_reconciliation(%L,'upfront')$q$,pA),'proposal_not_found','tenant B cannot recompute tenant A reconciliation');
 perform pg_temp.expect_err(uB,format($q$select public.publish_financial_fact_from_import_decision(%L)$q$,d_c),'approved_decision_not_found_or_forbidden','tenant B cannot publish from tenant A decision');
 perform pg_temp.check_that(pg_temp.run_as(uB,format($q$with u as (update public.financial_reconciliation_cases set resolution_note='pwn' where id=%L returning 1) select count(*)::text from u$q$,case_id))='0','tenant B cannot update tenant A cases');
 perform pg_temp.expect_err(uS,$q$delete from public.financial_events$q$,'permission denied','ledger cannot be deleted by members (no DELETE privilege)');
 perform pg_temp.expect_err(uS,$q$update public.financial_events set amount=1$q$,'permission denied','ledger cannot be updated by members (no UPDATE privilege)');
 perform pg_temp.expect_err(uA,format($q$insert into public.import_match_candidates(organization_id,normalized_row_id,proposal_id,match_strength,match_basis,status) values(%L,%L,%L,'exact','{}','suggested')$q$,o1,n_c,pA),'match_candidate_requires_governed_rpc|row-level security','agent cannot forge an exact match candidate');
 perform pg_temp.expect_err(uA,format($q$insert into public.proposal_external_identities(organization_id,proposal_id,institution_key,external_proposal_number) values(%L,%L,'daycoval','999')$q$,o1,pA),'row-level security','agent cannot bind an external proposal identity');

 -- ===== column security (20260920_column_security_and_tenant_derivation_v1) =====
 perform pg_temp.expect_err(uA,'select commission_upfront from public.import_normalized_rows','permission denied','agent cannot read commission columns of import rows');
 perform pg_temp.expect_err(uA,'select normalized_payload from public.import_normalized_rows','permission denied','agent cannot read the economic payload of import rows');
 perform pg_temp.expect_err(uA,'select * from public.import_normalized_rows','permission denied','select * on import rows is denied for agent (restricted columns)');
 perform pg_temp.check_that(pg_temp.run_as(uA,'select count(*)::text from (select id,record_kind,bank_key,external_proposal_number,term,rate from public.import_normalized_rows) t')::int>=1,'agent still reads operational import columns');
 perform pg_temp.check_that(pg_temp.run_as(uA,format($q$select count(*)::text from public.list_import_rows(%L) where amount is not null or normalized_payload is not null or commission_upfront is not null$q$,b_c::uuid))='0' and pg_temp.run_as(uA,format($q$select count(*)::text from public.list_import_rows(%L)$q$,b_c::uuid))::int>=1,'list_import_rows masks economics for agent');
 perform pg_temp.check_that(pg_temp.run_as(uS,format($q$select max(amount)::text from public.list_import_rows(%L)$q$,b_c::uuid))::numeric=120,'list_import_rows returns economics to supervisor');
 perform pg_temp.expect_err(uB,format($q$select * from public.list_import_rows(%L)$q$,b_c::uuid),'batch_not_found_or_forbidden','tenant B cannot list tenant A import rows');
 perform pg_temp.expect_err(uR,format($q$select * from public.list_import_rows(%L)$q$,b_c::uuid),'batch_not_found_or_forbidden','revoked membership cannot list import rows');
 perform pg_temp.expect_err(uA,'select snapshot from public.proposal_commercial_snapshots','permission denied','agent cannot read the commercial snapshot economics');
 perform pg_temp.expect_err(uA,'select commission_rule_version_id from public.proposal_commercial_snapshots','permission denied','agent cannot read commission rule ids');
 perform pg_temp.check_that(pg_temp.run_as(uA,'select count(*)::text from (select proposal_id,channel_id from public.proposal_commercial_snapshots) t')='1','agent reads operational snapshot columns');
 perform pg_temp.expect_err(uA,format($q$select * from public.get_commercial_route(%L)$q$,pA),'forbidden','agent cannot get the commercial route economics');
 perform pg_temp.expect_err(uB,format($q$select * from public.get_commercial_route(%L)$q$,pA),'forbidden','tenant B cannot get tenant A route economics');
 perform pg_temp.check_that(pg_temp.run_as(uS,format($q$select (snapshot->>'calculation_base_amount') from public.get_commercial_route(%L)$q$,pA))='1000','supervisor reads the frozen route economics');
 -- ===== multi-organization user: tenant comes from the resource, never arbitrary =====
 bM1:=pg_temp.run_as(uM,format($q$select public.ingest_normalized_import_batch(%L,'m1.csv',repeat('e',64),'text/csv','p','1','[{"rowNumber":1,"rawPayload":{"x":1},"normalized":{"recordKind":"other","normalizedPayload":{}}}]'::jsonb)::text$q$,sc));
 bM2:=pg_temp.run_as(uM,format($q$select public.ingest_normalized_import_batch(%L,'m2.csv',repeat('f',64),'text/csv','p','1','[{"rowNumber":1,"rawPayload":{"x":2},"normalized":{"recordKind":"other","normalizedPayload":{}}}]'::jsonb)::text$q$,s2b));
 perform pg_temp.check_that((select organization_id from public.import_batches where id=bM1::uuid)=o1 and (select organization_id from public.import_batches where id=bM2::uuid)=o2,'multi-org user: each batch lands in the organization of ITS source');
 perform pg_temp.expect_err(uR,format($q$select public.ingest_normalized_import_batch(%L,'r.csv',repeat('9',64),'text/csv','p','1','[{"rowNumber":1,"rawPayload":{},"normalized":{"recordKind":"other","normalizedPayload":{}}}]'::jsonb)$q$,sc),'source_not_found','revoked membership cannot ingest');
 cu1:=pg_temp.run_as(uM,format($q$select public.create_customer_with_timeline(%L::uuid,'Multi A','11111111111')::text$q$,o1))::uuid;
 cu2:=pg_temp.run_as(uM,format($q$select public.create_customer_with_timeline(%L::uuid,'Multi B','22222222222')::text$q$,o2))::uuid;
 perform pg_temp.check_that((select organization_id from public.clients where id=cu1)=o1 and (select organization_id from public.clients where id=cu2)=o2,'explicit organization decides where the customer is created');
 perform pg_temp.expect_err(uM,$q$select public.create_customer_with_timeline('Ambiguous','33333333333')$q$,'organization_required','legacy customer RPC refuses when the user has 2+ memberships');
 perform pg_temp.expect_err(uB,format($q$select public.create_customer_with_timeline(%L::uuid,'Cross','44444444444')$q$,o1),'active_membership_required','cannot create a customer in a foreign organization');
 perform pg_temp.expect_err(uR,format($q$select public.create_customer_with_timeline(%L::uuid,'Revoked','55555555555')$q$,o1),'active_membership_required','revoked membership cannot create customers');
 perform pg_temp.check_that(pg_temp.run_as(uA,$q$select public.create_customer_with_timeline('Single','66666666666')::text$q$) is not null,'legacy customer RPC still works for a single-membership user');
 perform pg_temp.expect_err(uM,format($q$select public.create_and_publish_commission_rule(%L,%L,'upfront',1,null,null,'gross',now(),null)$q$,ch,gen_random_uuid()),'channel_not_found','multi-org user is only supervisor in the channel organization: manager-only rule publishing is refused there');
 perform pg_temp.expect_err(uS,format($q$select public.create_and_publish_commission_rule(%L,%L,'upfront',1,null,null,'gross',now(),null)$q$,ch,gen_random_uuid()),'channel_not_found','supervisor cannot publish rules (manager+ only)');
 perform pg_temp.check_that(pg_get_functiondef('public.apply_approved_import_match'::regproc) like '%table_identity_requires_manager%','table identities require manager+ (same rule as the RLS policy)');

 -- ===== release gate: direct calls to private.* helpers (authenticated must NOT get an RLS/tenant bypass) =====
 perform pg_temp.check_that(pg_temp.run_as(uA,format($q$select coalesce(private.caller_role_in(%L::uuid),'null')$q$,o1))='agent','caller_role_in answers only about the caller (agent in own tenant)');
 perform pg_temp.check_that(pg_temp.run_as(uB,format($q$select coalesce(private.caller_role_in(%L::uuid),'null')$q$,o1))='null','caller_role_in for a tenant where the caller has no membership is NULL (no oracle on others)');
 perform pg_temp.check_that(pg_temp.run_as(uR,format($q$select coalesce(private.caller_role_in(%L::uuid),'null')$q$,o1))='null','revoked membership: caller_role_in is NULL');
 perform pg_temp.check_that(pg_temp.run_as(gen_random_uuid(),format($q$select coalesce(private.caller_role_in(%L::uuid),'null')$q$,o1))='null','user without any membership: caller_role_in is NULL');
 perform pg_temp.check_that(pg_temp.run_as(uM,format($q$select coalesce(private.caller_role_in(%L::uuid),'null')||'/'||coalesce(private.caller_role_in(%L::uuid),'null')$q$,o1,o2))='supervisor/admin','multi-org user: role is per organization, never merged');
 perform pg_temp.expect_err(uB,format($q$select * from private.list_import_rows(%L)$q$,b_c::uuid),'batch_not_found_or_forbidden','direct private.list_import_rows: tenant B refused');
 perform pg_temp.expect_err(uR,format($q$select * from private.list_import_rows(%L)$q$,b_c::uuid),'batch_not_found_or_forbidden','direct private.list_import_rows: revoked refused');
 perform pg_temp.expect_err(gen_random_uuid(),format($q$select * from private.list_import_rows(%L)$q$,b_c::uuid),'batch_not_found_or_forbidden','direct private.list_import_rows: no membership refused');
 perform pg_temp.expect_err(uB,format($q$select * from private.list_import_rows(%L,array['100'])$q$,b_c::uuid),'batch_not_found_or_forbidden','private.list_import_rows with p_numbers cannot be used to read another tenant rows');
 perform pg_temp.check_that(pg_temp.run_as(uA,format($q$select count(*)::text from private.list_import_rows(%L) where amount is not null or normalized_payload is not null$q$,b_c::uuid))='0','direct private.list_import_rows still masks economics for agent');
 perform pg_temp.expect_err(uA,format($q$select * from private.import_row_evidence(%L)$q$,n_c),'forbidden','direct private.import_row_evidence: agent refused');
 perform pg_temp.expect_err(uB,format($q$select * from private.import_row_evidence(%L)$q$,n_c),'forbidden','direct private.import_row_evidence: tenant B refused');
 perform pg_temp.expect_err(uR,format($q$select * from private.import_row_evidence(%L)$q$,n_c),'forbidden','direct private.import_row_evidence: revoked refused');
 perform pg_temp.expect_err(gen_random_uuid(),format($q$select * from private.import_row_evidence(%L)$q$,n_c),'forbidden','direct private.import_row_evidence: no membership refused');
 perform pg_temp.expect_err(uR,format($q$select * from private.commercial_route(%L)$q$,pA),'forbidden','direct private.commercial_route: revoked refused');
 perform pg_temp.expect_err(gen_random_uuid(),format($q$select * from private.commercial_route(%L)$q$,pA),'forbidden','direct private.commercial_route: no membership refused');
 perform pg_temp.expect_err(uB,format($q$select * from private.commercial_route(%L)$q$,pA),'forbidden','direct private.commercial_route: tenant B refused');
 perform pg_temp.expect_err(uB,format($q$select * from private.import_row_evidence(%L)$q$,gen_random_uuid()),'forbidden','unknown row id and foreign row id give the same error');
 begin
  set local role anon;
  perform private.caller_role_in(o1);
  reset role;
  perform pg_temp.check_that(false,'anon must not be able to call private helpers');
 exception when others then reset role; perform pg_temp.check_that(sqlerrm ~ 'permission denied','anon cannot call private helpers ('||sqlerrm||')'); end;
 perform pg_temp.check_that(not has_schema_privilege('anon','private','USAGE') and not has_schema_privilege('anon','private','CREATE') and not has_schema_privilege('authenticated','private','CREATE'),'private schema: no anon USAGE, nobody can CREATE objects there');
 -- inventory: every SECURITY DEFINER in application schemas pins search_path, is never executable by anon or PUBLIC, and none lives in an exposed schema for authenticated
 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and not exists(select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%')),'every SECURITY DEFINER in public/private pins search_path');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace,lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a where p.prosecdef and n.nspname in ('public','private') and (a.grantee=0 or a.grantee=(select oid from pg_roles where rolname='anon'))),'no SECURITY DEFINER in public/private is executable by PUBLIC or anon');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname='public' and has_function_privilege('authenticated',p.oid,'EXECUTE')),'no SECURITY DEFINER function in the exposed public schema is executable by authenticated');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace,lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a where n.nspname='private' and (a.grantee=0 or a.grantee=(select oid from pg_roles where rolname='anon'))),'no function in private is executable by PUBLIC or anon (definer or not)');
 raise notice 'DEFINER_INVENTORY %',(select string_agg(n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||') auth='||has_function_privilege('authenticated',p.oid,'EXECUTE')::text||' anon='||has_function_privilege('anon',p.oid,'EXECUTE')::text,E'\n' order by 1) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private'));
 perform pg_temp.check_that(not exists(select 1 from public.financial_reconciliation_cases where expected_amount<0 or reported_amount<0 or settled_amount<0),'no negative bucket anywhere');

 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %
%
DEFINER INVENTORY:
%',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED' end,r,(select string_agg(n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||') authenticated='||has_function_privilege('authenticated',p.oid,'EXECUTE')::text||' anon='||has_function_privilege('anon',p.oid,'EXECUTE')::text,E'
' order by n.nspname,p.proname) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private'));
end $test$;

-- Regression (found by this harness): private readers must treat a NULL role as forbidden. `NULL not in (...)` is NULL, which
-- silently let tenant B call get_commercial_route / import_row_evidence for tenant A. Fixed with coalesce(role,'').
