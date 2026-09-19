-- Rollback-only behavioral contract for 20260919_reconciliation_cases_write_hardening_v1.sql (LIVE) and
-- 20260920_reconciliation_resolution_immutability_v1.sql (NOT LIVE: execute it earlier in the same transaction). Ends with RAISE EXCEPTION so nothing persists; pass = message 'ALL PASS'.
do $test$
declare
 u1 uuid:=gen_random_uuid(); u3 uuid:=gen_random_uuid(); o1 uuid:=gen_random_uuid(); p1 uuid:=gen_random_uuid(); e1 uuid:=gen_random_uuid();
 c uuid; msg text; res text:=''; n int;
 procedure_dummy int;
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
 create function pg_temp.expect_err(p_uid uuid,q text,pat text,label text) returns void language plpgsql as $f$
 declare msg text;
 begin
  begin perform pg_temp.as_user(p_uid); execute q; reset role; msg:=null;
  exception when others then reset role; msg:=sqlerrm; end;
  if msg is null then insert into t_res values(label||' [UNEXPECTED SUCCESS]',false);
  elsif msg !~ pat then insert into t_res values(label||' [got: '||msg||']',false);
  else insert into t_res values(label,true); end if;
 end $f$;
 create function pg_temp.check_that(cond boolean,label text) returns void language plpgsql as $f$
 begin insert into t_res values(label,coalesce(cond,false)); end $f$;

 insert into auth.users(id) values(u1),(u3);
 insert into public.organizations(id,name,document) values(o1,'T-R','doc-'||o1);
 insert into public.organization_memberships(organization_id,user_id,role) values(o1,u1,'supervisor'),(o1,u3,'agent');
 set local session_replication_role='replica';
 insert into public.proposals_v2(id,organization_id,customer_id,product_table_version_id,customer_snapshot,commercial_snapshot) values(p1,o1,gen_random_uuid(),gen_random_uuid(),'{}','{}');
 set local session_replication_role='origin';
 perform set_config('corban.financial_expected_rpc','on',true);
 insert into public.financial_events(id,organization_id,proposal_id,event_type,component_type,amount,occurred_at,idempotency_key,source_kind,source_reference)
  values(e1,o1,p1,'commission_expected','upfront',1000,now(),'fx:'||e1,'proposal_snapshot','fx');
 perform set_config('corban.financial_expected_rpc','off',true);

 c:=pg_temp.run_as(u1,format($q$select public.refresh_financial_reconciliation(%L,'upfront')::text$q$,p1))::uuid;
 perform pg_temp.check_that((select expected_amount from public.financial_reconciliation_cases where id=c)=1000,'governed refresh still writes derived amounts');
 perform pg_temp.expect_err(u1,format($q$update public.financial_reconciliation_cases set settled_amount=1000 where id=%L$q$,c),'reconciliation_amounts_are_derived','direct settled_amount rewrite blocked');
 perform pg_temp.expect_err(u1,format($q$update public.financial_reconciliation_cases set expected_amount=1 where id=%L$q$,c),'reconciliation_amounts_are_derived','direct expected_amount rewrite blocked');
 perform pg_temp.expect_err(u1,format($q$update public.financial_reconciliation_cases set status='matched' where id=%L$q$,c),'reconciliation_status_is_derived','forging status=matched blocked');
 perform pg_temp.expect_err(u1,format($q$update public.financial_reconciliation_cases set organization_id=%L where id=%L$q$,gen_random_uuid(),c),'reconciliation_amounts_are_derived|violates|policy','moving a case across tenants blocked');
 perform pg_temp.expect_err(u1,format($q$insert into public.financial_reconciliation_cases(organization_id,proposal_id,component_type,expected_amount,reported_amount,settled_amount,status) values(%L,%L,'other',1,1,1,'matched')$q$,o1,p1),'reconciliation_case_requires_governed_rpc','direct insert of a forged case blocked');
 perform pg_temp.expect_err(u1,format($q$update public.financial_reconciliation_cases set status='resolved' where id=%L$q$,c),'resolution_note_required','resolving needs a note');
 perform pg_temp.run_as(u1,format($q$with u as (update public.financial_reconciliation_cases set status='resolved',resolution_note='checked with bank statement now',resolved_by=%L where id=%L returning 1) select count(*)::text from u$q$,u3,c));
 perform pg_temp.check_that((select status='resolved' and resolved_by=u1 and resolved_at is not null from public.financial_reconciliation_cases where id=c),'human resolution allowed; resolver stamped from session, not client value');
 perform pg_temp.check_that((select expected_amount=1000 and settled_amount=0 from public.financial_reconciliation_cases where id=c),'amounts untouched by resolution');
 perform pg_temp.check_that(coalesce(pg_temp.run_as(u3,format($q$with u as (update public.financial_reconciliation_cases set resolution_note='x' where id=%L returning 1) select count(*)::text from u$q$,c)),'0')='0','agent cannot update cases (RLS)');

 -- Block D re-audit (20260920_reconciliation_resolution_immutability_v1)
 perform pg_temp.expect_err(u1,format($q$update public.financial_reconciliation_cases set resolution_note='written without resolving the case' where id=%L$q$,c),'resolution_only_via_resolve|resolution_is_immutable','a note cannot be written on an open case without resolving it');
 perform pg_temp.expect_err(u1,format($q$update public.financial_reconciliation_cases set resolved_by=%L where id=%L$q$,u3,c),'resolution_is_immutable','resolved_by cannot be rewritten after resolution');
 perform pg_temp.expect_err(u1,format($q$update public.financial_reconciliation_cases set resolution_note='rewritten justification after the fact' where id=%L$q$,c),'resolution_is_immutable','the justification of a resolved case is immutable');
 perform pg_temp.expect_err(u1,format($q$update public.financial_reconciliation_cases set resolved_at=now()-interval '3 days' where id=%L$q$,c),'resolution_is_immutable','resolved_at cannot be back-dated');
 perform pg_temp.expect_err(u1,format($q$update public.financial_reconciliation_cases set status='open' where id=%L$q$,c),'resolution_is_immutable','a resolved case cannot be reopened by a human');
 perform pg_temp.check_that((select status='resolved' and resolved_by=u1 and resolution_note='checked with bank statement now' from public.financial_reconciliation_cases where id=c),'resolution triple untouched by every attempt');
 perform set_config('corban.financial_expected_rpc','on',true);
 insert into public.financial_events(id,organization_id,proposal_id,event_type,component_type,amount,occurred_at,idempotency_key,source_kind,source_reference) values(gen_random_uuid(),o1,p1,'commission_expected','upfront',500,now(),'fx2:'||e1,'proposal_snapshot','fx2'),(gen_random_uuid(),o1,p1,'commission_expected','deferred',100,now(),'fx3:'||e1,'proposal_snapshot','fx3');
 perform set_config('corban.financial_expected_rpc','off',true);
 perform pg_temp.run_as(u1,format($q$select public.refresh_financial_reconciliation(%L,'deferred')::text$q$,p1));
 perform pg_temp.expect_err(u1,format($q$update public.financial_reconciliation_cases set resolution_note='note on an OPEN case without resolving' where proposal_id=%L and component_type='deferred'$q$,p1),'resolution_only_via_resolve','a note cannot be written on an OPEN case without resolving it');
 perform pg_temp.run_as(u1,format($q$select public.refresh_financial_reconciliation(%L,'upfront')::text$q$,p1));
 perform pg_temp.check_that((select status='resolved' and resolved_by=u1 and expected_amount=1500 from public.financial_reconciliation_cases where id=c),'refresh updates amounts but never reopens or orphans a resolved case');
 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into res,n from t_res;
 raise exception 'RESULTS: %
%',case when n=0 then 'ALL PASS' else n||' FAILED' end,res;
end $test$;
