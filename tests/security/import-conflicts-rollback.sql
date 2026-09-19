-- Rollback-only behavioral contract for 20260919_import_conflicts_v1.sql (requires it applied, or executed earlier in the
-- same transaction). Ends with RAISE EXCEPTION; pass = message starting with 'RESULTS: ALL PASS'.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid(); uS uuid:=gen_random_uuid(); uA uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid();
 s1 uuid:=gen_random_uuid(); s2 uuid:=gen_random_uuid(); b1 uuid:=gen_random_uuid(); b2 uuid:=gen_random_uuid(); b3 uuid:=gen_random_uuid();
 rr1 uuid:=gen_random_uuid(); rr2 uuid:=gen_random_uuid(); rrB uuid:=gen_random_uuid(); rr3 uuid:=gen_random_uuid();
 f text; n text; cid uuid; r text; k int; ev_before int;
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

 insert into auth.users(id) values(uS),(uA),(uB);
 insert into public.organizations(id,name,document) values(o1,'C-A','doc-'||o1),(o2,'C-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role) values(o1,uS,'supervisor'),(o1,uA,'agent'),(o2,uB,'admin');
 insert into public.import_sources(id,organization_id,name,source_kind) values(s1,o1,'a','manual'),(s2,o2,'b','manual');
 set local session_replication_role='replica';
 insert into public.import_batches(id,organization_id,source_id,original_filename,content_sha256) values(b1,o1,s1,'a.csv',repeat('a',64)),(b3,o1,s1,'c.csv',repeat('c',64)),(b2,o2,s2,'b.csv',repeat('b',64));
 insert into public.import_raw_rows(id,organization_id,batch_id,row_number,raw_payload,raw_hash) values
  (rr1,o1,b1,1,'{"x":1}',repeat('1',64)),(rr2,o1,b1,2,'{"x":2}',repeat('2',64)),(rr3,o1,b3,1,'{"x":3}',repeat('3',64)),(rrB,o2,b2,1,'{"x":9}',repeat('9',64));
 set local session_replication_role='origin';
 select count(*) into ev_before from public.financial_events;

 f:=format('[{"kind":"contradictory_status","severity":"review","identityKey":"daycoval::100","detail":{"dimension":"bank_client","values":["Pago","Cancelado"]},"rawRowIds":["%s","%s"]},{"kind":"duplicate_row","severity":"info","identityKey":"daycoval::100","detail":{},"rawRowIds":["%s"]}]',rr1,rr2,rr1);
 n:=pg_temp.run_as(uS,format($q$select public.record_import_conflicts(%L,%L::jsonb)::text$q$,b1,f));
 perform pg_temp.check_that(n='2','supervisor records two conflicts for the batch');
 perform pg_temp.check_that(pg_temp.run_as(uS,format($q$select public.record_import_conflicts(%L,%L::jsonb)::text$q$,b1,f))='0','replay is idempotent by fingerprint (no duplicates)');
 perform pg_temp.check_that((select count(*) from public.import_conflict_rows)=3,'raw-row evidence links preserved (2+1)');
 perform pg_temp.check_that((select bool_and(not auto_publish_allowed) from public.import_conflicts),'no conflict can authorize automatic publication');
 perform pg_temp.check_that((select count(*) from public.financial_events)=ev_before,'recording conflicts creates no financial facts');
 perform pg_temp.expect_err(uA,format($q$select public.record_import_conflicts(%L,%L::jsonb)$q$,b1,f),'batch_not_found_or_forbidden','agent cannot record conflicts');
 perform pg_temp.expect_err(uB,format($q$select public.record_import_conflicts(%L,%L::jsonb)$q$,b1,f),'batch_not_found_or_forbidden','tenant B cannot record conflicts on tenant A batch');
 perform pg_temp.expect_err(uS,format($q$select public.record_import_conflicts(%L,%L::jsonb)$q$,b2,f),'batch_not_found_or_forbidden','tenant A supervisor cannot use tenant B batch');
 perform pg_temp.expect_err(uS,format($q$select public.record_import_conflicts(%L,%L::jsonb)$q$,b1,format('[{"kind":"duplicate_row","severity":"info","rawRowIds":["%s"]}]',rr3)),'conflict_row_not_in_batch','row from another batch of the same tenant is rejected');
 perform pg_temp.expect_err(uS,format($q$select public.record_import_conflicts(%L,%L::jsonb)$q$,b1,format('[{"kind":"duplicate_row","severity":"info","rawRowIds":["%s"]}]',rrB)),'conflict_row_not_in_batch','cross-tenant raw row is rejected');
 perform pg_temp.expect_err(uS,format($q$select public.record_import_conflicts(%L,%L::jsonb)$q$,b1,format('[{"kind":"made_up","severity":"info","rawRowIds":["%s"]}]',rr1)),'violates check','unknown kind rejected by CHECK');
 perform pg_temp.expect_err(uS,format($q$insert into public.import_conflicts(organization_id,batch_id,kind,severity,fingerprint) values(%L,%L,'duplicate_row','info','x')$q$,o1,b1),'import_conflict_requires_governed_rpc','direct insert blocked');
 perform pg_temp.expect_err(uS,format($q$select public.record_import_conflicts(%L,%L::jsonb)$q$,b1,'[{"kind":"duplicate_row","severity":"info","rawRowIds":[]}]'),'conflict_evidence_required','a conflict without raw evidence is rejected');
 perform pg_temp.check_that(pg_temp.run_as(uS,format($q$select public.record_import_conflicts(%L,%L::jsonb)::text$q$,b1,format('[{"kind":"unknown_schema","severity":"review","detail":{"reason":"x"},"rawRowIds":["%s","%s"]}]',rr2,rr2)))='1','duplicate raw ids inside a finding are de-duplicated (no PK error)');
 perform pg_temp.expect_err(uS,format($q$select public.record_import_conflicts(%L,(select jsonb_agg(jsonb_build_object('kind','duplicate_row','severity','info','identityKey',g::text,'rawRowIds',jsonb_build_array(%L))) from generate_series(1,501) g))$q$,b1,rr1::text),'too_many_findings','finding count is capped');
 perform pg_temp.expect_err(uS,format($q$select public.record_import_conflicts(%L,%L::jsonb)$q$,b1,format('[{"kind":"duplicate_row","severity":"info","identityKey":"big","detail":{"x":"%s"},"rawRowIds":["%s"]}]',repeat('a',9000),rr1)),'violates check','oversized detail is rejected');
 begin
  perform set_config('corban.import_conflict_rpc','on',true);
  insert into public.import_conflict_rows(conflict_id,organization_id,raw_row_id) select id,o1,rr3 from public.import_conflicts where kind='contradictory_status';
  perform pg_temp.check_that(false,'guard: raw row from ANOTHER batch must not link to the conflict');
 exception when others then perform pg_temp.check_that(sqlerrm ~ 'tenant_or_batch_mismatch','guard: conflict->raw_row->batch integrity holds even for the owner role ('||sqlerrm||')'); end;
 perform set_config('corban.import_conflict_rpc','off',true);
 perform pg_temp.check_that(pg_temp.run_as(uA,'select count(*)::text from public.import_conflicts')='0','agent reads no conflicts');
 perform pg_temp.check_that(pg_temp.run_as(uB,'select count(*)::text from public.import_conflicts')='0','tenant B reads no tenant A conflicts');
 perform pg_temp.check_that(pg_temp.run_as(uS,'select count(*)::text from public.import_conflicts')='3','supervisor reads tenant conflicts');
 select id into cid from public.import_conflicts where kind='contradictory_status';
 perform pg_temp.expect_err(uS,format($q$select public.resolve_import_conflict(%L,'resolved','short')$q$,cid),'resolution_note_length_invalid','resolution note must be 10..2000 chars');
 perform pg_temp.expect_err(uS,format($q$update public.import_conflicts set detail='{}' where id=%L$q$,cid),'import_conflict_evidence_is_immutable','evidence (detail) is immutable');
 perform pg_temp.expect_err(uS,format($q$update public.import_conflicts set kind='duplicate_row' where id=%L$q$,cid),'import_conflict_evidence_is_immutable','kind is immutable');
 perform pg_temp.expect_err(uS,format($q$update public.import_conflicts set status='resolved' where id=%L$q$,cid),'resolution_note_required','resolution requires a note');
 perform pg_temp.expect_err(uA,format($q$select public.resolve_import_conflict(%L,'resolved','looked at it')$q$,cid),'conflict_not_found_or_forbidden','agent cannot resolve');
 perform pg_temp.expect_err(uB,format($q$select public.resolve_import_conflict(%L,'resolved','looked at it')$q$,cid),'conflict_not_found_or_forbidden','tenant B cannot resolve');
 perform pg_temp.run_as(uS,format($q$select public.resolve_import_conflict(%L,'resolved','bank confirmed the later status')::text$q$,cid));
 perform pg_temp.check_that((select status='resolved' and resolved_by=uS and resolved_at is not null from public.import_conflicts where id=cid),'resolution stamped by the database session');
 perform pg_temp.expect_err(uS,format($q$select public.resolve_import_conflict(%L,'dismissed','reopen attempt')$q$,cid),'import_conflict_already_closed','a closed conflict cannot be reopened or changed');
 perform pg_temp.check_that((select count(*) from public.financial_events)=ev_before,'resolving a conflict creates no financial facts');
 perform pg_temp.check_that((select count(*) from public.import_raw_rows)=4 and (select raw_payload->>'x' from public.import_raw_rows where id=rr1)='1','raw evidence untouched');

 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %
%',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED' end,r;
end $test$;
