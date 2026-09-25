-- Tenant A/B adversarial contract: a member of tenant B attacks tenant A through reads, direct writes and RPCs.
-- Covers customers, proposals, simulations, the commission engine, commission receipts and seller payout.
-- Synthetic fixtures only, one transaction rolled back. Pass = notice 'RESULTS: ALL PASS'; any failure raises.
-- Rewritten on 2026-09-24: the legacy network model (channels, entities, route snapshots, rules) was removed in F5.
begin;
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid(); uA uuid:=gen_random_uuid(); uAg uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid();
 pA uuid:=gen_random_uuid(); cliA uuid:=gen_random_uuid(); accA uuid:=gen_random_uuid();
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
 insert into public.payout_accounts(id,organization_id,user_id) values(accA,o1,uAg);
 set local session_replication_role='origin';

 -- reads
 perform pg_temp.check_that(pg_temp.run_as(uB,'select count(*)::text from public.clients')='0','B reads no A customers');
 perform pg_temp.check_that(pg_temp.run_as(uB,'select count(*)::text from public.proposals_v2')='0','B reads no A proposals');
 perform pg_temp.check_that(pg_temp.run_as(uB,'select count(*)::text from public.simulations')='0','B reads no A simulations');
 perform pg_temp.check_that(pg_temp.run_as(uB,'select count(*)::text from public.proposal_commission_calcs')='0','B reads no A commission calculation');
 perform pg_temp.check_that(pg_temp.run_as(uB,'select count(*)::text from public.commission_receipts')='0','B reads no A commission receipt');
 perform pg_temp.check_that(pg_temp.run_as(uB,'select count(*)::text from public.payout_accounts')='0','B reads no A payout account');
 perform pg_temp.check_that(pg_temp.run_as(uB,'select count(*)::text from public.payout_entries')='0','B reads no A payout entry');
 perform pg_temp.check_that(pg_temp.run_as(uA,'select count(*)::text from public.clients')='1','A reads its own customer');
 -- direct writes
 perform pg_temp.expect_err(uB,format($q$insert into public.clients(organization_id,full_name,cpf) values(%L,'x','12345678909')$q$,o1),'row-level security|permission denied','B cannot insert a customer into tenant A');
 perform pg_temp.check_that(pg_temp.run_as(uB,format($q$with u as (update public.clients set full_name='pwn' where id=%L returning 1) select count(*)::text from u$q$,cliA))='0','B cannot update an A customer');
 perform pg_temp.check_that(pg_temp.run_as(uB,format($q$with u as (update public.proposals_v2 set status='cancelled' where id=%L returning 1) select count(*)::text from u$q$,pA))='0','B cannot change an A proposal');
 perform pg_temp.expect_err(uB,format($q$insert into public.payout_entries(organization_id,account_id,kind,amount,effective_on,status) values(%L,%L,'bonus',100,current_date,'approved')$q$,o1,accA),'permission denied|row-level security|governed','B cannot write a payout entry into tenant A');
 -- RPC attacks
 perform pg_temp.expect_err(uB,format($q$select public.calculate_proposal_commission(%L)$q$,pA),'not_authorized','B cannot calculate the commission of an A proposal');
 perform pg_temp.expect_err(uB,format($q$select public.proposal_commission_mine(%L)$q$,pA),'not_authorized','B cannot read the commission view of an A proposal');
 perform pg_temp.expect_err(uB,format($q$select public.save_commission_rule(%L,'global',null,'cascade',6,40,10,15,75,true,'x')$q$,o1),'.','B cannot save a commission rule in tenant A');
 perform pg_temp.expect_err(uB,format($q$select public.import_receipt_report(%L,'bank',gen_random_uuid(),'upfront',current_date,'x.csv',md5('x'),null,'[]'::jsonb)$q$,o1),'.','B cannot import a receipt report into tenant A');
 perform pg_temp.expect_err(uB,format($q$select public.finance_alerts(%L)$q$,o1),'.','B cannot read the finance alerts of tenant A');
 perform pg_temp.expect_err(uB,format($q$select public.ensure_payout_account(%L,null,%L)$q$,o1,uAg),'not_authorized','B cannot open a payout account in tenant A');
 perform pg_temp.expect_err(uB,format($q$select public.add_payout_entry(%L,'bonus',100,null,'ataque',current_date,1)$q$,accA),'not_authorized','B cannot post an entry to an A payout account');
 perform pg_temp.expect_err(uB,format($q$select public.close_payout_period(%L,current_date)$q$,o1),'not_authorized','B cannot close the payout period of tenant A');
 perform pg_temp.check_that(pg_temp.run_as(uB,format($q$select count(*)::text from public.payout_account_summaries(%L)$q$,o1))='0','B sees no payout summary of tenant A');
 perform pg_temp.expect_err(uAg,format($q$select public.close_payout_period(%L,current_date)$q$,o1),'not_authorized','an agent of A cannot close the payout period');
 perform pg_temp.expect_err(uB,format($q$select public.prepare_proposal_documents(%L)$q$,pA),'.','B cannot prepare documents for an A proposal');
 perform pg_temp.expect_err(uB,format($q$select public.send_proposal_to_digitization(%L)$q$,pA),'.','B cannot send an A proposal to digitization');
 perform pg_temp.expect_err(uB,format($q$select public.transition_operational_case(%L,'digitizing',null)$q$,gen_random_uuid()),'operational_case_not_found_or_forbidden','B cannot transition a foreign/unknown case');
 select count(*) into n0 from public.clients where organization_id=o1;
 perform pg_temp.run_as(uB,$q$select public.create_customer_with_timeline('Synthetic B','98765432100',null,null,'corban_os')::text$q$);
 select count(*) into n1 from public.clients where organization_id=o1;
 perform pg_temp.check_that(n0=n1 and (select count(*) from public.clients where organization_id=o2)=1,'B customer creation lands only in tenant B');
 perform pg_temp.check_that((select status from public.proposals_v2 where id=pA)='draft','A proposal status untouched');
 perform pg_temp.check_that(not exists(select 1 from public.payout_entries where account_id=accA),'no payout entry appeared on the A account');

 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 if k>0 then raise exception 'RESULTS: % FAILED
%',k,r; end if;
 raise notice 'RESULTS: ALL PASS (% checks)',(select count(*) from t_res);
end $test$;
rollback;
