-- Rollback-only contract for 20260920_leads_v1.sql (execute the migration earlier in the same transaction, or apply it).
-- Ends with RAISE EXCEPTION so nothing persists; pass = message starting with 'RESULTS: ALL PASS'.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid(); uS uuid:=gen_random_uuid(); uA uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid(); uM uuid:=gen_random_uuid(); uR uuid:=gen_random_uuid();
 l1 uuid; l1b uuid; l2 uuid; l3 uuid; cust uuid; cust2 uuid; lm1 uuid; lm2 uuid; r text; k int;
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

 insert into auth.users(id) values(uS),(uA),(uB),(uM),(uR);
 insert into public.organizations(id,name,document) values(o1,'L-A','doc-'||o1),(o2,'L-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role,status) values(o1,uS,'supervisor','active'),(o1,uA,'agent','active'),(o2,uB,'admin','active'),(o1,uM,'agent','active'),(o2,uM,'agent','active'),(o1,uR,'admin','revoked');

 l1:=pg_temp.run_as(uA,format($q$select public.create_lead(%L::uuid,'whatsapp','Maria Teste','5511999990000','maria@example.com','campanha-x','wa-123')::text$q$,o1))::uuid;
 l1b:=pg_temp.run_as(uA,format($q$select public.create_lead(%L::uuid,'whatsapp','Maria Teste','5511999990000','maria@example.com','campanha-x','wa-123')::text$q$,o1))::uuid;
 perform pg_temp.check_that(l1=l1b and (select count(*) from public.leads where organization_id=o1)=1,'intake is idempotent by (organization, channel, external_ref): webhook replay creates no duplicate');
 perform pg_temp.check_that((select count(*) from public.lead_events where lead_id=l1)=1,'replay adds no timeline noise');
 perform pg_temp.check_that((select channel='whatsapp' and campaign='campanha-x' and status='new' and owner_user_id=uA from public.leads where id=l1),'provenance (channel/campaign/ref) and owner recorded');
 perform pg_temp.expect_err(uB,format($q$select public.create_lead(%L::uuid,'manual','Cross Tenant')$q$,o1),'lead_forbidden','tenant B cannot create a lead in tenant A');
 perform pg_temp.expect_err(uR,format($q$select public.create_lead(%L::uuid,'manual','Revoked User')$q$,o1),'lead_forbidden','revoked membership cannot create leads');
 perform pg_temp.expect_err(uB,format($q$select public.set_lead_status(%L,'contacted')$q$,l1),'lead_forbidden','tenant B cannot change a tenant A lead (known UUID)');
 perform pg_temp.expect_err(uB,format($q$select public.convert_lead_to_customer(%L,'12345678901')$q$,l1),'lead_forbidden','tenant B cannot convert a tenant A lead');
 perform pg_temp.expect_err(uA,'insert into public.leads(organization_id,channel,full_name) values (gen_random_uuid(),''manual'',''x'')','permission denied','no direct insert');
 perform pg_temp.expect_err(uA,format($q$update public.leads set status='converted' where id=%L$q$,l1),'permission denied','no direct update (status cannot be forged)');
 perform pg_temp.expect_err(uA,'delete from public.leads','permission denied','no delete');
 perform pg_temp.expect_err(uA,format($q$insert into public.lead_events(organization_id,lead_id,event_type) values(%L,%L,'note')$q$,o1,l1),'permission denied','timeline is append-only through the RPCs only');
 perform pg_temp.check_that(pg_temp.run_as(uB,'select count(*)::text from public.leads')='0','tenant B reads no tenant A leads');
 perform pg_temp.check_that(pg_temp.run_as(uB,'select count(*)::text from public.lead_events')='0','tenant B reads no tenant A timeline');

 perform pg_temp.run_as(uA,format($q$select public.set_lead_status(%L,'contacted')::text$q$,l1));
 perform pg_temp.run_as(uA,format($q$select public.set_lead_status(%L,'qualified')::text$q$,l1));
 perform pg_temp.expect_err(uA,format($q$select public.set_lead_status(%L,'converted')$q$,l1),'invalid_lead_status','converted can only be reached by conversion');
 perform pg_temp.expect_err(uA,format($q$select public.set_lead_status(%L,'lost')$q$,l1),'lost_reason_required','lost needs a reason');
 l2:=pg_temp.run_as(uA,format($q$select public.create_lead(%L::uuid,'meta_ads','Joao Perdido',null,null,'c2','meta-9')::text$q$,o1))::uuid;
 perform pg_temp.run_as(uA,format($q$select public.set_lead_status(%L,'lost','sem interesse')::text$q$,l2));
 perform pg_temp.expect_err(uA,format($q$select public.set_lead_status(%L,'new')$q$,l2),'lead_reactivation_requires_supervisor','an agent cannot reactivate a lost lead');
 perform pg_temp.expect_err(uA,format($q$select public.convert_lead_to_customer(%L,'12345678901')$q$,l2),'lost_lead_must_be_reactivated','a lost lead cannot be converted directly');
 perform pg_temp.run_as(uS,format($q$select public.set_lead_status(%L,'new')::text$q$,l2));
 perform pg_temp.check_that((select count(*) from public.lead_events where lead_id=l2 and event_type='reactivated')=1,'supervisor reactivation is on the timeline');

 perform pg_temp.expect_err(uA,format($q$select public.convert_lead_to_customer(%L,'123')$q$,l1),'invalid_cpf_format','conversion validates the CPF');
 cust:=pg_temp.run_as(uA,format($q$select public.convert_lead_to_customer(%L,'12345678901')::text$q$,l1))::uuid;
 perform pg_temp.check_that((select organization_id=o1 and original_source='lead:whatsapp' and full_name='Maria Teste' from public.clients where id=cust),'customer created in the LEAD organization with provenance');
 perform pg_temp.check_that((select status='converted' and customer_id=cust and converted_at is not null from public.leads where id=l1),'lead is converted and linked (write-once)');
 perform pg_temp.check_that(pg_temp.run_as(uA,format($q$select public.convert_lead_to_customer(%L,'12345678901')::text$q$,l1))::uuid=cust,'conversion replay returns the same customer, no duplicate');
 perform pg_temp.check_that((select count(*) from public.clients where organization_id=o1 and cpf='12345678901')=1,'exactly one customer');
 perform pg_temp.expect_err(uA,format($q$select public.set_lead_status(%L,'contacted')$q$,l1),'lead_already_converted','a converted lead cannot change status');
 l3:=pg_temp.run_as(uA,format($q$select public.create_lead(%L::uuid,'manual','Duplicada Cpf')::text$q$,o1))::uuid;
 perform pg_temp.expect_err(uA,format($q$select public.convert_lead_to_customer(%L,'12345678901')$q$,l3),'duplicate key|23505|unique','conversion cannot create a second customer with the same CPF in the tenant');
 perform pg_temp.check_that((select status='new' and customer_id is null from public.leads where id=l3),'failed conversion leaves the lead untouched (atomic)');

 lm1:=pg_temp.run_as(uM,format($q$select public.create_lead(%L::uuid,'api','Multi A',null,null,null,'x-1')::text$q$,o1))::uuid;
 lm2:=pg_temp.run_as(uM,format($q$select public.create_lead(%L::uuid,'api','Multi B',null,null,null,'x-1')::text$q$,o2))::uuid;
 perform pg_temp.check_that((select organization_id from public.leads where id=lm1)=o1 and (select organization_id from public.leads where id=lm2)=o2 and lm1<>lm2,'multi-org user: explicit organization decides; same external_ref in two tenants does not collide');
 perform pg_temp.check_that(not exists(select 1 from information_schema.columns where table_schema='public' and table_name in ('leads','lead_events') and column_name ~* '(commission|amount|split|fee|payout)'),'CRM tables carry no financial columns');
 perform pg_temp.check_that((select count(*) from public.lead_events where lead_id=l1)=4,'timeline: created, contacted, qualified, converted');

 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %
%',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED' end,r;
end $test$;
