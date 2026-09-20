-- Rollback-only adversarial harness for 20261002_commercial_model_v3_foundation_v1. Run the migration text first in the same transaction (until LIVE), then this DO block.
-- Ends with RAISE EXCEPTION; pass = 'RESULTS: ALL PASS'. Every row is synthetic.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid();
 uAd uuid:=gen_random_uuid(); uMg uuid:=gen_random_uuid(); uSv uuid:=gen_random_uuid(); uAg uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid(); uR uuid:=gen_random_uuid();
 gBal uuid; gInd uuid; gBr uuid; pol1 uuid; pol1b uuid; pol2 uuid; pol3 uuid; polB uuid; polId uuid; cP uuid; cN uuid; cO uuid;
 bk uuid; bkB uuid; pv uuid; ag uuid; agT uuid; agB uuid; rt uuid; tb uuid; v1 uuid; v2 uuid; gC uuid; gP uuid; gM uuid; gB uuid; gOff uuid; ct uuid; ctNovo uuid; cond uuid; cond2 uuid; cu uuid:=gen_random_uuid(); sim uuid; tpl uuid; fe int; r text; k int; n int;
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
 -- INSERT ... RETURNING id as a user
 create function pg_temp.ins(p_uid uuid,q text) returns text language sql as $f$
  select pg_temp.u(p_uid,'with x as ('||q||' returning id) select id::text from x') $f$;
 create function pg_temp.save(p_uid uuid,p_ver uuid,p_ct uuid,p_term int,p_coef text,p_rate text,p_rec text,p_shares text,p_cond text default 'null',p_pol text default 'null') returns text language sql as $f$
  select pg_temp.u(p_uid,format('select public.save_commercial_condition(%L,%L,%s,%L,%L,%L,%L::jsonb,%s,%s)::text',p_ver,p_ct,p_term,p_coef,p_rate,p_rec,p_shares,p_cond,p_pol)) $f$;
 create function pg_temp.save_err(p_uid uuid,p_ver uuid,p_ct uuid,p_term int,p_coef text,p_rate text,p_rec text,p_shares text,pat text,label text,p_cond text default 'null',p_pol text default 'null') returns void language sql as $f$
  select pg_temp.expect_err(p_uid,format('select public.save_commercial_condition(%L,%L,%s,%L,%L,%L,%L::jsonb,%s,%s)',p_ver,p_ct,p_term,p_coef,p_rate,p_rec,p_shares,p_cond,p_pol),pat,label) $f$;

 insert into auth.users(id) values(uAd),(uMg),(uSv),(uAg),(uB),(uR);
 insert into public.organizations(id,name,document) values(o1,'V3-A','doc-'||o1),(o2,'V3-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role,status) values(o1,uAd,'admin','active'),(o1,uMg,'manager','active'),(o1,uSv,'supervisor','active'),(o1,uAg,'agent','active'),(o1,uR,'manager','inactive'),(o2,uB,'admin','active');
 insert into public.clients(id,organization_id,full_name,cpf) values(cu,o1,'Cliente Sintetico','00000000001');
 select count(*) into fe from public.financial_events;
 select id into ctNovo from public.contract_types where tech_key='novo';

 -- ---- platform structure
 perform pg_temp.check_that((select count(*) from public.contract_types)=4 and exists(select 1 from public.contract_types where name='Compra de Dívida') and exists(select 1 from public.contract_types where name='Portabilidade'),'four standard contract types exist');
 perform pg_temp.check_that(not exists(select 1 from information_schema.columns where table_name='contract_types' and column_name in ('product_id','bank_id','organization_id')),'contract types depend on NOTHING (no product, bank or tenant column)');
 perform pg_temp.check_that((select count(*) from public.national_agreement_templates where kind='state_government')=27 and (select count(*) from public.national_agreement_templates where kind='capital_city_hall')=26,'27 governments (26 states + DF) and 26 capital city halls');
 perform pg_temp.check_that(not exists(select 1 from public.national_agreement_templates where name ilike '%Brasília%' and kind='capital_city_hall') and exists(select 1 from public.national_agreement_templates where name='Governo do Distrito Federal'),'no Prefeitura de Brasília; DF is a Governo');
 perform pg_temp.check_that((select count(distinct uf) from public.national_agreement_templates where kind='capital_city_hall')=26 and (select count(distinct uf) from public.national_agreement_templates where kind='state_government')=27,'every UF covered exactly once per kind');
 perform pg_temp.check_that(not exists(select 1 from information_schema.columns where table_name='national_agreement_templates' and column_name in ('bank_id','organization_id')),'templates are not tied to a bank or a tenant');
 perform pg_temp.check_that((select count(*) from public.organization_agreements)=0,'nothing is enabled for anyone by default');
 perform pg_temp.expect_err(uAd,'insert into public.contract_types(tech_key,name) values(''x'',''Hack'')','permission denied','a tenant admin cannot write contract types');
 perform pg_temp.expect_err(uAd,'update public.national_agreement_templates set is_active=false','permission denied','a tenant admin cannot edit the national templates');
 perform pg_temp.check_that(pg_temp.u(uAg,'select count(*)::text from public.contract_types')='4' and pg_temp.u(uAg,'select count(*)::text from public.national_agreement_templates')='53','every member reads the platform structure');

 -- ---- surface / definer
 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and p.proname not in ('attach_import_batch_adapter','caller_role_in','commercial_route','import_row_evidence','lead_write','list_import_rows','bootstrap_organization_admin','get_user_organization_id')),'DEFINER inventory equals the 8 reviewed functions');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p,lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a where p.pronamespace='public'::regnamespace and p.proname in ('save_commercial_condition','create_simulation_for_condition','save_payout_policy') and (a.grantee=0 or a.grantee=(select oid from pg_roles where rolname='anon'))),'V3 RPCs not executable by PUBLIC/anon');

 -- ---- tenant-owned catalog
 bk:=pg_temp.ins(uMg,format($q$insert into public.organization_banks(organization_id,name) values(%L,'Banco Sintetico')$q$,o1))::uuid;
 perform pg_temp.check_that((select tech_key ~ '^[0-9a-f]{32}$' and created_by=uMg and official_code is null from public.organization_banks where id=bk),'manager creates a bank by NAME; tech key generated by the database; no official code required');
 perform pg_temp.expect_err(uAg,format($q$insert into public.organization_banks(organization_id,name) values(%L,'Banco do Agente')$q$,o1),'row-level security|permission denied','an agent cannot create banks');
 perform pg_temp.expect_err(uSv,format($q$insert into public.organization_banks(organization_id,name) values(%L,'Banco do Supervisor')$q$,o1),'row-level security|permission denied','a supervisor cannot create banks');
 perform pg_temp.expect_err(uR,format($q$insert into public.organization_banks(organization_id,name) values(%L,'Banco Inativo')$q$,o1),'row-level security|permission denied','an inactive manager cannot create banks');
 perform pg_temp.expect_err(uMg,format($q$insert into public.organization_banks(organization_id,name) values(%L,'  BANCO sintetico ')$q$,o1),'duplicate key|unique','a bank with the same name (case-insensitive) is refused');
 perform pg_temp.expect_err(uMg,format($q$insert into public.organization_banks(organization_id,name) values(%L,'Banco Cruzado')$q$,o2),'row-level security','a tenant A manager cannot create a bank inside tenant B');
 bkB:=pg_temp.ins(uB,format($q$insert into public.organization_banks(organization_id,name) values(%L,'Banco Sintetico')$q$,o2))::uuid;
 perform pg_temp.check_that(bkB is not null,'the same bank NAME in another tenant is fine (tenant-owned)');
 perform pg_temp.check_that(pg_temp.u(uB,'select count(*)::text from public.organization_banks')='1' and pg_temp.u(uAg,'select count(*)::text from public.organization_banks')='1','each tenant reads only its own banks (agents read them too)');
 perform pg_temp.expect_err(uMg,format($q$update public.organization_banks set tech_key='forged' where id=%L$q$,bk),'catalog_identity_is_immutable','tech key is immutable');
 perform pg_temp.expect_err(uMg,format($q$update public.organization_banks set organization_id=%L where id=%L$q$,o2,bk),'catalog_identity_is_immutable|row-level security','organization_id is immutable');
 perform pg_temp.check_that(pg_temp.u(uMg,format($q$select count(*)::text from (select 1 from public.organization_banks where id=%L) z$q$,bk))='1' and pg_temp.u(uMg,format($q$with x as (update public.organization_banks set name='Banco Sintetico Renomeado',official_code='001' where id=%L returning 1) select count(*)::text from x$q$,bk))='1','manager renames a bank and may add a real official code');
 pv:=pg_temp.ins(uMg,format($q$insert into public.organization_providers(organization_id,name,provider_type) values(%L,'Master Sintetico','master')$q$,o1))::uuid;
 perform pg_temp.check_that(pv is not null,'manager creates a provider / master');
 perform pg_temp.expect_err(uAg,format($q$insert into public.organization_providers(organization_id,name) values(%L,'X')$q$,o1),'row-level security|permission denied','an agent cannot create providers');
 -- agreements: enable from a national template, custom, duplicates
 select id into tpl from public.national_agreement_templates where tech_key='gov-ac';
 agT:=pg_temp.ins(uMg,format($q$insert into public.organization_agreements(organization_id,template_id,name) values(%L,%L,'nome que o usuario tentou trocar')$q$,o1,tpl))::uuid;
 perform pg_temp.check_that((select name='Governo do Acre' and template_id=tpl from public.organization_agreements where id=agT),'enabling a national template gives the OFFICIAL name (the tenant cannot relabel it)');
 perform pg_temp.expect_err(uMg,format($q$insert into public.organization_agreements(organization_id,template_id,name) values(%L,%L,'x')$q$,o1,tpl),'duplicate key|unique','the same template cannot be enabled twice');
 perform pg_temp.expect_err(uMg,format($q$update public.organization_agreements set template_id=null where id=%L$q$,agT),'catalog_identity_is_immutable','an enabled template cannot be detached');
 perform pg_temp.expect_err(uMg,format($q$insert into public.organization_agreements(organization_id,template_id,name) values(%L,gen_random_uuid(),'x')$q$,o1),'foreign key|violates|national_template_not_available','unknown template refused');
 ag:=pg_temp.ins(uMg,format($q$insert into public.organization_agreements(organization_id,name) values(%L,'Convenio Proprio Sintetico')$q$,o1))::uuid;
 perform pg_temp.check_that(ag is not null and (select template_id is null from public.organization_agreements where id=ag),'tenant registers its own additional agreement (not bound to any bank)');
 perform pg_temp.check_that(pg_temp.u(uAg,'select count(*)::text from public.organization_agreements')='2','agents read enabled agreements');
 agB:=pg_temp.ins(uB,format($q$insert into public.organization_agreements(organization_id,template_id,name) values(%L,%L,'x')$q$,o2,tpl))::uuid;
 perform pg_temp.check_that(agB is not null and (select count(*) from public.organization_agreements where template_id=tpl)=2,'two tenants enable the same national agreement independently (no duplication of the government per bank)');
 -- commission groups
 gC:=pg_temp.ins(uMg,format($q$insert into public.commission_groups(organization_id,name,kind,calculation_basis) values(%L,'Corretor','broker','percent_of_production')$q$,o1))::uuid;
 gP:=pg_temp.ins(uMg,format($q$insert into public.commission_groups(organization_id,name,kind,calculation_basis) values(%L,'Parceiro','partner','percent_of_received_commission')$q$,o1))::uuid;
 gM:=pg_temp.ins(uMg,format($q$insert into public.commission_groups(organization_id,name,kind,calculation_basis) values(%L,'Gerente','manager','percent_of_production')$q$,o1))::uuid;
 gOff:=pg_temp.ins(uMg,format($q$insert into public.commission_groups(organization_id,name,kind,calculation_basis,is_active) values(%L,'Grupo Inativo','other','percent_of_production',false)$q$,o1))::uuid;
 gB:=pg_temp.ins(uB,format($q$insert into public.commission_groups(organization_id,name,kind,calculation_basis) values(%L,'Corretor','broker','percent_of_production')$q$,o2))::uuid;
 perform pg_temp.check_that(gC is not null and gP is not null and gM is not null,'tenant creates dynamic groups; manager/supervisor groups are optional ordinary groups');
 perform pg_temp.expect_err(uAg,format($q$insert into public.commission_groups(organization_id,name,kind,calculation_basis) values(%L,'X','other','percent_of_production')$q$,o1),'row-level security|permission denied','an agent cannot create groups');
 perform pg_temp.expect_err(uMg,format($q$insert into public.commission_groups(organization_id,name,kind,calculation_basis) values(%L,'corretor','broker','percent_of_production')$q$,o1),'duplicate key|unique','duplicate group name refused');
 perform pg_temp.expect_err(uMg,format($q$insert into public.commission_groups(organization_id,name,kind,calculation_basis) values(%L,'Y','other','percent_of_something_else')$q$,o1),'check constraint|violates','calculation basis is an explicit enum (no silent mixing)');
 perform pg_temp.check_that(pg_temp.u(uAg,'select count(*)::text from public.commission_groups')='0' and pg_temp.u(uSv,'select count(*)::text from public.commission_groups')='4' and pg_temp.u(uB,'select count(*)::text from public.commission_groups')='1','FAIL CLOSED: agents read no groups; supervisor reads own tenant; tenant B reads only its own');

 -- ---- routes: V3 shape next to legacy
 rt:=pg_temp.ins(uMg,format($q$insert into public.organization_product_routes(organization_id,org_bank_id,org_agreement_id,production_origin,status) values(%L,%L,%L,'own','active')$q$,o1,bk,agT))::uuid;
 perform pg_temp.check_that(rt is not null,'route = bank + agreement (provider optional); NO contract type, NO product');
 perform pg_temp.expect_err(uMg,format($q$insert into public.organization_product_routes(organization_id,org_bank_id,org_agreement_id,production_origin,status) values(%L,%L,%L,'own','active')$q$,o1,bk,agT),'duplicate key|unique','duplicate V3 route refused');
 perform pg_temp.check_that(pg_temp.ins(uMg,format($q$insert into public.organization_product_routes(organization_id,org_bank_id,org_provider_id,org_agreement_id,production_origin,status) values(%L,%L,%L,%L,'third_party','active')$q$,o1,bk,pv,agT))::uuid is not null,'the same bank+agreement through an external origin company is a different route');
 perform pg_temp.expect_err(uMg,format($q$insert into public.organization_product_routes(organization_id,org_bank_id,org_agreement_id,production_origin,status) values(%L,%L,%L,'own','active')$q$,o1,bkB,agT),'foreign key|violates','a tenant A route cannot reference a tenant B bank');
 perform pg_temp.expect_err(uMg,format($q$insert into public.organization_product_routes(organization_id,org_bank_id,org_agreement_id,production_origin,status) values(%L,%L,%L,'own','active')$q$,o1,bk,agB),'foreign key|violates','a tenant A route cannot reference a tenant B agreement');
 perform pg_temp.expect_err(uMg,format($q$insert into public.organization_product_routes(organization_id,org_bank_id,org_agreement_id,bank_id,production_origin,status) values(%L,%L,%L,gen_random_uuid(),'own','active')$q$,o1,bk,ag),'organization_product_routes_shape|check','a route cannot mix the legacy and V3 shapes');
 perform pg_temp.expect_err(uMg,format($q$insert into public.organization_product_routes(organization_id,status) values(%L,'active')$q$,o1),'organization_product_routes_shape|check','a route with neither shape is refused');
 perform pg_temp.expect_err(uAg,format($q$insert into public.organization_product_routes(organization_id,org_bank_id,org_agreement_id,production_origin,status) values(%L,%L,%L,'own','active')$q$,o1,bk,ag),'row-level security|permission denied','an agent cannot create routes');
 -- Origem da Produção: Própria (no external company) or Terceiro (an external origin company is required)
 perform pg_temp.expect_err(uMg,format($q$insert into public.organization_product_routes(organization_id,org_bank_id,org_agreement_id,production_origin,status) values(%L,%L,%L,'third_party','active')$q$,o1,bk,ag),'organization_product_routes_shape|check','third-party production without an origin company is refused');
 perform pg_temp.expect_err(uMg,format($q$insert into public.organization_product_routes(organization_id,org_bank_id,org_provider_id,org_agreement_id,production_origin,status) values(%L,%L,%L,%L,'own','active')$q$,o1,bk,pv,ag),'organization_product_routes_shape|check','own production with an external company is refused (Própria has no supplier)');
 perform pg_temp.expect_err(uMg,format($q$insert into public.organization_product_routes(organization_id,org_bank_id,org_agreement_id,production_origin,status) values(%L,%L,%L,'whatever','active')$q$,o1,bk,ag),'check','an unknown production origin is refused');
 perform pg_temp.expect_err(uMg,format($q$insert into public.organization_product_routes(organization_id,org_bank_id,org_agreement_id,status) values(%L,%L,%L,'active')$q$,o1,bk,ag),'organization_product_routes_shape|check','a V3 route must declare its production origin');
 perform pg_temp.check_that((select production_origin='own' and org_provider_id is null from public.organization_product_routes where id=rt),'the route is Própria: no external company');
 perform pg_temp.check_that((select count(*) from public.organization_product_routes where production_origin='third_party')=1,'a Terceiro route carries its origin company');


 -- ---- table (= product) and draft version
 tb:=pg_temp.ins(uMg,format($q$insert into public.product_tables(organization_id,route_id,code,name,status) values(%L,%L,'t-'||substr(md5(random()::text),1,8),'Tabela Servidor 001','active')$q$,o1,rt))::uuid;
 v1:=pg_temp.ins(uMg,format($q$insert into public.product_table_versions(organization_id,product_table_id,version,status) values(%L,%L,1,'draft')$q$,o1,tb))::uuid;
 perform pg_temp.check_that(tb is not null and v1 is not null,'table (Produto) and a draft version created by the tenant on a V3 route (no global reference needed)');

 -- ---- commercial condition: ONE call, every group
 cond:=pg_temp.save(uMg,v1,ctNovo,84,'0.01234567','1.85','7.0',format('[{"group_id":"%s","pct":4.0},{"group_id":"%s","pct":45.5},{"group_id":"%s","pct":0.2}]',gC,gP,gM))::uuid;
 perform pg_temp.check_that(cond is not null and (select count(*) from public.commercial_condition_shares where condition_id=cond)=3,'ONE call registered the condition and the share of EVERY group');
 perform pg_temp.check_that((select coefficient=0.01234567 and rate=1.85 and term=84 from public.commercial_conditions where id=cond) and (select received_commission_pct=7.000000 from public.commercial_condition_commissions where condition_id=cond),'exact NUMERIC storage (coefficient 0.01234567, rate 1.85, received 7.00)');
 perform pg_temp.check_that((select share_pct=45.500000 and effective_pct=3.185000 and source='manual' from public.commercial_condition_shares where condition_id=cond and group_id=gP),'a percent_of_received_commission share is stored exactly (45.5) with its derived effective value (7 x 45.5% = 3.185)');
 perform pg_temp.check_that(not exists(select 1 from information_schema.columns where table_name in ('commercial_conditions','commercial_condition_commissions','commercial_condition_shares') and data_type in ('real','double precision')),'no floating point column in the commercial model');
 perform pg_temp.save_err(uMg,v1,ctNovo,84,'0.02','1',   '7.0','[]','condition_already_exists','the same version + contract type + term is refused (no duplicate table rows)');
 perform pg_temp.check_that(pg_temp.save(uMg,v1,ctNovo,60,'0.02',null,'6.0',format('[{"group_id":"%s","pct":3}]',gC))::uuid is not null,'another term of the same contract type is a separate condition');
 perform pg_temp.check_that(pg_temp.save(uMg,v1,(select id from public.contract_types where tech_key='portabilidade'),84,null,'1.5','5.0','[]')::uuid is not null,'a condition with rate only and no shares is valid');
 perform pg_temp.save_err(uMg,v1,ctNovo,36,'0.02',null,'5.0',format('[{"group_id":"%s","pct":5.5}]',gC),'production_shares_exceed_received_commission','production-based shares cannot exceed the commission received');
 perform pg_temp.save_err(uMg,v1,ctNovo,36,'0.02',null,'5.0',format('[{"group_id":"%s","pct":60},{"group_id":"%s","pct":60}]',gP,gP),'duplicate_group_share','the same group twice is refused');
 perform pg_temp.save_err(uMg,v1,ctNovo,36,'0.02',null,'5.0',format('[{"group_id":"%s","pct":101}]',gP),'invalid_shares','a share above 100 is refused');
 perform pg_temp.save_err(uMg,v1,ctNovo,36,'0.02',null,'5.0',format('[{"group_id":"%s","pct":-1}]',gP),'invalid_shares','a negative share is refused');
 perform pg_temp.save_err(uMg,v1,ctNovo,36,'0.02',null,'5.0','[{"group_id":"not-a-uuid","pct":1}]','invalid_shares','a malformed group id is refused');
 perform pg_temp.save_err(uMg,v1,ctNovo,36,'0.02',null,'5.0','{"a":1}','invalid_shares','shares must be an array');
 perform pg_temp.save_err(uMg,v1,ctNovo,36,'0.02',null,'5.0',format('[{"group_id":"%s","pct":1}]',gB),'commission_group_not_found','a tenant B group cannot be used by tenant A');
 perform pg_temp.save_err(uMg,v1,ctNovo,36,'0.02',null,'5.0',format('[{"group_id":"%s","pct":1}]',gOff),'commission_group_not_found','an inactive group cannot be used');
 perform pg_temp.save_err(uMg,v1,gen_random_uuid(),36,'0.02',null,'5.0','[]','contract_type_not_found','unknown contract type');
 perform pg_temp.save_err(uMg,v1,ctNovo,0,'0.02',null,'5.0','[]','invalid_term','term 0 refused');
 perform pg_temp.save_err(uMg,v1,ctNovo,601,'0.02',null,'5.0','[]','invalid_term','term above 600 refused');
 perform pg_temp.save_err(uMg,v1,ctNovo,36,null,null,'5.0','[]','coefficient_or_rate_required','neither coefficient nor rate refused');
 perform pg_temp.save_err(uMg,v1,ctNovo,36,'-1',null,'5.0','[]','coefficient_or_rate_required','negative coefficient refused');
 perform pg_temp.save_err(uMg,v1,ctNovo,36,'0.02',null,'100.5','[]','invalid_received_commission','received commission above 100 refused');
 perform pg_temp.save_err(uMg,v1,ctNovo,36,'0.02',null,null,'[]','invalid_received_commission','missing received commission refused (blank is not zero)');
 perform pg_temp.save_err(uAg,v1,ctNovo,36,'0.02',null,'5.0','[]','not_authorized|version_not_found','an agent cannot register conditions');
 perform pg_temp.save_err(uSv,v1,ctNovo,36,'0.02',null,'5.0','[]','not_authorized|version_not_found','a supervisor cannot register conditions');
 perform pg_temp.save_err(uR,v1,ctNovo,36,'0.02',null,'5.0','[]','not_authorized|version_not_found','an inactive manager cannot register conditions');
 perform pg_temp.save_err(uB,v1,ctNovo,36,'0.02',null,'5.0','[]','version_not_found','tenant B cannot register conditions on a tenant A version');
 -- editing a draft condition replaces its shares
 cond2:=pg_temp.save(uMg,v1,ctNovo,84,'0.02','1.85','8.0',format('[{"group_id":"%s","pct":4.5}]',gC),format('%L',cond))::uuid;
 perform pg_temp.check_that(cond2=cond and (select count(*) from public.commercial_condition_shares where condition_id=cond)=1 and (select received_commission_pct=8 from public.commercial_condition_commissions where condition_id=cond) and (select coefficient=0.02 from public.commercial_conditions where id=cond),'editing a draft condition replaces values and the full share set (removed groups are gone)');
 -- direct writes are closed
 perform pg_temp.expect_err(uMg,format($q$insert into public.commercial_conditions(organization_id,product_table_version_id,contract_type_id,term,coefficient) values(%L,%L,%L,12,0.1)$q$,o1,v1,ctNovo),'condition_write_requires_governed_rpc','direct INSERT of a condition is refused');
 perform pg_temp.expect_err(uMg,format($q$update public.commercial_conditions set coefficient=9 where id=%L$q$,cond),'condition_write_requires_governed_rpc','direct UPDATE of a condition is refused');
 perform pg_temp.expect_err(uMg,format($q$update public.commercial_condition_commissions set received_commission_pct=99 where condition_id=%L$q$,cond),'condition_write_requires_governed_rpc','direct UPDATE of the received commission is refused');
 perform pg_temp.expect_err(uMg,format($q$insert into public.commercial_condition_shares(organization_id,condition_id,group_id,share_pct,effective_pct) values(%L,%L,%L,90,90)$q$,o1,cond,gP),'condition_write_requires_governed_rpc','direct INSERT of a share is refused');
 perform pg_temp.expect_err(uMg,format($q$delete from public.commercial_condition_shares where condition_id=%L$q$,cond),'condition_write_requires_governed_rpc','direct DELETE of shares is refused');
 perform pg_temp.expect_err(uMg,format($q$delete from public.commercial_conditions where id=%L$q$,cond),'permission denied','conditions can never be deleted');
 -- visibility: pricing for every member, commission only supervisor+
 perform pg_temp.check_that(pg_temp.u(uAg,'select count(*)::text from public.commercial_conditions')='3' and pg_temp.u(uAg,'select count(*)::text from public.commercial_condition_commissions')='0' and pg_temp.u(uAg,'select count(*)::text from public.commercial_condition_shares')='0','FAIL CLOSED: an agent reads pricing but NO commission and NO shares');
 perform pg_temp.check_that(pg_temp.u(uSv,'select count(*)::text from public.commercial_condition_commissions')='3' and pg_temp.u(uSv,'select count(*)::text from public.commercial_condition_shares')::int>=2,'a supervisor reads commission and shares');
 perform pg_temp.check_that(pg_temp.u(uB,'select (select count(*) from public.commercial_conditions)+(select count(*) from public.commercial_condition_commissions)+(select count(*) from public.commercial_condition_shares)')::int=0,'tenant B reads none of tenant A conditions, commissions or shares');

 -- ---- publish a version whose pricing lives only in conditions, then it is frozen
 perform pg_temp.check_that(pg_temp.u(uMg,format($q$select public.publish_product_table_version(%L)::text$q$,v1))=v1::text,'v1 (priced by conditions) publishes and freezes its conditions');
 v2:=pg_temp.ins(uMg,format($q$insert into public.product_table_versions(organization_id,product_table_id,version,status) values(%L,%L,2,'draft')$q$,o1,tb))::uuid;
 perform pg_temp.expect_err(uMg,format($q$select public.publish_product_table_version(%L)$q$,v2),'rate_or_coefficient_required','a version with no pricing at all cannot be published');
 perform pg_temp.check_that(pg_temp.save(uMg,v2,ctNovo,84,'0.019',null,'7.0',format('[{"group_id":"%s","pct":4}]',gC))::uuid is not null,'conditions registered on the draft v2');
 -- ---- payout policies (repasse por grupo): a saved rate card of % of the RECEIVED commission, versioned and immutable
 gBal:=pg_temp.ins(uMg,format($q$insert into public.commission_groups(organization_id,name,kind,calculation_basis) values(%L,'Balcao','counter','percent_of_received_commission')$q$,o1))::uuid;
 gInd:=pg_temp.ins(uMg,format($q$insert into public.commission_groups(organization_id,name,kind,calculation_basis) values(%L,'Indicador','referrer','percent_of_received_commission')$q$,o1))::uuid;
 gBr:=pg_temp.ins(uB,format($q$insert into public.commission_groups(organization_id,name,kind,calculation_basis) values(%L,'Parceiro B','partner','percent_of_received_commission')$q$,o2))::uuid;
 pol1:=pg_temp.u(uMg,format($q$select public.save_payout_policy(%L,'Politica Smart','gross','0',%L::jsonb,null)::text$q$,o1,format('[{"group_id":"%s","pct":80},{"group_id":"%s","pct":50},{"group_id":"%s","pct":25}]',gP,gBal,gInd)))::uuid;
 perform pg_temp.check_that((select version=1 and base_kind='gross' and discount_pct=0 from public.payout_policy_versions where id=pol1) and (select count(*) from public.payout_policy_items where version_id=pol1)=3,'a payout policy is a rate card per group (80% + 50% + 25% = alternatives, NOT a sum) saved as version 1');
 perform pg_temp.check_that((select tech_key ~ '^[0-9a-f]{32}$' from public.payout_policies where id=(select policy_id from public.payout_policy_versions where id=pol1)),'policy technical key generated by the database');
 polId:=(select policy_id from public.payout_policy_versions where id=pol1);
 pol1b:=pg_temp.u(uMg,format($q$select public.save_payout_policy(%L,null,'gross','0',%L::jsonb,%L)::text$q$,o1,format('[{"group_id":"%s","pct":85},{"group_id":"%s","pct":50}]',gP,gBal),polId))::uuid;
 perform pg_temp.check_that((select version=2 from public.payout_policy_versions where id=pol1b) and (select count(*) from public.payout_policy_versions where policy_id=polId)=2 and (select count(*) from public.payout_policy_items where version_id=pol1)=3,'saving again creates version 2; version 1 and its items are untouched (history is not rewritten)');
 perform pg_temp.expect_err(uMg,format($q$update public.payout_policy_items set pct=1 where version_id=%L$q$,pol1),'permission denied|payout_policy_versions_are_immutable','policy items can never be edited');
 perform pg_temp.expect_err(uMg,format($q$update public.payout_policy_versions set base_kind='net' where id=%L$q$,pol1),'permission denied|payout_policy_versions_are_immutable','policy versions can never be edited');
 perform pg_temp.expect_err(uMg,format($q$delete from public.payout_policy_versions where id=%L$q$,pol1),'permission denied|payout_policy_versions_are_immutable','policy versions can never be deleted');
 perform pg_temp.expect_err(uMg,format($q$insert into public.payout_policy_versions(organization_id,policy_id,version,base_kind) values(%L,%L,9,'gross')$q$,o1,polId),'payout_write_requires_governed_rpc','a version cannot be written directly');
 perform pg_temp.expect_err(uMg,format($q$insert into public.payout_policies(organization_id,name) values(%L,'Direta')$q$,o1),'payout_write_requires_governed_rpc','a policy cannot be created directly');
 perform pg_temp.expect_err(uAg,format($q$select public.save_payout_policy(%L,'X','gross','0','[]'::jsonb,null)$q$,o1),'not_authorized','an agent cannot save a payout policy');
 perform pg_temp.expect_err(uSv,format($q$select public.save_payout_policy(%L,'X','gross','0','[]'::jsonb,null)$q$,o1),'not_authorized','a supervisor cannot save a payout policy');
 perform pg_temp.expect_err(uR,format($q$select public.save_payout_policy(%L,'X','gross','0','[]'::jsonb,null)$q$,o1),'not_authorized','an inactive manager cannot save a payout policy');
 perform pg_temp.expect_err(uB,format($q$select public.save_payout_policy(%L,'X','gross','0','[]'::jsonb,null)$q$,o1),'not_authorized','tenant B cannot create a policy inside tenant A');
 perform pg_temp.expect_err(uB,format($q$select public.save_payout_policy(%L,null,'gross','0','[]'::jsonb,%L)$q$,o2,polId),'policy_not_found','tenant B cannot add a version to a tenant A policy');
 perform pg_temp.expect_err(uMg,format($q$select public.save_payout_policy(%L,'Y','gross','0',%L::jsonb,null)$q$,o1,format('[{"group_id":"%s","pct":10}]',gC)),'policy_group_must_use_received_basis','a production-based group cannot be in a policy over the received commission (no silent mixing)');
 perform pg_temp.expect_err(uMg,format($q$select public.save_payout_policy(%L,'Y','gross','0',%L::jsonb,null)$q$,o1,format('[{"group_id":"%s","pct":10}]',gBr)),'commission_group_not_found','a tenant B group cannot be in a tenant A policy');
 perform pg_temp.expect_err(uMg,format($q$select public.save_payout_policy(%L,'Y','gross','0',%L::jsonb,null)$q$,o1,format('[{"group_id":"%s","pct":60},{"group_id":"%s","pct":10}]',gP,gP)),'duplicate_group_share','the same group twice in a policy is refused');
 perform pg_temp.expect_err(uMg,format($q$select public.save_payout_policy(%L,'Y','gross','0',%L::jsonb,null)$q$,o1,format('[{"group_id":"%s","pct":101}]',gP)),'invalid_policy','a policy percentage above 100 is refused');
 perform pg_temp.expect_err(uMg,format($q$select public.save_payout_policy(%L,'Y','gross','10','[]'::jsonb,null)$q$,o1),'invalid_policy','a gross policy cannot carry a discount');
 perform pg_temp.expect_err(uMg,format($q$select public.save_payout_policy(%L,'Y','weird','0','[]'::jsonb,null)$q$,o1),'invalid_policy','unknown base kind refused');
 perform pg_temp.expect_err(uMg,format($q$select public.save_payout_policy(%L,'Y','net','101','[]'::jsonb,null)$q$,o1),'invalid_policy','discount above 100 refused');
 perform pg_temp.expect_err(uMg,format($q$select public.save_payout_policy(%L,'  politica SMART ','gross','0','[]'::jsonb,null)$q$,o1),'policy_already_exists','duplicate policy name (case and spaces) refused');
 perform pg_temp.check_that(pg_temp.u(uAg,'select count(*)::text from public.payout_policies')='0' and pg_temp.u(uSv,'select count(*)::text from public.payout_policies')='1' and pg_temp.u(uB,'select count(*)::text from public.payout_policies')='0','FAIL CLOSED: agents read no policy; supervisor reads own tenant; tenant B reads none of tenant A');
 -- applying a policy to a condition
 cP:=pg_temp.save(uMg,v2,(select id from public.contract_types where tech_key='refinanciamento'),60,'0.02',null,'10.0','[]','null',format('%L',pol1))::uuid;
 perform pg_temp.check_that((select count(*)=3 and bool_and(source='policy') and bool_and(policy_version_id=pol1) from public.commercial_condition_shares where condition_id=cP) and (select effective_pct from public.commercial_condition_shares where condition_id=cP and group_id=gP)=8.000000 and (select effective_pct from public.commercial_condition_shares where condition_id=cP and group_id=gBal)=5.000000 and (select effective_pct from public.commercial_condition_shares where condition_id=cP and group_id=gInd)=2.500000,'received 10% x policy (Parceiro 80, Balcao 50, Indicador 25) = 8.00 / 5.00 / 2.50, derived by the database with NO percentage typed on the condition');
 perform pg_temp.check_that((select net_base_pct=10 and policy_version_id=pol1 and received_commission_pct=10 from public.commercial_condition_commissions where condition_id=cP),'the condition records gross received, the base used and the policy version (snapshot of the rule applied)');
 pol2:=pg_temp.u(uMg,format($q$select public.save_payout_policy(%L,'Politica Liquida','net','10',%L::jsonb,null)::text$q$,o1,format('[{"group_id":"%s","pct":80}]',gP)))::uuid;
 cN:=pg_temp.save(uMg,v2,(select id from public.contract_types where tech_key='portabilidade'),60,'0.02',null,'10.0','[]','null',format('%L',pol2))::uuid;
 perform pg_temp.check_that((select net_base_pct=9.000000 from public.commercial_condition_commissions where condition_id=cN) and (select effective_pct=7.200000 and share_pct=80 from public.commercial_condition_shares where condition_id=cN and group_id=gP),'net policy: 10% received less a 10% tax = 9.00% base; Parceiro 80% of that = 7.20% (gross and net are kept apart)');
 cO:=pg_temp.save(uMg,v2,(select id from public.contract_types where tech_key='compra_de_divida'),60,'0.02',null,'10.0',format('[{"group_id":"%s","pct":70},{"group_id":"%s","pct":4}]',gP,gC),'null',format('%L',pol1))::uuid;
 perform pg_temp.check_that((select source='override' and effective_pct=7.000000 from public.commercial_condition_shares where condition_id=cO and group_id=gP) and (select source='manual' and effective_pct=4.000000 and policy_version_id is null from public.commercial_condition_shares where condition_id=cO and group_id=gC) and (select count(*) from public.commercial_condition_shares where condition_id=cO and source='policy')=2,'an explicit percentage overrides the policy for that group (traceable as override); a production group stays manual; the rest come from the policy');
 perform pg_temp.check_that(pg_temp.save(uMg,v2,(select id from public.contract_types where tech_key='compra_de_divida'),36,'0.02',null,'5.0',format('[{"group_id":"%s","pct":4},{"group_id":"%s","pct":3}]',gC,gM))::uuid is not null,'groups are ALTERNATIVE sellers: 4% + 3% against 5% received is valid (each group is capped by the commission received, not their sum)');
 perform pg_temp.save_err(uMg,v2,ctNovo,12,'0.02',null,'5.0',format('[{"group_id":"%s","pct":5.5}]',gM),'production_shares_exceed_received_commission','one group cannot get more than the company received');
 perform pg_temp.save_err(uMg,v2,ctNovo,12,'0.02',null,'5.0','[]','policy_not_found','an unknown policy version is refused','null',format('%L',gen_random_uuid()));
 polB:=pg_temp.u(uB,format($q$select public.save_payout_policy(%L,'Politica B','gross','0',%L::jsonb,null)::text$q$,o2,format('[{"group_id":"%s","pct":50}]',gBr)))::uuid;
 perform pg_temp.save_err(uMg,v2,ctNovo,12,'0.02',null,'5.0','[]','policy_not_found','a tenant B policy cannot be applied by tenant A','null',format('%L',polB));
 update public.payout_policies set is_active=false where id=(select policy_id from public.payout_policy_versions where id=pol2);
 perform pg_temp.save_err(uMg,v2,ctNovo,12,'0.02',null,'5.0','[]','policy_not_found','an inactive policy cannot be applied','null',format('%L',pol2));
 pol3:=pg_temp.u(uMg,format($q$select public.save_payout_policy(%L,'Politica Tres','gross','0',%L::jsonb,null)::text$q$,o1,format('[{"group_id":"%s","pct":10}]',gInd)))::uuid;
 update public.commission_groups set is_active=false where id=gInd;
 perform pg_temp.save_err(uMg,v2,ctNovo,12,'0.02',null,'5.0','[]','policy_group_inactive','a policy whose group was deactivated is refused (never silently dropped)','null',format('%L',pol3));
 update public.commission_groups set is_active=true where id=gInd;
 perform pg_temp.check_that(pg_temp.u(uAg,'select (select count(*) from public.commercial_condition_shares)+(select count(*) from public.payout_policy_items)')::int=0,'FAIL CLOSED: an agent reads no share and no policy item');
 perform pg_temp.check_that(pg_temp.u(uMg,format($q$select public.publish_product_table_version(%L)::text$q$,v2))=v2::text,'a version priced only by conditions publishes');
 perform pg_temp.check_that((select status='published' from public.product_table_versions where id=v2) and (select status='superseded' from public.product_table_versions where id=v1),'publication supersedes the previous version');
 perform pg_temp.save_err(uMg,v2,ctNovo,60,'0.02',null,'5.0','[]','version_not_draft','a published version accepts no new condition');
 perform pg_temp.save_err(uMg,v1,ctNovo,12,'0.02',null,'5.0','[]','version_not_draft','a superseded version accepts no new condition');
 perform pg_temp.check_that((select count(*) from public.commercial_conditions where product_table_version_id=v1)=3,'the history of the superseded version is intact (3 conditions)');
 -- an even stronger freeze: the guard itself (no RPC token) also refuses on a published version
 perform set_config('corban.condition_rpc','on',true);
 perform pg_temp.check_that(coalesce(pg_temp.err_of(uMg,format($q$update public.commercial_conditions set coefficient=7 where product_table_version_id=%L$q$,v2)),'') ~ 'published_version_conditions_are_immutable|row-level|permission','even with a forged token a published version stays frozen (the guard checks the version status itself)');
 perform set_config('corban.condition_rpc','off',true);

 -- ---- governed simulation on a condition
 sim:=pg_temp.u(uAg,format($q$select public.create_simulation_for_condition(%L,%L,%L,10000,84)::text$q$,cu,v2,ctNovo))::uuid;
 perform pg_temp.check_that((select installment_amount=190.00 and coefficient=0.01900000 and organization_id=o1 and created_by=uAg and status='calculated' and expected_commission_amount is null and released_amount is null from public.simulations where id=sim),'agent simulates on a condition: installment from the condition coefficient, tenant derived, NO commission');
 perform pg_temp.check_that((select input_snapshot->>'contract_type_id'=ctNovo::text and (input_snapshot->>'condition_id') is not null and not (result_snapshot::text ilike '%commission%') from public.simulations where id=sim),'the snapshot records contract type and condition, never commission');
 perform pg_temp.expect_err(uAg,format($q$select public.create_simulation_for_condition(%L,%L,%L,10000,72)$q$,cu,v2,ctNovo),'condition_not_found','a term without a condition cannot be simulated');
 perform pg_temp.expect_err(uAg,format($q$select public.create_simulation_for_condition(%L,%L,%L,10000,84)$q$,cu,v2,(select id from public.contract_types where tech_key='refinanciamento')),'condition_not_found','a contract type without a condition cannot be simulated');
 perform pg_temp.expect_err(uAg,format($q$select public.create_simulation_for_condition(%L,%L,%L,10000,84)$q$,cu,v1,ctNovo),'published_table_version_not_available','a superseded version cannot be simulated');
 perform pg_temp.expect_err(uB,format($q$select public.create_simulation_for_condition(%L,%L,%L,10000,84)$q$,cu,v2,ctNovo),'customer_not_found_or_forbidden','tenant B cannot simulate on tenant A data');
 perform pg_temp.expect_err(uR,format($q$select public.create_simulation_for_condition(%L,%L,%L,10000,84)$q$,cu,v2,ctNovo),'customer_not_found_or_forbidden','an inactive member cannot simulate');
 perform pg_temp.expect_err(uAg,format($q$select public.create_simulation_for_condition(%L,%L,%L,0,84)$q$,cu,v2,ctNovo),'invalid_amount','invalid amount refused');
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe,'no financial truth created by any of this');
 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED: '||left(r,900) end;
end $test$;
