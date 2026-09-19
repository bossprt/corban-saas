-- Rollback-only adversarial harness for 20260929_catalog_publish_v1. Run the migration text first in the same transaction (until LIVE), then this DO block.
-- Ends with RAISE EXCEPTION; pass = 'RESULTS: ALL PASS'. Every row is synthetic.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid();
 uAd uuid:=gen_random_uuid(); uMg uuid:=gen_random_uuid(); uSv uuid:=gen_random_uuid(); uAg uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid(); uR uuid:=gen_random_uuid();
 bk uuid:=gen_random_uuid(); pv uuid:=gen_random_uuid(); ag uuid:=gen_random_uuid(); pr uuid:=gen_random_uuid(); md uuid:=gen_random_uuid(); dt uuid:=gen_random_uuid(); dt2 uuid:=gen_random_uuid();
 rt uuid:=gen_random_uuid(); rtB uuid:=gen_random_uuid(); tb uuid:=gen_random_uuid(); tbB uuid:=gen_random_uuid(); cu uuid:=gen_random_uuid();
 v1 uuid; v2 uuid; v3 uuid; vB uuid; t1 uuid; t2 uuid; sim uuid; prop uuid; fe int; r text; k int; n int;
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
 create function pg_temp.err_of(p_uid uuid,q text) returns text language plpgsql as $f$
 declare msg text;
 begin
  begin perform pg_temp.u(p_uid,q); msg:=null; exception when others then msg:=sqlerrm; end;
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
 create function pg_temp.ins_version(p_uid uuid,p_org uuid,p_table uuid,p_ver int,p_status text,p_rate text,p_coef text) returns text language sql as $f$
  select pg_temp.u(p_uid,format($q$with x as (insert into public.product_table_versions(organization_id,product_table_id,version,status,rate,coefficient,term_min,term_max,published_at) values(%L,%L,%s,%L,%s,%s,12,84,case when %L='draft' then null else now() end) returning id) select id::text from x$q$,p_org,p_table,p_ver,p_status,p_rate,p_coef,p_status)) $f$;
 create function pg_temp.ins_template(p_uid uuid,p_org uuid,p_route uuid,p_ver int,p_status text) returns text language sql as $f$
  select pg_temp.u(p_uid,format($q$with x as (insert into public.document_checklist_templates(organization_id,route_id,version,status,name,published_at) values(%L,%L,%s,%L,'Checklist sintetico',case when %L='draft' then null else now() end) returning id) select id::text from x$q$,p_org,p_route,p_ver,p_status,p_status)) $f$;

 insert into auth.users(id) values(uAd),(uMg),(uSv),(uAg),(uB),(uR);
 insert into public.organizations(id,name,document) values(o1,'CAT-A','doc-'||o1),(o2,'CAT-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role,status) values(o1,uAd,'admin','active'),(o1,uMg,'manager','active'),(o1,uSv,'supervisor','active'),(o1,uAg,'agent','active'),(o1,uR,'manager','inactive'),(o2,uB,'admin','active');
 insert into public.banks(id,code,name) values(bk,'B-'||bk,'Banco sintetico'); insert into public.providers(id,code,name,provider_type) values(pv,'P-'||pv,'Provider sintetico','promotora');
 insert into public.agreements(id,bank_id,code,name) values(ag,bk,'A-'||ag,'Convenio sintetico'); insert into public.products(id,code,name) values(pr,'PR-'||pr,'Produto sintetico');
 insert into public.modalities(id,product_id,code,name) values(md,pr,'M-'||md,'Modalidade sintetica');
 insert into public.document_types(id,code,name) values(dt,'D-'||dt,'Documento A'),(dt2,'D-'||dt2,'Documento B');
 insert into public.organization_product_routes(id,organization_id,bank_id,provider_id,agreement_id,product_id,modality_id,status) values(rt,o1,bk,pv,ag,pr,md,'active'),(rtB,o2,bk,pv,ag,pr,md,'active');
 insert into public.product_tables(id,organization_id,route_id,code,name,status) values(tb,o1,rt,'T1','Tabela sintetica','active'),(tbB,o2,rtB,'T1','Tabela B','active');
 insert into public.clients(id,organization_id,full_name,cpf) values(cu,o1,'Cliente Sintetico','00000000001');
 select count(*) into fe from public.financial_events;

 -- surface
 perform pg_temp.check_that(not exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('publish_product_table_version','publish_document_checklist_template','guard_catalog_publication') and p.prosecdef),'no SECURITY DEFINER added');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and p.proname not in ('attach_import_batch_adapter','caller_role_in','commercial_route','import_row_evidence','lead_write','list_import_rows','bootstrap_organization_admin','get_user_organization_id')),'DEFINER inventory equals the 8 reviewed functions');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p,lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a where p.pronamespace='public'::regnamespace and p.proname in ('publish_product_table_version','publish_document_checklist_template') and (a.grantee=0 or a.grantee=(select oid from pg_roles where rolname='anon'))),'publish RPCs not executable by PUBLIC/anon');
 perform pg_temp.expect_err(uAg,format($q$select public.publish_product_table_version(%L)$q$,gen_random_uuid()),'not_authorized|version_not_found','an agent cannot publish');

 -- table versions
 v1:=pg_temp.ins_version(uMg,o1,tb,1,'draft','1.5','0.02')::uuid;
 perform pg_temp.check_that(v1 is not null and (select status='draft' from public.product_table_versions where id=v1),'manager creates a DRAFT version in the browser');
 perform pg_temp.expect_err(uMg,format($q$insert into public.product_table_versions(organization_id,product_table_id,version,status,rate,coefficient,published_at) values(%L,%L,9,'published',1,0.01,now())$q$,o1,tb),'catalog_insert_must_be_draft','INSERT of an already-published version is refused');
 perform pg_temp.expect_err(uAg,format($q$insert into public.product_table_versions(organization_id,product_table_id,version,status,rate,coefficient) values(%L,%L,8,'draft',1,0.01)$q$,o1,tb),'row-level security|permission denied','agent cannot create versions');
 perform pg_temp.expect_err(uSv,format($q$insert into public.product_table_versions(organization_id,product_table_id,version,status,rate,coefficient) values(%L,%L,8,'draft',1,0.01)$q$,o1,tb),'row-level security|permission denied','supervisor cannot create versions (existing policy)');
 perform pg_temp.expect_err(uMg,format($q$update public.product_table_versions set status='published',published_at=now() where id=%L$q$,v1),'catalog_publication_requires_governed_rpc','direct UPDATE draft -> published is refused');
 perform pg_temp.expect_err(uSv,format($q$select public.publish_product_table_version(%L)$q$,v1),'not_authorized|version_not_found','supervisor cannot publish a table version');
 perform pg_temp.expect_err(uAg,format($q$select public.publish_product_table_version(%L)$q$,v1),'not_authorized|version_not_found','agent cannot publish');
 perform pg_temp.expect_err(uR,format($q$select public.publish_product_table_version(%L)$q$,v1),'not_authorized|version_not_found','inactive manager cannot publish');
 vB:=pg_temp.u(uB,format($q$with x as (insert into public.product_table_versions(organization_id,product_table_id,version,status,rate,coefficient) values(%L,%L,1,'draft',1,0.03) returning id) select id::text from x$q$,o2,tbB))::uuid;
 perform pg_temp.expect_err(uB,format($q$select public.publish_product_table_version(%L)$q$,v1),'version_not_found','tenant B cannot publish a tenant A version');
 perform pg_temp.expect_err(uMg,format($q$select public.publish_product_table_version(%L)$q$,vB),'version_not_found','tenant A manager cannot publish a tenant B version');
 v3:=pg_temp.ins_version(uMg,o1,tb,3,'draft','null','null')::uuid;
 perform pg_temp.expect_err(uMg,format($q$select public.publish_product_table_version(%L)$q$,v3),'rate_or_coefficient_required','a version with neither rate nor coefficient cannot be published');
 perform pg_temp.check_that(pg_temp.u(uMg,format($q$select public.publish_product_table_version(%L)::text$q$,v1))=v1::text,'manager publishes through the RPC');
 perform pg_temp.check_that((select status='published' and published_at is not null and effective_from is not null from public.product_table_versions where id=v1),'...and the version is published with its dates');
 perform pg_temp.expect_err(uMg,format($q$select public.publish_product_table_version(%L)$q$,v1),'version_not_draft','publishing twice is refused');
 perform pg_temp.expect_err(uMg,format($q$update public.product_table_versions set rate=99 where id=%L$q$,v1),'published_product_table_version_is_immutable|row-level security','a published version is immutable');
 perform pg_temp.expect_err(uMg,format($q$update public.product_table_versions set status='superseded' where id=%L$q$,v1),'catalog_status_requires_governed_rpc','direct supersede is refused');
 v2:=pg_temp.ins_version(uAd,o1,tb,2,'draft','1.4','0.019')::uuid;
 perform pg_temp.u(uAd,format($q$select public.publish_product_table_version(%L)$q$,v2));
 perform pg_temp.check_that((select status='superseded' from public.product_table_versions where id=v1) and (select status='published' from public.product_table_versions where id=v2) and (select count(*) from public.product_table_versions where product_table_id=tb and status='published')=1,'publishing v2 supersedes v1: exactly one published version per table');

 -- the whole no-SQL chain: agent simulates on the published version, proposal, checklist -> documents
 sim:=pg_temp.u(uAg,format($q$select public.create_simulation(%L,%L,10000,36)::text$q$,cu,v2))::uuid;
 perform pg_temp.check_that((select installment_amount=190.00 from public.simulations where id=sim),'agent simulates on the just-published version (installment 10000 x 0.019)');
 perform pg_temp.expect_err(uAg,format($q$select public.create_simulation(%L,%L,1000,36)$q$,cu,v1),'published_table_version_not_available','a superseded version is no longer simulatable');
 prop:=pg_temp.u(uSv,format($q$select public.create_proposal_from_simulation(%L)::text$q$,sim))::uuid;
 perform pg_temp.expect_err(uSv,format($q$select public.prepare_proposal_documents(%L)$q$,prop),'published_checklist_required','without a published checklist documents cannot be prepared');

 -- checklists (supervisor+)
 t1:=pg_temp.ins_template(uSv,o1,rt,1,'draft')::uuid;
 perform pg_temp.check_that(t1 is not null,'supervisor creates a DRAFT checklist');
 perform pg_temp.expect_err(uSv,format($q$insert into public.document_checklist_templates(organization_id,route_id,version,status,name,published_at) values(%L,%L,7,'published','x',now())$q$,o1,rt),'catalog_insert_must_be_draft','INSERT of a published checklist is refused');
 perform pg_temp.expect_err(uAg,format($q$insert into public.document_checklist_templates(organization_id,route_id,version,status,name) values(%L,%L,6,'draft','x')$q$,o1,rt),'row-level security|permission denied','agent cannot create checklists');
 perform pg_temp.expect_err(uSv,format($q$select public.publish_document_checklist_template(%L)$q$,t1),'template_has_no_items','an empty checklist cannot be published');
 perform pg_temp.u(uSv,format($q$with x as (insert into public.document_checklist_items(organization_id,template_id,document_type_id,label,is_required,sort_order) values(%L,%L,%L,'Documento de identidade',true,0),(%L,%L,%L,'Comprovante',false,1) returning 1) select count(*)::text from x$q$,o1,t1,dt,o1,t1,dt2));
 perform pg_temp.expect_err(uSv,format($q$update public.document_checklist_templates set status='published',published_at=now() where id=%L$q$,t1),'catalog_publication_requires_governed_rpc','direct checklist publication is refused');
 perform pg_temp.expect_err(uAg,format($q$select public.publish_document_checklist_template(%L)$q$,t1),'not_authorized|template_not_found','agent cannot publish a checklist');
 perform pg_temp.expect_err(uB,format($q$select public.publish_document_checklist_template(%L)$q$,t1),'template_not_found','tenant B cannot publish a tenant A checklist');
 perform pg_temp.check_that(pg_temp.u(uSv,format($q$select public.publish_document_checklist_template(%L)::text$q$,t1))=t1::text,'supervisor publishes the checklist through the RPC');
 perform pg_temp.check_that((select status='published' and published_at is not null from public.document_checklist_templates where id=t1),'...and the checklist is published');
 perform pg_temp.expect_err(uSv,format($q$insert into public.document_checklist_items(organization_id,template_id,document_type_id,label,is_required,sort_order) values(%L,%L,%L,'x',true,5)$q$,o1,t1,dt),'checklist_items_require_draft_template|row-level security|duplicate','a published checklist gets no new items');
 perform pg_temp.check_that(pg_temp.u(uAg,format($q$select public.prepare_proposal_documents(%L)::text$q$,prop))='2','the agent prepares proposal documents from the published checklist (2 requirements)');
 perform pg_temp.check_that((select status='documents_pending' from public.proposals_v2 where id=prop),'proposal moves to documents_pending');
 t2:=pg_temp.ins_template(uMg,o1,rt,2,'draft')::uuid;
 perform pg_temp.u(uMg,format($q$with x as (insert into public.document_checklist_items(organization_id,template_id,document_type_id,label,is_required,sort_order) values(%L,%L,%L,'Novo item',true,0) returning 1) select count(*)::text from x$q$,o1,t2,dt));
 perform pg_temp.u(uMg,format($q$select public.publish_document_checklist_template(%L)$q$,t2));
 perform pg_temp.check_that((select status='superseded' from public.document_checklist_templates where id=t1) and (select count(*) from public.document_checklist_templates where route_id=rt and status='published')=1,'a newer checklist supersedes the previous: one published per route');
 perform pg_temp.check_that((select count(*) from public.proposal_document_requirements where proposal_id=prop)=2,'the proposal keeps its own snapshot of requirements after the checklist changed');

 -- reads
 perform pg_temp.check_that(pg_temp.u(uB,'select count(*)::text from public.product_table_versions where organization_id<>(select organization_id from public.organization_memberships where user_id=auth.uid() limit 1)')='0','tenant B reads no tenant A versions');
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe,'no financial truth created by any of this');

 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED: '||r end;
end $test$;
