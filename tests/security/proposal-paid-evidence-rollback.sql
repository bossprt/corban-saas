-- 20260924_confirm_paid_replay_v1 is LIVE: run this file as is (no prelude).
-- Rollback-only proof that the ONLY way a proposal becomes PAID is confirm_proposal_paid_from_import (approved import decision + production
-- report status evidence), that the proposals_v2 write guard (worker_governance_v1) lets that path through, and that a PAID status is NOT money.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid(); uS uuid:=gen_random_uuid(); uA uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid();
 pA uuid:=gen_random_uuid(); sp uuid:=gen_random_uuid(); cu uuid:=gen_random_uuid(); ptab uuid:=gen_random_uuid(); pver uuid:=gen_random_uuid(); b text; n uuid; cnd uuid; d uuid:=gen_random_uuid(); r text; k int; fe int; fc int;
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

 insert into auth.users(id) values(uS),(uA),(uB);
 insert into public.organizations(id,name,document) values(o1,'PE-A','doc-'||o1),(o2,'PE-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role) values(o1,uS,'supervisor'),(o1,uA,'agent'),(o2,uB,'admin');
 insert into public.import_sources(id,organization_id,name,source_kind,financial_semantic) values(sp,o1,'production report','bank','production_report');
 insert into public.clients(id,organization_id,full_name,cpf) values(cu,o1,'Cliente PE','12312312312');
 set local session_replication_role='replica';
 insert into public.product_tables(id,organization_id,route_id,code,name,status) values(ptab,o1,gen_random_uuid(),'T-PE','Tabela PE','active');
 insert into public.product_table_versions(id,organization_id,product_table_id,version,status,published_at) values(pver,o1,ptab,1,'published',now());
 insert into public.proposals_v2(id,organization_id,customer_id,product_table_version_id,status,customer_snapshot,commercial_snapshot) values(pA,o1,cu,pver,'approved','{}','{}');
 insert into public.proposal_external_identities(organization_id,proposal_id,institution_key,external_proposal_number) values(o1,pA,'daycoval','100');
 set local session_replication_role='origin';
 select count(*) into fe from public.financial_events; select count(*) into fc from public.financial_reconciliation_cases;

 perform pg_temp.expect_err(uS,format($q$update public.proposals_v2 set status='paid' where id=%L$q$,pA),'proposal_write_requires_governed_rpc','a supervisor cannot set PAID by UPDATE');
 perform pg_temp.expect_err(uA,format($q$update public.proposals_v2 set status='paid' where id=%L$q$,pA),'proposal_write_requires_governed_rpc','an agent cannot set PAID by UPDATE');
 perform pg_temp.expect_err(uS,format($q$select public.confirm_proposal_paid_from_import(%L)$q$,gen_random_uuid()),'approved_decision_not_found_or_forbidden','no PAID without an approved import decision');

 b:=pg_temp.run_as(uS,format($q$select public.ingest_normalized_import_batch(%L,'s.csv',repeat('a',64),'text/csv','generic-production-report','1.0.0','[{"rowNumber":1,"rawPayload":{"Proposta":"100","Status":"PAGO"},"normalized":{"recordKind":"status","bankKey":"Daycoval","externalProposalNumber":"100","normalizedPayload":{"canonicalStatus":"paid","rawStatus":"PAGO","occurredAt":"2026-02-03T00:00:00Z"}}}]'::jsonb)::text$q$,sp));
 perform pg_temp.run_as(uS,format($q$select public.generate_import_match_candidates(%L)::text$q$,b));
 select c.id,c.normalized_row_id into cnd,n from public.import_match_candidates c join public.import_normalized_rows nr on nr.id=c.normalized_row_id join public.import_raw_rows rr on rr.id=nr.raw_row_id where rr.batch_id=b::uuid limit 1;
 perform pg_temp.check_that((select match_strength='exact' and proposal_id=pA from public.import_match_candidates where id=cnd),'the status row matches the proposal exactly by institution + external number');
 perform pg_temp.run_as(uS,format($q$with i as (insert into public.import_decisions(id,organization_id,batch_id,normalized_row_id,candidate_id,decision,decided_by) values(%L,%L,%L,%L,%L,'approve',%L) returning 1) select count(*)::text from i$q$,d,o1,b::uuid,n,cnd,uS));
 perform pg_temp.expect_err(uS,format($q$select public.confirm_proposal_paid_from_import(%L)$q$,d),'identity_match_must_be_applied_first','PAID needs the identity match applied first');
 perform pg_temp.expect_err(uB,format($q$select public.confirm_proposal_paid_from_import(%L)$q$,d),'approved_decision_not_found_or_forbidden','tenant B cannot confirm PAID from a tenant A decision');
 perform pg_temp.expect_err(uA,format($q$select public.confirm_proposal_paid_from_import(%L)$q$,d),'approved_decision_not_found_or_forbidden','an agent cannot confirm PAID');
 perform pg_temp.run_as(uS,format($q$select public.apply_approved_import_match(%L)::text$q$,d));
 r:=pg_temp.run_as(uS,format($q$select public.confirm_proposal_paid_from_import(%L)::text$q$,d));
 perform pg_temp.check_that((select status='paid' from public.proposals_v2 where id=pA),'the governed evidence path DOES mark the proposal paid (the write guard lets it through)');
 perform pg_temp.check_that((select count(*)=1 and bool_and(canonical_status='paid' and raw_status='PAGO') from public.proposal_status_evidence where proposal_id=pA),'exactly one status evidence row backs the change');
 perform pg_temp.check_that(pg_temp.run_as(uS,format($q$select public.confirm_proposal_paid_from_import(%L)::text$q$,d))=r,'REPLAY: the same decision returns the same evidence (idempotent, no error)');
 perform pg_temp.check_that((select count(*) from public.proposal_status_evidence where proposal_id=pA)=1,'REPLAY: zero duplicate evidence');
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe and (select count(*) from public.financial_reconciliation_cases)=fc,'a PAID STATUS is not money: no financial event and no reconciliation case was created');
 perform pg_temp.expect_err(uS,format($q$update public.proposals_v2 set status='approved' where id=%L$q$,pA),'proposal_write_requires_governed_rpc','a paid proposal cannot be moved back by UPDATE');
 perform pg_temp.check_that((select status='paid' from public.proposals_v2 where id=pA),'still paid after the attempt');
 perform pg_temp.expect_err(uS,format($q$update public.proposals_v2 set expected_commission_amount=1 where id=%L$q$,pA),'proposal_write_requires_governed_rpc','the paid-evidence token does not leak to later direct writes');

 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %
%',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED' end,case when k=0 then '' else r end;
end $test$;
