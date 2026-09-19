-- Rollback-only tenant A/B adversarial contract against the LIVE schema (customers, proposals, channels, rules, RPCs).
-- Synthetic fixtures only; the DO block ends with RAISE EXCEPTION so nothing persists. Pass = 'RESULTS: ALL PASS'.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid(); uA uuid:=gen_random_uuid(); uAg uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid();
 pA uuid:=gen_random_uuid(); chA uuid:=gen_random_uuid(); cliA uuid:=gen_random_uuid(); ptA uuid:=gen_random_uuid();
 r text; k int; n0 int; n1 int;
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

 insert into auth.users(id) values(uA),(uAg),(uB);
 insert into public.organizations(id,name,document) values(o1,'AB-A','doc-'||o1),(o2,'AB-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role) values(o1,uA,'manager'),(o1,uAg,'agent'),(o2,uB,'admin');
 set local session_replication_role='replica';
 insert into public.clients(id,organization_id,full_name,cpf) values(cliA,o1,'Synthetic A','12345678901');
 insert into public.proposals_v2(id,organization_id,customer_id,product_table_version_id,customer_snapshot,commercial_snapshot) values(pA,o1,cliA,gen_random_uuid(),'{}','{}');
 insert into public.commercial_channels(id,organization_id,bank_id,name) values(chA,o1,gen_random_uuid(),'chA');
 set local session_replication_role='origin';

 -- reads
 perform pg_temp.check_that(pg_temp.run_as(uB,'select count(*)::text from public.clients')='0','B reads no A customers');
 perform pg_temp.check_that(pg_temp.run_as(uB,'select count(*)::text from public.proposals_v2')='0','B reads no A proposals');
 perform pg_temp.check_that(pg_temp.run_as(uB,'select count(*)::text from public.commercial_channels')='0','B reads no A channels');
 perform pg_temp.check_that(pg_temp.run_as(uB,'select count(*)::text from public.simulations')='0','B reads no A simulations');
 perform pg_temp.check_that(pg_temp.run_as(uA,'select count(*)::text from public.clients')='1','A reads its own customer');
 -- writes
 perform pg_temp.expect_err(uB,format($q$insert into public.clients(organization_id,full_name,cpf) values(%L,'x','12345678909')$q$,o1),'row-level security','B cannot insert a customer into tenant A');
 perform pg_temp.check_that(pg_temp.run_as(uB,format($q$with u as (update public.clients set full_name='pwn' where id=%L returning 1) select count(*)::text from u$q$,cliA))='0','B cannot update an A customer');
 perform pg_temp.check_that(pg_temp.run_as(uB,format($q$with u as (update public.proposals_v2 set status='cancelled' where id=%L returning 1) select count(*)::text from u$q$,pA))='0','B cannot change an A proposal');
 perform pg_temp.expect_err(uB,format($q$insert into public.commercial_entities(organization_id,legal_name,entity_kind) values(%L,'x','other')$q$,o1),'row-level security','B cannot create a commercial entity in tenant A');
 -- RPC attacks
 perform pg_temp.expect_err(uB,format($q$select public.create_and_publish_commission_rule(%L,%L,'upfront',1,null,null,'gross',now(),null)$q$,chA,ptA),'channel_not_found','B cannot publish a commission rule on an A channel');
 perform pg_temp.expect_err(uAg,format($q$select public.create_and_publish_commission_rule(%L,%L,'upfront',1,null,null,'gross',now(),null)$q$,chA,ptA),'forbidden','agent cannot publish rules');
 perform pg_temp.expect_err(uB,format($q$select public.freeze_proposal_commercial_route(%L,%L,%L,null)$q$,pA,chA,gen_random_uuid()),'.','B cannot freeze the route of an A proposal');
 perform pg_temp.check_that(not exists(select 1 from public.proposal_commercial_snapshots where proposal_id=pA),'no snapshot appeared for the A proposal');
 perform pg_temp.expect_err(uB,format($q$select public.prepare_proposal_documents(%L)$q$,pA),'.','B cannot prepare documents for an A proposal');
 perform pg_temp.expect_err(uB,format($q$select public.send_proposal_to_digitization(%L)$q$,pA),'.','B cannot send an A proposal to digitization');
 perform pg_temp.expect_err(uB,format($q$select public.transition_operational_case(%L,'digitizing',null)$q$,gen_random_uuid()),'operational_case_not_found_or_forbidden','B cannot transition a foreign/unknown case');
 perform pg_temp.expect_err(uB,format($q$select public.confirm_proposal_paid_from_import(%L)$q$,gen_random_uuid()),'.','B cannot confirm PAID from a foreign decision');
 select count(*) into n0 from public.clients where organization_id=o1;
 perform pg_temp.run_as(uB,$q$select public.create_customer_with_timeline('Synthetic B','98765432100',null,null,'corban_os')::text$q$);
 select count(*) into n1 from public.clients where organization_id=o1;
 perform pg_temp.check_that(n0=n1 and (select count(*) from public.clients where organization_id=o2)=1,'B customer creation lands only in tenant B');
 perform pg_temp.check_that((select status from public.proposals_v2 where id=pA)='draft','A proposal status untouched');

 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %
%',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED' end,r;
end $test$;
