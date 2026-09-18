-- Rollback-only behavioral contract for 20260919_rbac_helper_security_invoker_v1.sql and
-- 20260919_import_batch_adapter_lineage_v1.sql. Requires both applied (or executed earlier in the same transaction).
-- Ends with RAISE EXCEPTION so nothing persists; pass = message starting with 'RESULTS: ALL PASS'.
do $test$
declare
 u1 uuid:=gen_random_uuid(); u2 uuid:=gen_random_uuid(); u3 uuid:=gen_random_uuid(); u5 uuid:=gen_random_uuid();
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid();
 b1 uuid:=gen_random_uuid(); b2 uuid:=gen_random_uuid(); b3 uuid:=gen_random_uuid(); b4 uuid:=gen_random_uuid(); s1 uuid:=gen_random_uuid(); s2 uuid:=gen_random_uuid();
 m1 text; m2 text; r text; n int;
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

 insert into auth.users(id) values(u1),(u2),(u3),(u5);
 insert into public.organizations(id,name,document) values(o1,'T-A','doc-'||o1),(o2,'T-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role,status) values
  (o1,u1,'admin','active'),(o2,u2,'admin','active'),(o1,u3,'agent','active'),(o1,u5,'admin','revoked');
 insert into public.import_sources(id,organization_id,name,source_kind) values(s1,o1,'a','manual'),(s2,o2,'b','manual');
 set local session_replication_role='replica';
 insert into public.import_batches(id,organization_id,source_id,original_filename,content_sha256,parser_key,received_by) values
  (b1,o1,s1,'a.csv',repeat('a',64),'2tech/busca_contrato_file',u1),
  (b2,o2,s2,'b.csv',repeat('b',64),'2tech/busca_contrato_file',u2),
  (b3,o1,s1,'c.csv',repeat('c',64),'daycoval-table-offer',u1),
  (b4,o1,s1,'d.csv',repeat('d',64),'2tech/busca_contrato_file',u3);
 set local session_replication_role='origin';

 -- ===== RBAC helper is SECURITY INVOKER and answers only about the caller =====
 perform pg_temp.check_that(not (select prosecdef from pg_proc where oid='public.has_active_organization_role(uuid,text[])'::regprocedure),'helper is SECURITY INVOKER (advisor WARN gone)');
 perform pg_temp.check_that(not has_function_privilege('anon','public.has_active_organization_role(uuid,text[])','EXECUTE'),'anon cannot execute helper');
 perform pg_temp.check_that(has_function_privilege('authenticated','public.has_active_organization_role(uuid,text[])','EXECUTE'),'authenticated can execute helper');
 perform pg_temp.check_that(pg_temp.run_as(u1,format($q$select public.has_active_organization_role(%L,array['admin'])::text$q$,o1))='true','admin has admin in own tenant');
 perform pg_temp.check_that(pg_temp.run_as(u1,format($q$select public.has_active_organization_role(%L,array['admin'])::text$q$,o2))='false','admin of A has nothing in tenant B');
 perform pg_temp.check_that(pg_temp.run_as(u3,format($q$select public.has_active_organization_role(%L,array['admin','manager'])::text$q$,o1))='false','agent is not admin/manager');
 perform pg_temp.check_that(pg_temp.run_as(u3,format($q$select public.has_active_organization_role(%L,array['agent'])::text$q$,o1))='true','agent has agent');
 perform pg_temp.check_that(pg_temp.run_as(u5,format($q$select public.has_active_organization_role(%L,array['admin'])::text$q$,o1))='false','revoked membership grants nothing');
 perform pg_temp.check_that(pg_temp.run_as(gen_random_uuid(),format($q$select public.has_active_organization_role(%L,array['admin'])::text$q$,o1))='false','user without membership: false');
 perform pg_temp.check_that(pg_temp.run_as(u1,format($q$select public.has_active_organization_role(%L,array['admin'])::text$q$,gen_random_uuid()))='false','unknown tenant: false (no oracle)');
 -- RLS + invoker RPC dependent on the helper keep working after the swap
 perform pg_temp.run_as(u1,format($q$with i as (insert into public.commercial_entities(organization_id,legal_name,entity_kind) values(%L,'x','other') returning 1) select count(*)::text from i$q$,o1));
 perform pg_temp.check_that(true,'RLS policy using helper still admits an admin insert');
 perform pg_temp.expect_err(u3,format($q$insert into public.commercial_entities(organization_id,legal_name,entity_kind) values(%L,'x','other')$q$,o1),'row-level security|violates','agent insert still denied by policy');
 perform pg_temp.expect_err(u1,format($q$insert into public.commercial_entities(organization_id,legal_name,entity_kind) values(%L,'x','other')$q$,o2),'row-level security|violates','cross-tenant insert still denied by policy');

 -- ===== adapter lineage: structure =====
 perform pg_temp.check_that(not (select prosecdef from pg_proc where oid='public.attach_import_batch_adapter(uuid,text)'::regprocedure),'public entry point is SECURITY INVOKER');
 perform pg_temp.check_that((select prosecdef and 'search_path=""' = any(proconfig) from pg_proc where oid='private.attach_import_batch_adapter(uuid,text)'::regprocedure),'private definer pins search_path=""');
 perform pg_temp.check_that(not has_function_privilege('anon','private.attach_import_batch_adapter(uuid,text)','EXECUTE') and not has_schema_privilege('anon','private','USAGE'),'anon: no USAGE on private, no EXECUTE');
 perform pg_temp.check_that(not has_function_privilege('anon','public.attach_import_batch_adapter(uuid,text)','EXECUTE'),'anon cannot execute the public entry point');
 perform pg_temp.check_that(pg_get_functiondef('private.attach_import_batch_adapter(uuid,text)'::regprocedure) !~* 'organization_id\s*=\s*p_|limit 1','no client org id, no LIMIT 1 tenant resolution');

 -- ===== adapter lineage: behaviour =====
 perform pg_temp.run_as(u1,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')::text$q$,b1));
 perform pg_temp.check_that((select adapter_id is not null and adapter_contract_version is not null from public.import_batches where id=b1),'attach sets adapter + contract version');
 perform pg_temp.run_as(u1,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')::text$q$,b1));
 perform pg_temp.check_that(true,'replay is a no-op');
 perform pg_temp.expect_err(u1,format($q$select public.attach_import_batch_adapter(%L,'bevi/webservice_agente')$q$,b1),'adapter_parser_mismatch|batch_adapter_immutable','other adapter cannot replace lineage');
 perform pg_temp.expect_err(u1,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')$q$,b3),'adapter_parser_mismatch','adapter must equal the real parser (forged parser)');
 perform pg_temp.expect_err(u1,format($q$select public.attach_import_batch_adapter(%L,'nope/none')$q$,b3),'adapter_not_found','forged adapter key');
 -- same error for: foreign batch, nonexistent batch, unauthorized member, revoked member, anonymous
 m1:=pg_temp.err_of(u1,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')$q$,b2));
 m2:=pg_temp.err_of(u1,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')$q$,gen_random_uuid()));
 perform pg_temp.check_that(m1='batch_not_found_or_forbidden' and m2=m1,'foreign batch and nonexistent batch are indistinguishable');
 perform pg_temp.check_that(pg_temp.err_of(u3,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')$q$,b3))=m1,'agent who is not the receiver: same error');
 perform pg_temp.check_that(pg_temp.err_of(u5,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')$q$,b1))=m1,'revoked member: same error');
 perform pg_temp.check_that(pg_temp.err_of(null,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')$q$,b1))=m1,'anonymous/no-uid: same error');
 perform pg_temp.check_that(pg_temp.err_of(u2,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')$q$,b1))=m1,'tenant B admin on tenant A batch: same error');
 -- receiver (agent) may attach to their own batch; admin of another tenant may not
 perform pg_temp.run_as(u3,format($q$select public.attach_import_batch_adapter(%L,'2tech/busca_contrato_file')::text$q$,b4));
 perform pg_temp.check_that((select adapter_id is not null from public.import_batches where id=b4),'batch receiver (agent) can attach to own batch');
 -- no broad UPDATE: members cannot change the batch; lineage is write-once even for privileged paths
 r:=pg_temp.run_as(u1,format($q$with u as (update public.import_batches set original_filename='hacked' where id=%L returning 1) select count(*)::text from u$q$,b1));
 perform pg_temp.check_that(r='0' and (select original_filename='a.csv' from public.import_batches where id=b1),'members cannot UPDATE import_batches (no broad update)');
 perform pg_temp.expect_err(u1,format($q$update public.import_batches set adapter_id=null where id=%L$q$,b1),'permission|row-level|immutable|governed|0','member cannot clear lineage');
 begin update public.import_batches set adapter_id=null,adapter_contract_version=null where id=b1; perform pg_temp.check_that(false,'privileged path cannot clear lineage');
 exception when others then perform pg_temp.check_that(sqlerrm ~ 'batch_adapter_immutable','write-once trigger blocks clearing lineage even for the owner role ('||sqlerrm||')'); end;
 begin update public.import_batches set adapter_id=(select id from public.integration_adapters where adapter_key='bevi/webservice_agente') where id=b3; perform pg_temp.check_that(false,'setting lineage without the governed RPC must fail');
 exception when others then perform pg_temp.check_that(sqlerrm ~ 'adapter_lineage_requires_governed_rpc','setting lineage outside the governed RPC is blocked ('||sqlerrm||')'); end;

 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into m1,n from t_res;
 raise exception 'RESULTS: %
%',case when n=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else n||' FAILED' end,m1;
end $test$;
