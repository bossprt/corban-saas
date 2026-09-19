-- Rollback-only proof that 20260927_membership_select_policy_merge_v1 changes NO visibility (one policy = the OR of the two it replaces).
-- Run the migration text first in the same transaction (until LIVE), then this DO block. Ends with RAISE EXCEPTION.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid();
 uA uuid:=gen_random_uuid(); uM uuid:=gen_random_uuid(); uS uuid:=gen_random_uuid(); uAg uuid:=gen_random_uuid(); uR uuid:=gen_random_uuid(); uAi uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid(); uX uuid:=gen_random_uuid();
 mAg uuid:=gen_random_uuid(); r text; k int;
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
 create function pg_temp.check_that(cond boolean,label text) returns void language plpgsql as $f$
 begin insert into t_res values(label,coalesce(cond,false)); end $f$;
 insert into auth.users(id) values(uA),(uM),(uS),(uAg),(uR),(uAi),(uB),(uX);
 insert into public.organizations(id,name,document) values(o1,'MP-A','doc-'||o1),(o2,'MP-B','doc-'||o2);
 insert into public.organization_memberships(id,organization_id,user_id,role,status) values
  (gen_random_uuid(),o1,uA,'admin','active'),(gen_random_uuid(),o1,uM,'manager','active'),(gen_random_uuid(),o1,uS,'supervisor','active'),(mAg,o1,uAg,'agent','active'),
  (gen_random_uuid(),o1,uR,'agent','inactive'),(gen_random_uuid(),o1,uAi,'admin','inactive'),(gen_random_uuid(),o2,uB,'admin','active'),(gen_random_uuid(),o1,uX,'agent','active'),(gen_random_uuid(),o2,uX,'admin','active');
 perform pg_temp.check_that((select count(*) from pg_policies where schemaname='public' and tablename='organization_memberships' and cmd='SELECT' and 'authenticated'=any(roles))=1,'exactly ONE select policy for authenticated (advisor warning gone)');
 perform pg_temp.check_that(not exists(select 1 from pg_policies where tablename='organization_memberships' and policyname in ('organization_memberships_select_self','organization_memberships_select_team')),'the two old policies are gone');
 perform pg_temp.check_that(pg_temp.u(uAg,'select count(*)::text from public.organization_memberships')='1','agent sees only own row');
 perform pg_temp.check_that(pg_temp.u(uS,'select count(*)::text from public.organization_memberships')='1','supervisor sees only own row');
 perform pg_temp.check_that(pg_temp.u(uA,format($q$select count(*)::text from public.organization_memberships where organization_id=%L$q$,o1))='7' and pg_temp.u(uM,format($q$select count(*)::text from public.organization_memberships where organization_id=%L$q$,o1))='7','admin and manager see the whole tenant A team (inactive rows included)');
 perform pg_temp.check_that(pg_temp.u(uA,format($q$select count(*)::text from public.organization_memberships where organization_id=%L$q$,o2))='0','admin of A sees nothing of B');
 perform pg_temp.check_that(pg_temp.u(uB,format($q$select count(*)::text from public.organization_memberships where organization_id=%L$q$,o1))='0' and pg_temp.u(uB,'select count(*)::text from public.organization_memberships')='2','admin of B sees B (2 rows incl. the multi-org user) and nothing of A');
 perform pg_temp.check_that(pg_temp.u(uR,'select count(*)::text from public.organization_memberships')='0','an inactive member sees nothing, not even their own row');
 perform pg_temp.check_that(pg_temp.u(uAi,'select count(*)::text from public.organization_memberships')='0','an INACTIVE admin sees nothing');
 perform pg_temp.check_that(pg_temp.u(uX,format($q$select count(*)::text from public.organization_memberships where organization_id=%L$q$,o1))='1' and pg_temp.u(uX,format($q$select count(*)::text from public.organization_memberships where organization_id=%L$q$,o2))='2','multi-org user: own row in A (agent), whole team in B (admin)');
 perform pg_temp.u(uA,format($q$select public.set_member_role(%L,'supervisor')::text$q$,mAg));
 perform pg_temp.check_that((select role='supervisor' from public.organization_memberships where id=mAg),'governed role change still works');
 perform pg_temp.check_that(has_table_privilege('authenticated','public.organization_memberships','SELECT') and not has_table_privilege('authenticated','public.organization_memberships','INSERT'),'grants unchanged');
 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED: '||r end;
end $test$;
