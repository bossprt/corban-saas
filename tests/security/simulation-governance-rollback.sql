-- Rollback-only adversarial harness for 20260926_simulation_governance_v1.
-- Run in ONE simple-query transaction: the migration text first, then this DO block (when the migration is LIVE, only the DO block).
-- Ends with RAISE EXCEPTION; pass = 'RESULTS: ALL PASS'. All rows are synthetic and rolled back.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid();
 uAg uuid:=gen_random_uuid(); uS uuid:=gen_random_uuid(); uM uuid:=gen_random_uuid(); uAd uuid:=gen_random_uuid(); uR uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid(); uN uuid:=gen_random_uuid();
 c1 uuid:=gen_random_uuid(); c2 uuid:=gen_random_uuid(); pt1 uuid:=gen_random_uuid(); pt2 uuid:=gen_random_uuid(); v1 uuid:=gen_random_uuid(); vd uuid:=gen_random_uuid(); vB uuid:=gen_random_uuid(); vnc uuid:=gen_random_uuid();
 sim uuid; sim2 uuid; prop uuid; fe int; fc int; r text; k int; rec record;
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
 create function pg_temp.mk(p_uid uuid,p_cust uuid,p_ver uuid,p_amt text,p_term int) returns text language sql as $f$
  select pg_temp.u(p_uid,format('select public.create_simulation(%L,%L,%s,%s)::text',p_cust,p_ver,p_amt,p_term)) $f$;
 create function pg_temp.mk_err(p_uid uuid,p_cust uuid,p_ver uuid,p_amt text,p_term text,pat text,label text) returns void language sql as $f$
  select pg_temp.expect_err('authenticated',p_uid,format('select public.create_simulation(%L,%L,%s,%s)',p_cust,p_ver,p_amt,p_term),pat,label) $f$;

 insert into auth.users(id) values(uAg),(uS),(uM),(uAd),(uR),(uB),(uN);
 insert into public.organizations(id,name,document) values(o1,'SIM-A','doc-'||o1),(o2,'SIM-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role,status) values(o1,uAg,'agent','active'),(o1,uS,'supervisor','active'),(o1,uM,'manager','active'),(o1,uAd,'admin','active'),(o1,uR,'agent','inactive'),(o2,uB,'admin','active');
 set local session_replication_role='replica';
 insert into public.clients(id,organization_id,full_name,cpf) values(c1,o1,'Cliente Sintetico A','00000000001'),(c2,o2,'Cliente Sintetico B','00000000002');
 insert into public.product_tables(id,organization_id,route_id,code,name,status) values(pt1,o1,gen_random_uuid(),'T-SIM','Tabela sintetica','active'),(pt2,o2,gen_random_uuid(),'T-SIMB','Tabela B','active');
 insert into public.product_table_versions(id,organization_id,product_table_id,version,status,rate,coefficient,term_min,term_max,published_at,metadata) values
  (v1,o1,pt1,1,'published',1.5,0.02,12,84,now(),'{"commission_pct":7.5}'),
  (vd,o1,pt1,2,'draft',1.5,0.02,12,84,null,'{}'),
  (vB,o2,pt2,1,'published',1.9,0.03,12,84,now(),'{}'),
  (vnc,o1,pt1,3,'published',1.5,null,null,null,now(),'{}');
 set local session_replication_role='origin';
 select count(*) into fe from public.financial_events; select count(*) into fc from public.financial_reconciliation_cases;

 -- ---- surface
 perform pg_temp.expect_err('anon',null,format('select public.create_simulation(%L,%L,1000,12)',c1,v1),'permission denied','anon cannot call create_simulation');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('create_simulation','guard_simulation_write','create_proposal_from_simulation') and p.prosecdef),'no SECURITY DEFINER among the touched functions');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and p.proname not in ('attach_import_batch_adapter','caller_role_in','commercial_route','import_row_evidence','lead_write','list_import_rows','bootstrap_organization_admin','get_user_organization_id')),'DEFINER inventory equals the 8 reviewed functions');
 perform pg_temp.check_that(has_column_privilege('authenticated','public.simulations','status','UPDATE') and not has_column_privilege('authenticated','public.simulations','requested_amount','UPDATE') and not has_column_privilege('authenticated','public.simulations','expected_commission_amount','UPDATE') and not has_column_privilege('authenticated','public.simulations','organization_id','UPDATE'),'authenticated may UPDATE only status/updated_at');
 perform pg_temp.check_that(not has_table_privilege('authenticated','public.simulations','DELETE'),'authenticated has no DELETE');
 perform pg_temp.check_that(not has_column_privilege('authenticated','public.simulations','expected_commission_amount','INSERT') and not has_column_privilege('authenticated','public.simulations','released_amount','INSERT'),'authenticated cannot INSERT commission or released amount');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p,lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a where p.pronamespace='public'::regnamespace and p.proname='create_simulation' and (a.grantee=0 or a.grantee=(select oid from pg_roles where rolname='anon'))),'create_simulation not executable by PUBLIC/anon');

 -- ---- legitimate path, every role that may work
 sim:=pg_temp.mk(uAg,c1,v1,'10000.005',36)::uuid;
 perform pg_temp.check_that((select organization_id=o1 and customer_id=c1 and created_by=uAg and status='calculated' and requested_amount=10000.01 and installment_amount=200.00 and rate=1.5 and coefficient=0.02 and term=36 from public.simulations where id=sim),'agent creates a simulation: tenant derived, actor recorded, installment computed by the database');
 perform pg_temp.check_that((select expected_commission_amount is null and released_amount is null from public.simulations where id=sim),'expected commission and released amount stay NULL (no governed source)');
 perform pg_temp.check_that((select not (result_snapshot::text ilike '%commission%') and not (input_snapshot::text ilike '%commission%') from public.simulations where id=sim),'table metadata (may carry commercial terms) is not copied into the snapshot');
 perform pg_temp.check_that(pg_temp.mk(uS,c1,v1,'5000',12)::uuid is not null and pg_temp.mk(uM,c1,v1,'5000',84)::uuid is not null and pg_temp.mk(uAd,c1,v1,'5000',24)::uuid is not null,'supervisor, manager and admin can create too');
 sim2:=pg_temp.mk(uAg,c1,vnc,'1000',12)::uuid;
 perform pg_temp.check_that((select installment_amount is null and result_snapshot->>'calculation'='manual_pending' from public.simulations where id=sim2),'table without coefficient: no invented installment');

 -- ---- attacks through the RPC
 perform pg_temp.mk_err(uAg,c2,v1,'1000','12','customer_not_found_or_forbidden','tenant A user + customer of tenant B');
 perform pg_temp.mk_err(uB,c1,vB,'1000','12','customer_not_found_or_forbidden','tenant B user + customer of tenant A');
 perform pg_temp.mk_err(uAg,c1,vB,'1000','12','published_table_version_not_available','tenant A customer + table version of tenant B');
 perform pg_temp.mk_err(uAg,c1,vd,'1000','12','published_table_version_not_available','unpublished (draft) table version');
 perform pg_temp.mk_err(uAg,c1,gen_random_uuid(),'1000','12','published_table_version_not_available','unknown table version');
 perform pg_temp.mk_err(uAg,c1,v1,'1000','6','term_below_table_minimum','term below the table minimum');
 perform pg_temp.mk_err(uAg,c1,v1,'1000','120','term_above_table_maximum','term above the table maximum');
 perform pg_temp.mk_err(uAg,c1,v1,'0','12','invalid_amount','zero amount');
 perform pg_temp.mk_err(uAg,c1,v1,'-5','12','invalid_amount','negative amount');
 perform pg_temp.mk_err(uAg,c1,v1,'null','12','invalid_amount','null amount');
 perform pg_temp.mk_err(uAg,c1,v1,'1000000000000','12','invalid_amount','absurd amount');
 perform pg_temp.mk_err(uAg,c1,v1,'1000','0','invalid_term','zero term');
 perform pg_temp.mk_err(uAg,c1,v1,'1000','null','invalid_term','null term');
 perform pg_temp.mk_err(uR,c1,v1,'1000','12','customer_not_found_or_forbidden','inactive membership cannot create (customer not even visible)');
 perform pg_temp.mk_err(uN,c1,v1,'1000','12','customer_not_found_or_forbidden','user without membership cannot create');
 perform pg_temp.check_that((select count(*) from public.simulations where organization_id=o2)=0,'no simulation ever landed in tenant B');

 -- ---- direct writes are closed (forged tenant, actor, commission, status)
 perform pg_temp.expect_err('authenticated',uAg,format($q$insert into public.simulations(organization_id,customer_id,product_table_version_id,status,requested_amount,created_by) values(%L,%L,%L,'calculated',1,%L)$q$,o1,c1,v1,uAd),'governed_rpc','agent direct INSERT with forged created_by');
 perform pg_temp.expect_err('authenticated',uAd,format($q$insert into public.simulations(organization_id,customer_id,product_table_version_id,status,requested_amount) values(%L,%L,%L,'calculated',1)$q$,o1,c1,v1),'governed_rpc','not even admin can INSERT directly');
 perform pg_temp.expect_err('authenticated',uAg,format($q$insert into public.simulations(organization_id,customer_id,product_table_version_id,status,requested_amount,expected_commission_amount) values(%L,%L,%L,'calculated',1,999999)$q$,o1,c1,v1),'permission denied','forged expected_commission_amount on INSERT');
 perform pg_temp.expect_err('authenticated',uAg,format($q$insert into public.simulations(organization_id,customer_id,product_table_version_id,status,requested_amount) values(%L,%L,%L,'calculated',1)$q$,o2,c2,vB),'governed_rpc|row-level security','forged organization_id (tenant B) on INSERT');
 perform pg_temp.expect_err('authenticated',uAg,format($q$update public.simulations set expected_commission_amount=999999 where id=%L$q$,sim),'permission denied','forged expected_commission_amount on UPDATE');
 perform pg_temp.expect_err('authenticated',uAd,format($q$update public.simulations set requested_amount=1 where id=%L$q$,sim),'permission denied','requested_amount is not updatable');
 perform pg_temp.expect_err('authenticated',uAd,format($q$update public.simulations set organization_id=%L where id=%L$q$,o2,sim),'permission denied','organization_id is not updatable');
 perform pg_temp.expect_err('authenticated',uAg,format($q$update public.simulations set status='selected' where id=%L$q$,sim),'governed_rpc','status cannot be flipped directly');
 perform pg_temp.expect_err('authenticated',uAd,format($q$delete from public.simulations where id=%L$q$,sim),'permission denied','no DELETE');
 perform pg_temp.u(uB,format($q$with x as (update public.simulations set status='cancelled' where id=%L returning 1) select count(*)::text from x$q$,sim));
 perform pg_temp.check_that((select status='calculated' from public.simulations where id=sim),'tenant B UPDATE of a tenant A simulation touches nothing (RLS filters the row)');
 perform pg_temp.expect_err('anon',null,'select * from public.simulations','permission denied','anon cannot read');

 -- ---- visibility
 perform pg_temp.check_that(pg_temp.u(uB,'select count(*)::text from public.simulations')='0','tenant B reads no tenant A simulation');
 perform pg_temp.check_that(pg_temp.u(uAg,'select count(*)::text from public.simulations')::int>=5,'tenant A members read their simulations');
 perform pg_temp.check_that(pg_temp.u(uR,'select count(*)::text from public.simulations')='0' and pg_temp.u(uN,'select count(*)::text from public.simulations')='0','inactive / no membership read nothing');

 -- ---- proposal linkage and immutability
 perform pg_temp.expect_err('authenticated',uB,format($q$select public.create_proposal_from_simulation(%L)$q$,sim),'simulation_not_found_or_forbidden','tenant B cannot create a proposal from a tenant A simulation');
 prop:=pg_temp.u(uS,format($q$select public.create_proposal_from_simulation(%L)::text$q$,sim))::uuid;
 perform pg_temp.check_that((select status='draft' and expected_commission_amount is null and requested_amount=10000.01 and organization_id=o1 from public.proposals_v2 where id=prop),'proposal created from the governed simulation carries NO commission');
 perform pg_temp.check_that((select status='selected' from public.simulations where id=sim),'the simulation is now selected (flip ran inside the guard token)');
 perform pg_temp.expect_err('authenticated',uS,format($q$select public.create_proposal_from_simulation(%L)$q$,sim),'simulation_not_available_for_proposal','a simulation cannot originate two proposals');
 perform pg_temp.expect_err('authenticated',uAd,format($q$update public.simulations set status='cancelled' where id=%L$q$,sim),'governed_rpc','a used simulation cannot be cancelled directly');
 perform pg_temp.expect_err('service_role',null,format($q$update public.simulations set requested_amount=1 where id=%L$q$,sim),'.','a used simulation is immutable even for service_role (existing guard)');
 perform pg_temp.check_that((select requested_amount=10000.01 from public.simulations where id=sim),'used simulation values unchanged after every attack');

 -- ---- revocation mid-flow
 sim2:=pg_temp.mk(uAg,c1,v1,'2000',24)::uuid;
 set local session_replication_role='replica';
 update public.organization_memberships set status='inactive' where user_id=uAg;
 set local session_replication_role='origin';
 perform pg_temp.mk_err(uAg,c1,v1,'2000','24','customer_not_found_or_forbidden','after deactivation the same user cannot create');
 perform pg_temp.expect_err('authenticated',uAg,format($q$select public.create_proposal_from_simulation(%L)$q$,sim2),'simulation_not_found_or_forbidden','after deactivation the same user cannot turn a simulation into a proposal');

 -- ---- financial firewall
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe and (select count(*) from public.financial_reconciliation_cases)=fc,'simulations and proposals created no financial truth');

 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED: '||r end;
end $test$;
