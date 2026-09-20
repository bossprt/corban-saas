-- Rollback-only adversarial harness for 20261004_commercial_bulk_import_v1 (needs the LIVE Commercial Model V3 tables). Run the function text first, then this block.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid(); uMg uuid:=gen_random_uuid(); uSv uuid:=gen_random_uuid(); uAg uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid(); uR uuid:=gen_random_uuid();
 bk uuid; ag uuid; rt uuid; tb uuid; v1 uuid; vPub uuid; gC uuid; gP uuid; gB uuid; ctN uuid; ctP uuid; ctR uuid; pol uuid; res text; r text; k int; det text; n0 int; j jsonb;
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
 -- returns 'ok:<json>' or 'err:<message>|<detail>'
 create function pg_temp.imp(p_uid uuid,p_ver uuid,p_rows text,p_pol text default 'null') returns text language plpgsql as $f$
 declare r text; m text; d text;
 begin
  begin r:=pg_temp.u(p_uid,format('select public.import_commercial_conditions(%L,%L::jsonb,%s)::text',p_ver,p_rows,p_pol)); return 'ok:'||r;
  exception when others then get stacked diagnostics m=message_text,d=pg_exception_detail; return 'err:'||m||'|'||coalesce(d,''); end;
 end $f$;
 create function pg_temp.check_that(cond boolean,label text) returns void language plpgsql as $f$
 begin insert into t_res values(label,coalesce(cond,false)); end $f$;
 insert into auth.users(id) values(uMg),(uSv),(uAg),(uB),(uR);
 insert into public.organizations(id,name,document) values(o1,'BULK-A','doc-'||o1),(o2,'BULK-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role,status) values(o1,uMg,'manager','active'),(o1,uSv,'supervisor','active'),(o1,uAg,'agent','active'),(o1,uR,'manager','inactive'),(o2,uB,'admin','active');
 insert into public.organization_banks(organization_id,name) values(o1,'Banco Bulk') returning id into bk;
 insert into public.organization_agreements(organization_id,name) values(o1,'Convenio Bulk') returning id into ag;
 insert into public.organization_product_routes(organization_id,org_bank_id,org_agreement_id,production_origin,status) values(o1,bk,ag,'own','active') returning id into rt;
 insert into public.product_tables(organization_id,route_id,code,name,status) values(o1,rt,'t-bulk','Tabela Bulk','active') returning id into tb;
 insert into public.product_table_versions(organization_id,product_table_id,version,status) values(o1,tb,1,'draft') returning id into v1;
 insert into public.product_table_versions(organization_id,product_table_id,version,status,published_at,effective_from) values(o1,tb,2,'published',now(),now()) returning id into vPub;
 insert into public.commission_groups(organization_id,name,kind,calculation_basis) values(o1,'Corretor','broker','percent_of_production') returning id into gC;
 insert into public.commission_groups(organization_id,name,kind,calculation_basis) values(o1,'Parceiro','partner','percent_of_received_commission') returning id into gP;
 insert into public.commission_groups(organization_id,name,kind,calculation_basis) values(o2,'Corretor','broker','percent_of_production') returning id into gB;
 select id into ctN from public.contract_types where tech_key='novo'; select id into ctP from public.contract_types where tech_key='portabilidade'; select id into ctR from public.contract_types where tech_key='refinanciamento';
 select count(*) into n0 from public.commercial_conditions;

 -- happy path: one transaction, three lines, groups included
 res:=pg_temp.imp(uMg,v1,format('[{"line":2,"contract_type_id":"%s","term":84,"coefficient":"0.01234567","rate":"1.85","received":"7","shares":[{"group_id":"%s","pct":"4"},{"group_id":"%s","pct":"45.5"}]},{"line":3,"contract_type_id":"%s","term":96,"coefficient":null,"rate":"1.5","received":"5","shares":[]},{"line":4,"contract_type_id":"%s","term":60,"coefficient":"0.02","rate":null,"received":"6","shares":[{"group_id":"%s","pct":"3"}]}]',ctN,gC,gP,ctP,ctR,gC));
 perform pg_temp.check_that(res like 'ok:%' and (res::text like '%"created": 3%') and (res like '%"updated": 0%'),'three lines are created in one call');
 perform pg_temp.check_that((select count(*) from public.commercial_conditions where product_table_version_id=v1)=3 and (select count(*) from public.commercial_condition_shares s join public.commercial_conditions c on c.id=s.condition_id where c.product_table_version_id=v1)=3,'three conditions and their three shares exist');
 perform pg_temp.check_that((select coefficient=0.01234567 and rate=1.85 from public.commercial_conditions where product_table_version_id=v1 and term=84) and (select effective_pct=3.185 from public.commercial_condition_shares s join public.commercial_conditions c on c.id=s.condition_id where c.product_table_version_id=v1 and c.term=84 and s.group_id=gP),'exact NUMERIC through the bulk path (0.01234567; 7% x 45.5% = 3.185)');
 -- idempotent reprocessing
 res:=pg_temp.imp(uMg,v1,format('[{"line":2,"contract_type_id":"%s","term":84,"coefficient":"0.03","rate":"1.85","received":"7","shares":[{"group_id":"%s","pct":"4"}]},{"line":3,"contract_type_id":"%s","term":96,"coefficient":null,"rate":"1.5","received":"5","shares":[]}]',ctN,gC,ctP));
 perform pg_temp.check_that(res like 'ok:%' and res like '%"created": 0%' and res like '%"updated": 2%','sending the same keys again updates, never duplicates');
 perform pg_temp.check_that((select count(*) from public.commercial_conditions where product_table_version_id=v1)=3 and (select coefficient=0.03 from public.commercial_conditions where product_table_version_id=v1 and term=84) and (select count(*) from public.commercial_condition_shares s join public.commercial_conditions c on c.id=s.condition_id where c.product_table_version_id=v1 and c.term=84)=1,'still 3 conditions; value updated; the removed group share is gone');
 -- all-or-nothing: valid + invalid lines in one payload
 res:=pg_temp.imp(uMg,v1,format('[{"line":10,"contract_type_id":"%s","term":12,"coefficient":"0.5","rate":null,"received":"5","shares":[]},{"line":11,"contract_type_id":"%s","term":24,"coefficient":"0.5","rate":null,"received":"5","shares":[{"group_id":"%s","pct":"9"}]},{"line":12,"contract_type_id":"%s","term":36,"coefficient":"0.5","rate":null,"received":"5","shares":[{"group_id":"%s","pct":"1"}]},{"line":13,"contract_type_id":"%s","term":48,"coefficient":"abc","rate":null,"received":"5","shares":[]}]',ctN,ctN,gC,ctN,gB,ctN));
 perform pg_temp.check_that(res like 'err:bulk_import_rejected|%',' a batch with refused lines fails as a whole');
 det:=split_part(res,'|',2);
 perform pg_temp.check_that(det::jsonb @> '[{"line":11,"code":"production_shares_exceed_received_commission"},{"line":12,"code":"commission_group_not_found"},{"line":13,"code":"invalid_number"}]'::jsonb and not (det::jsonb @> '[{"line":10}]'::jsonb),'the detail lists EVERY refused line with its code and not the valid one');
 perform pg_temp.check_that((select count(*) from public.commercial_conditions where product_table_version_id=v1)=3 and not exists(select 1 from public.commercial_conditions where product_table_version_id=v1 and term in (12,24,36,48)),'NOTHING of the failed batch was saved (the valid line 10 was rolled back)');
 -- structure
 perform pg_temp.check_that(pg_temp.imp(uMg,v1,format('[{"line":2,"contract_type_id":"%s","term":5,"coefficient":"1","received":"1"},{"line":3,"contract_type_id":"%s","term":5,"coefficient":"1","received":"1"}]',ctN,ctN)) like 'err:bulk_import_rejected|%duplicate_row%','the same Tipo de Contrato + prazo twice in one batch is refused');
 perform pg_temp.check_that(pg_temp.imp(uMg,v1,'[]') like 'err:invalid_rows%' and pg_temp.imp(uMg,v1,'{"a":1}') like 'err:invalid_rows%' and pg_temp.imp(uMg,v1,'null') like 'err:invalid_rows%','empty, non array and null payloads refused');
 perform pg_temp.check_that(pg_temp.imp(uMg,v1,(select jsonb_agg(jsonb_build_object('contract_type_id',ctN,'term',(g%600)+1,'coefficient','0.1','received','1'))::text from generate_series(1,501) g)) like 'err:too_many_rows%','more than 500 rows refused before any work');
 perform pg_temp.check_that(pg_temp.imp(uMg,v1,'[1,"x",null]') like 'err:bulk_import_rejected|%invalid_row%','non object elements are refused per line');
 perform pg_temp.check_that(pg_temp.imp(uMg,v1,format('[{"contract_type_id":"%s","term":"x","coefficient":"1","received":"1"}]',ctN)) like 'err:bulk_import_rejected|%invalid_row%','a malformed term is refused');
 perform pg_temp.check_that(pg_temp.imp(uMg,v1,format('[{"contract_type_id":"%s","term":5,"coefficient":"1","received":"1","organization_id":"%s"}]',ctN,o2)) like 'ok:%' and (select organization_id=o1 from public.commercial_conditions where product_table_version_id=v1 and term=5),'a forged organization_id in the payload is ignored: the tenant comes from the version');
 -- authorization
 perform pg_temp.check_that(pg_temp.imp(uAg,v1,'[]') like 'err:not_authorized%' and pg_temp.imp(uSv,v1,'[]') like 'err:not_authorized%' and pg_temp.imp(uR,v1,'[]') similar to 'err:(not_authorized|version_not_found)%','agent, supervisor and inactive manager cannot import (an inactive member no longer even sees the version)');
 perform pg_temp.check_that(pg_temp.imp(uB,v1,'[]') like 'err:version_not_found%','tenant B cannot even see the version');
 perform pg_temp.check_that(pg_temp.imp(uMg,vPub,format('[{"contract_type_id":"%s","term":5,"coefficient":"1","received":"1"}]',ctN)) like 'err:version_not_draft%','a published version cannot be imported into');
 perform pg_temp.check_that(pg_temp.imp(uMg,gen_random_uuid(),'[]') like 'err:version_not_found%','unknown version');
 -- policy through the bulk path
 perform pg_temp.check_that(pg_temp.imp(uMg,v1,format('[{"contract_type_id":"%s","term":7,"coefficient":"1","received":"1"}]',ctN),format('%L',gen_random_uuid())) like 'err:bulk_import_rejected|%policy_not_found%','an unknown policy version is refused per line');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and p.proname not in ('attach_import_batch_adapter','caller_role_in','commercial_route','import_row_evidence','lead_write','list_import_rows','bootstrap_organization_admin','get_user_organization_id')),'DEFINER inventory unchanged');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p,lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a where p.pronamespace='public'::regnamespace and p.proname='import_commercial_conditions' and (a.grantee=0 or a.grantee=(select oid from pg_roles where rolname='anon'))),'RPC not executable by PUBLIC/anon');
 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED: '||left(r,1200) end;
end $test$;
