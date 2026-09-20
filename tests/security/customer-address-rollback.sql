-- Rollback-only adversarial harness for 20261003_customer_address_v1. Run the migration text first (same transaction until LIVE), then this DO block. Ends with RAISE EXCEPTION.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid(); uA uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid(); uX uuid:=gen_random_uuid();
 c1 uuid:=gen_random_uuid(); c2 uuid:=gen_random_uuid(); r text; k int;
begin
 create temp table t_res(label text, pass boolean) on commit drop;
 create function pg_temp.u(p_uid uuid,q text) returns text language plpgsql as $f$
 declare r text;
 begin
  perform set_config('request.jwt.claims',json_build_object('sub',p_uid,'role','authenticated')::text,true);
  perform set_config('request.jwt.claim.sub',p_uid::text,true);
  set local role authenticated;
  begin execute q into r; exception when others then reset role; raise; end;
  reset role; return r;
 end $f$;
 create function pg_temp.expect_err(p_uid uuid,q text,pat text,label text) returns void language plpgsql as $f$
 declare msg text;
 begin
  begin perform pg_temp.u(p_uid,q); msg:=null; exception when others then msg:=sqlerrm; end;
  if msg is null then insert into t_res values(label||' [UNEXPECTED SUCCESS]',false);
  elsif msg !~ pat then insert into t_res values(label||' [got: '||msg||']',false);
  else insert into t_res values(label,true); end if;
 end $f$;
 create function pg_temp.check_that(cond boolean,label text) returns void language plpgsql as $f$
 begin insert into t_res values(label,coalesce(cond,false)); end $f$;
 insert into auth.users(id) values(uA),(uB),(uX);
 insert into public.organizations(id,name,document) values(o1,'ADDR-A','doc-'||o1),(o2,'ADDR-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role,status) values(o1,uA,'agent','active'),(o2,uB,'agent','active'),(o1,uX,'agent','inactive');
 insert into public.clients(id,organization_id,full_name,cpf) values(c1,o1,'Cliente A','00000000001'),(c2,o2,'Cliente B','00000000002');

 perform pg_temp.check_that(pg_temp.u(uA,format($q$select public.save_customer_address(%L,'69.900-000','Rua Sintetica','12','ap 3','Centro','Rio Branco','ac','cep_lookup')::text$q$,c1))=c1::text,'a member saves the address of a customer of the own tenant (mask and lower-case UF accepted)');
 perform pg_temp.check_that((select zip='69900000' and state='AC' and city='Rio Branco' and organization_id=o1 and source='cep_lookup' and updated_by=uA from public.client_addresses where client_id=c1),'zip normalised to 8 digits, UF upper-cased, tenant taken from the customer, actor recorded');
 perform pg_temp.check_that(pg_temp.u(uA,format($q$select public.save_customer_address(%L,'69900000','Rua Nova',null,null,'','Rio Branco','AC','cep_lookup_edited')::text$q$,c1))=c1::text,'second save returns the customer id');
 perform pg_temp.check_that((select street='Rua Nova' and number is null and district is null and source='cep_lookup_edited' from public.client_addresses where client_id=c1) and (select count(*) from public.client_addresses where client_id=c1)=1,'saving again updates the same row (one address per customer); blanks become NULL');
 perform pg_temp.expect_err(uA,format($q$select public.save_customer_address(%L,'69900000','x',null,null,null,null,null,'manual')$q$,c2),'customer_not_found_or_forbidden','a customer of another tenant is invisible');
 perform pg_temp.expect_err(uB,format($q$select public.save_customer_address(%L,'69900000','x',null,null,null,null,null,'manual')$q$,c1),'customer_not_found_or_forbidden','tenant B cannot write on tenant A customer');
 perform pg_temp.expect_err(uX,format($q$select public.save_customer_address(%L,'69900000','x',null,null,null,null,null,'manual')$q$,c1),'customer_not_found_or_forbidden|not_authorized','an inactive member cannot write');
 perform pg_temp.expect_err(uA,format($q$select public.save_customer_address(%L,'123','x',null,null,null,null,null,'manual')$q$,c1),'invalid_zip','short zip refused');
 perform pg_temp.expect_err(uA,format($q$select public.save_customer_address(%L,'abcdefgh','x',null,null,null,null,null,'manual')$q$,c1),'invalid_zip','non numeric zip refused');
 perform pg_temp.expect_err(uA,format($q$select public.save_customer_address(%L,'69900000','x',null,null,null,null,'ACRE','manual')$q$,c1),'invalid_state','UF must be two letters');
 perform pg_temp.expect_err(uA,format($q$select public.save_customer_address(%L,'69900000','x',null,null,null,null,'AC','whatever')$q$,c1),'invalid_source','unknown source refused');
 perform pg_temp.expect_err(uA,format($q$insert into public.client_addresses(client_id,organization_id,zip) values(%L,%L,'69900000')$q$,c1,o1),'address_write_requires_governed_rpc','direct insert refused');
 perform pg_temp.expect_err(uA,format($q$update public.client_addresses set city='Hack' where client_id=%L$q$,c1),'address_write_requires_governed_rpc','direct update refused');
 perform pg_temp.expect_err(uA,format($q$delete from public.client_addresses where client_id=%L$q$,c1),'permission denied','delete never granted');
 perform pg_temp.check_that(pg_temp.u(uB,'select count(*)::text from public.client_addresses')='0' and pg_temp.u(uA,'select count(*)::text from public.client_addresses')='1','each tenant reads only its own addresses');
 perform pg_temp.expect_err(uA,format($q$select public.save_customer_address(null,'69900000','x',null,null,null,null,null,'manual')$q$),'customer_not_found_or_forbidden','null customer refused');
 perform set_config('corban.address_rpc','on',true);
 perform pg_temp.expect_err(uA,format($q$insert into public.client_addresses(client_id,organization_id,zip) values(%L,%L,'69900000')$q$,c2,o1),'address_tenant_mismatch|row-level security|duplicate','even with a forged token the tenant must match the customer');
 perform set_config('corban.address_rpc','off',true);
 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and p.proname not in ('attach_import_batch_adapter','caller_role_in','commercial_route','import_row_evidence','lead_write','list_import_rows','bootstrap_organization_admin','get_user_organization_id')),'DEFINER inventory unchanged');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p,lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a where p.pronamespace='public'::regnamespace and p.proname='save_customer_address' and (a.grantee=0 or a.grantee=(select oid from pg_roles where rolname='anon'))),'RPC not executable by PUBLIC/anon');
 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED: '||left(r,900) end;
end $test$;
