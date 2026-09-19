-- Rollback-only adversarial harness for 20260925_team_access_lifecycle_v1.
-- Run in ONE simple-query transaction: the migration text first, then this DO block. It always ends in RAISE EXCEPTION, so
-- nothing (DDL included) persists. When the migration is LIVE, run only the DO block.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid();
 uA uuid:=gen_random_uuid(); uA2 uuid:=gen_random_uuid(); uM uuid:=gen_random_uuid(); uM2 uuid:=gen_random_uuid(); uS uuid:=gen_random_uuid(); uAg uuid:=gen_random_uuid(); uAg2 uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid(); uN uuid:=gen_random_uuid(); uX uuid:=gen_random_uuid();
 mA uuid:=gen_random_uuid(); mA2 uuid:=gen_random_uuid(); mM uuid:=gen_random_uuid(); mM2 uuid:=gen_random_uuid(); mS uuid:=gen_random_uuid(); mAg uuid:=gen_random_uuid(); mAg2 uuid:=gen_random_uuid(); mB uuid:=gen_random_uuid();
 s1 uuid:=gen_random_uuid(); inv uuid; inv2 uuid; r text; k int; fe int; n int; rec record; i int;
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
 create function pg_temp.svc(q text) returns text language plpgsql as $f$
 begin return pg_temp.run_as('service_role',null,q); end $f$;
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
 -- shortcuts: RPC as a user
 create function pg_temp.inv(p_uid uuid,p_org uuid,p_email text,p_role text) returns text language sql as $f$
  select pg_temp.u(p_uid,format('select public.create_organization_invitation(%L,%L,%L)::text',p_org,p_email,p_role)) $f$;
 create function pg_temp.inv_err(p_uid uuid,p_org uuid,p_email text,p_role text,pat text,label text) returns void language sql as $f$
  select pg_temp.expect_err('authenticated',p_uid,format('select public.create_organization_invitation(%L,%L,%L)',p_org,p_email,p_role),pat,label) $f$;
 create function pg_temp.role_err(p_uid uuid,p_m uuid,p_role text,pat text,label text) returns void language sql as $f$
  select pg_temp.expect_err('authenticated',p_uid,format('select public.set_member_role(%L,%L)',p_m,p_role),pat,label) $f$;
 create function pg_temp.status_err(p_uid uuid,p_m uuid,p_status text,pat text,label text) returns void language sql as $f$
  select pg_temp.expect_err('authenticated',p_uid,format('select public.set_member_status(%L,%L)',p_m,p_status),pat,label) $f$;
 create function pg_temp.accept(p_uid uuid,p_email text) returns text language sql as $f$
  select pg_temp.svc(format($q$select coalesce(string_agg(x.outcome||':'||x.role||':'||x.organization_id,',' order by x.organization_id),'') from public.accept_organization_invitations(%L,%L) x$q$,p_uid,p_email)) $f$;

 insert into auth.users(id) values(uA),(uA2),(uM),(uM2),(uS),(uAg),(uAg2),(uB),(uN),(uX);
 insert into public.organizations(id,name,document) values(o1,'TM-A','doc-'||o1),(o2,'TM-B','doc-'||o2);
 insert into public.organization_memberships(id,organization_id,user_id,role,status) values
  (mA,o1,uA,'admin','active'),(mA2,o1,uA2,'admin','active'),(mM,o1,uM,'manager','active'),(mM2,o1,uM2,'manager','active'),(mS,o1,uS,'supervisor','active'),(mAg,o1,uAg,'agent','active'),(mAg2,o1,uAg2,'agent','active'),(mB,o2,uB,'admin','active');
 insert into public.import_sources(id,organization_id,name,source_kind) values(s1,o1,'src','manual');
 select count(*) into fe from public.financial_events;

 -- ---- surface
 perform pg_temp.expect_err('anon',null,'select public.set_member_role(gen_random_uuid(),''agent'')','permission denied','anon cannot call set_member_role');
 perform pg_temp.expect_err('anon',null,'select public.create_organization_invitation(gen_random_uuid(),''a@b.co'',''agent'')','permission denied','anon cannot call create_organization_invitation');
 perform pg_temp.expect_err('authenticated',uA,'select * from public.accept_organization_invitations(gen_random_uuid(),''a@b.co'')','permission denied','even an admin cannot call the service_role-only accept');
 perform pg_temp.check_that(has_function_privilege('service_role','public.accept_organization_invitations(uuid,text)','EXECUTE'),'service_role can accept invitations');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('create_organization_invitation','revoke_organization_invitation','set_member_role','set_member_status','accept_organization_invitations','can_manage_member_role','guard_membership_write','guard_invitation_write','guard_admin_event_write') and p.prosecdef),'no new function is SECURITY DEFINER');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and p.proname not in ('attach_import_batch_adapter','caller_role_in','commercial_route','import_row_evidence','lead_write','list_import_rows','bootstrap_organization_admin','get_user_organization_id')),'DEFINER inventory equals the 8 reviewed functions');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p,lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a where p.pronamespace='public'::regnamespace and p.proname in ('create_organization_invitation','revoke_organization_invitation','set_member_role','set_member_status','accept_organization_invitations') and (a.grantee=0 or a.grantee=(select oid from pg_roles where rolname='anon'))),'RPCs not executable by PUBLIC or anon');
 perform pg_temp.check_that(has_table_privilege('authenticated','public.organization_memberships','SELECT') and not has_table_privilege('authenticated','public.organization_memberships','INSERT') and not has_table_privilege('authenticated','public.organization_memberships','DELETE'),'authenticated: SELECT only on memberships (no INSERT/DELETE)');
 perform pg_temp.check_that(not has_column_privilege('authenticated','public.organization_memberships','user_id','UPDATE') and not has_column_privilege('authenticated','public.organization_memberships','organization_id','UPDATE') and has_column_privilege('authenticated','public.organization_memberships','role','UPDATE'),'authenticated may UPDATE only role/status/updated_at');
 perform pg_temp.check_that(not has_table_privilege('anon','public.organization_invitations','SELECT') and not has_table_privilege('anon','public.organization_admin_events','SELECT'),'anon has no privilege on the new tables');

 -- ---- policy predicate
 perform pg_temp.check_that(public.can_manage_member_role('admin','agent','admin') and public.can_manage_member_role('admin','admin','agent') and public.can_manage_member_role('admin',null,'manager'),'predicate: admin may do everything');
 perform pg_temp.check_that(public.can_manage_member_role('manager','agent','supervisor') and public.can_manage_member_role('manager',null,'agent'),'predicate: manager manages supervisor/agent');
 perform pg_temp.check_that(not public.can_manage_member_role('manager','agent','manager') and not public.can_manage_member_role('manager','manager','agent') and not public.can_manage_member_role('manager','admin','agent') and not public.can_manage_member_role('manager',null,'admin'),'predicate: manager cannot create/touch manager or admin');
 perform pg_temp.check_that(not public.can_manage_member_role('supervisor',null,'agent') and not public.can_manage_member_role('agent',null,'agent') and not public.can_manage_member_role(null,null,'agent') and not public.can_manage_member_role('admin',null,'root') and not public.can_manage_member_role('admin','root','agent'),'predicate: supervisor/agent/unknown denied, unknown roles denied');

 -- ---- direct writes are closed
 perform pg_temp.expect_err('authenticated',uA,format('update public.organization_memberships set role=''admin'' where id=%L',mAg),'governed_rpc','admin cannot UPDATE role directly');
 perform pg_temp.u(uAg,format('with x as (update public.organization_memberships set role=''admin'' where id=%L returning 1) select count(*)::text from x',mAg));
 perform pg_temp.check_that((select role from public.organization_memberships where id=mAg)='agent','agent direct UPDATE of own role changes nothing (RLS filters the row)');
 perform pg_temp.expect_err('authenticated',uA,format('update public.organization_memberships set user_id=%L where id=%L',uX,mAg),'permission denied','identity columns are not updatable (user_id)');
 perform pg_temp.expect_err('authenticated',uA,format('update public.organization_memberships set organization_id=%L where id=%L',o2,mAg),'permission denied','identity columns are not updatable (organization_id)');
 perform pg_temp.expect_err('authenticated',uA,format('insert into public.organization_memberships(organization_id,user_id,role,status) values(%L,%L,''admin'',''active'')',o1,uX),'permission denied','admin cannot INSERT a membership directly');
 perform pg_temp.expect_err('authenticated',uX,format('insert into public.organization_memberships(organization_id,user_id,role,status) values(%L,%L,''admin'',''active'')',o1,uX),'permission denied','outsider cannot INSERT a self membership');
 perform pg_temp.expect_err('authenticated',uA,format('delete from public.organization_memberships where id=%L',mAg),'permission denied','admin cannot DELETE a membership');
 perform pg_temp.expect_err('authenticated',uA,format('insert into public.organization_invitations(organization_id,email,role,invited_by) values(%L,''x@y.co'',''admin'',%L)',o1,uA),'governed_rpc','admin cannot INSERT an invitation directly');
 perform pg_temp.expect_err('authenticated',uA,format('insert into public.organization_admin_events(organization_id,actor_user_id,event_type) values(%L,%L,''invite_created'')',o1,uA),'governed_rpc','admin cannot forge an audit event directly');
 perform pg_temp.expect_err('authenticated',uA,format('delete from public.organization_admin_events where organization_id=%L',o1),'permission denied','audit events cannot be deleted by authenticated');
 perform pg_temp.expect_err('service_role',null,format('update public.organization_memberships set user_id=%L where id=%L',uX,mAg),'membership_identity_immutable','trigger: membership identity immutable even for service_role');

 -- ---- invitations: authorization
 inv:=pg_temp.inv(uA,o1,'  Novo.Agente@Example.COM ','agent')::uuid;
 perform pg_temp.check_that((select email='novo.agente@example.com' and role='agent' and status='pending' and invited_by=uA and expires_at>now()+interval '6 days' from public.organization_invitations where id=inv),'admin invites an agent; email stored normalized; expires in 7 days');
 perform pg_temp.check_that(pg_temp.inv(uA,o1,'novo.admin@example.com','admin')::uuid is not null,'admin may invite an admin');
 perform pg_temp.check_that(pg_temp.inv(uM,o1,'gerente.agente@example.com','supervisor')::uuid is not null,'manager may invite a supervisor');
 perform pg_temp.inv_err(uM,o1,'x1@example.com','admin','role_change_not_permitted','manager CANNOT invite an admin');
 perform pg_temp.inv_err(uM,o1,'x2@example.com','manager','role_change_not_permitted','manager CANNOT invite a manager');
 perform pg_temp.inv_err(uS,o1,'x3@example.com','agent','not_authorized','supervisor cannot invite');
 perform pg_temp.inv_err(uAg,o1,'x4@example.com','agent','not_authorized','agent cannot invite');
 perform pg_temp.inv_err(uA,o2,'x5@example.com','agent','not_authorized','admin of tenant A cannot invite into tenant B (forged organization_id)');
 perform pg_temp.inv_err(uX,o1,'x6@example.com','agent','not_authorized','outsider cannot invite');
 perform pg_temp.inv_err(uA,o1,'x7@example.com','root','invalid_role','forged role rejected');
 perform pg_temp.inv_err(uA,o1,'x7@example.com',null,'invalid_role','null role rejected');
 perform pg_temp.inv_err(uA,o1,'not-an-email','agent','invalid_email','malformed email rejected');
 perform pg_temp.inv_err(uA,o1,'','agent','invalid_email','empty email rejected');
 perform pg_temp.inv_err(uA,o1,'NOVO.agente@example.com','agent','invitation_already_pending','duplicate pending invitation rejected (case-insensitive)');
 perform pg_temp.expect_err('anon',null,format('select public.create_organization_invitation(%L,''a@b.co'',''agent'')',o1),'permission denied','anon cannot invite');
 -- rate limit: 20 per actor per hour
 for i in 1..18 loop perform pg_temp.inv(uA,o1,'bulk'||i||'@example.com','agent'); end loop;
 perform pg_temp.inv_err(uA,o1,'bulk-overflow@example.com','agent','invitation_rate_limited','invitation spam is rate limited (20/hour/actor)');

 -- ---- invitations: visibility and revocation
 perform pg_temp.check_that(pg_temp.u(uAg,'select count(*)::text from public.organization_invitations')='0','agent sees no invitations');
 perform pg_temp.check_that(pg_temp.u(uS,'select count(*)::text from public.organization_invitations')='0','supervisor sees no invitations');
 perform pg_temp.check_that(pg_temp.u(uB,'select count(*)::text from public.organization_invitations')='0','tenant B admin sees none of tenant A invitations');
 perform pg_temp.check_that(pg_temp.u(uM,'select count(*)::text from public.organization_invitations')::int>=20,'manager sees the organization invitations');
 perform pg_temp.expect_err('authenticated',uB,format('select public.revoke_organization_invitation(%L)',inv),'invitation_not_found','tenant B cannot revoke a tenant A invitation');
 perform pg_temp.expect_err('authenticated',uAg,format('select public.revoke_organization_invitation(%L)',inv),'invitation_not_found|not_authorized','agent cannot revoke');
 inv2:=(select id from public.organization_invitations where email='novo.admin@example.com');
 perform pg_temp.expect_err('authenticated',uM,format('select public.revoke_organization_invitation(%L)',inv2),'not_authorized','manager cannot revoke an admin invitation');
 perform pg_temp.check_that(pg_temp.u(uA,format('select public.revoke_organization_invitation(%L)::text',inv2))='','admin revokes an invitation');
 perform pg_temp.expect_err('authenticated',uA,format('select public.revoke_organization_invitation(%L)',inv2),'invitation_already_resolved','revoking twice is refused');
 perform pg_temp.check_that(pg_temp.accept(uN,'novo.admin@example.com')='','a revoked invitation cannot be accepted');
 perform pg_temp.inv_err(uA,o1,'x8@example.com','agent','invitation_rate_limited','(rate limit still holds)');
 -- a revoked invitation frees the email for a new one (not rate-limit tested: use a different actor)
 perform pg_temp.check_that(pg_temp.inv(uA2,o1,'novo.admin@example.com','manager')::uuid is not null,'after revocation the address can be invited again (by another admin)');

 -- ---- acceptance (service_role only; identity comes from verified Auth)
 perform pg_temp.check_that(pg_temp.accept(uN,'somebody.else@example.com')='','wrong email accepts nothing');
 perform pg_temp.check_that(pg_temp.accept(uN,'Novo.Agente@Example.com')='joined:agent:'||o1,'accept joins with the invited role (email match is case-insensitive)');
 perform pg_temp.check_that((select status='active' and role='agent' from public.organization_memberships where user_id=uN and organization_id=o1),'membership is active with that role');
 perform pg_temp.check_that(pg_temp.accept(uN,'novo.agente@example.com')='','replaying acceptance does nothing (no second membership)');
 perform pg_temp.check_that((select count(*) from public.organization_memberships where user_id=uN)=1,'exactly one membership after replay');
 perform pg_temp.check_that((select status='accepted' and accepted_user_id=uN and resolved_at is not null from public.organization_invitations where id=inv),'invitation resolved as accepted');
 perform pg_temp.check_that(pg_temp.u(uN,'select count(*)::text from public.organization_memberships')='1','new member sees only their own membership');
 perform pg_temp.check_that(pg_temp.u(uN,format('select count(*)::text from public.import_sources where organization_id=%L',o1))='1','new member reaches tenant A data (RLS via membership)');
 perform pg_temp.check_that(pg_temp.u(uN,format('select count(*)::text from public.import_sources where organization_id=%L',o2))='0','...and nothing of tenant B');
 -- expired
 perform pg_temp.inv(uM,o1,'expired@example.com','agent');
 set local session_replication_role='replica';
 update public.organization_invitations set expires_at=now()-interval '1 day' where email='expired@example.com';
 set local session_replication_role='origin';
 perform pg_temp.check_that(pg_temp.accept(uX,'expired@example.com')='','expired invitation is not accepted');
 perform pg_temp.check_that((select status='expired' from public.organization_invitations where email='expired@example.com'),'...and becomes expired');
 perform pg_temp.check_that(pg_temp.inv(uM,o1,'expired@example.com','agent')::uuid is not null,'an expired invitation does not block a fresh one');
 -- existing active member: an invitation never changes their role silently
 perform pg_temp.inv(uA2,o1,'already@example.com','admin');
 perform pg_temp.check_that(pg_temp.accept(uAg2,'already@example.com')='already_member:admin:'||o1,'existing active member: outcome already_member');
 perform pg_temp.check_that((select role='agent' from public.organization_memberships where id=mAg2),'...role UNCHANGED (an invitation never elevates silently)');
 -- revoked member re-invited -> reactivated with the invited role
 perform pg_temp.u(uA,format('select public.set_member_status(%L,''revoked'')',mAg2));
 perform pg_temp.inv(uM,o1,'again@example.com','supervisor');
 perform pg_temp.check_that(pg_temp.accept(uAg2,'again@example.com')='reactivated:supervisor:'||o1,'revoked member re-invited: outcome reactivated');
 perform pg_temp.check_that((select role='supervisor' and status='active' from public.organization_memberships where id=mAg2),'...with the invited role and active status');
 -- multi-org: a member of tenant B accepts an invitation to tenant A
 perform pg_temp.inv(uA2,o1,'multi@example.com','agent');
 perform pg_temp.check_that(pg_temp.accept(uB,'multi@example.com')='joined:agent:'||o1,'user of tenant B accepts an invitation to tenant A');
 perform pg_temp.check_that((select count(*) from public.organization_memberships where user_id=uB and status='active')=2 and (select role from public.organization_memberships where user_id=uB and organization_id=o2)='admin' and (select role from public.organization_memberships where user_id=uB and organization_id=o1)='agent','multi-org: roles are per organization (admin in B, agent in A)');
 perform pg_temp.expect_err('authenticated',uB,format('select public.set_member_role(%L,''agent'')',mAg),'not_authorized|membership_not_found','multi-org: being admin in B grants nothing over tenant A members');
 perform pg_temp.check_that(pg_temp.u(uB,format('select count(*)::text from public.organization_invitations where organization_id=%L',o1))='0','multi-org: agent in A sees no invitations of A even though admin of B');

 -- ---- role management
 perform pg_temp.check_that(pg_temp.u(uA,format('select public.set_member_role(%L,''supervisor'')::text',mAg))='','admin promotes agent to supervisor');
 perform pg_temp.check_that((select role from public.organization_memberships where id=mAg)='supervisor','role changed');
 perform pg_temp.role_err(uA,mA,'agent','cannot_change_own_membership','admin cannot change own role');
 perform pg_temp.role_err(uM,mM,'admin','cannot_change_own_membership','manager cannot self-promote');
 perform pg_temp.role_err(uS,mS,'admin','not_authorized|membership_not_found','supervisor cannot self-promote (row not even lockable)');
 perform pg_temp.role_err(uAg2,mAg,'admin','not_authorized|membership_not_found','a (re)activated supervisor cannot promote another member');
 perform pg_temp.role_err(uM,mAg,'manager','role_change_not_permitted','manager cannot promote to manager');
 perform pg_temp.role_err(uM,mAg,'admin','role_change_not_permitted','manager cannot promote to admin');
 perform pg_temp.role_err(uM,mM2,'agent','role_change_not_permitted','manager cannot demote another manager');
 perform pg_temp.role_err(uM,mA,'agent','role_change_not_permitted','manager cannot demote an admin');
 perform pg_temp.check_that(pg_temp.u(uM,format('select public.set_member_role(%L,''agent'')::text',mAg))='','manager moves supervisor to agent');
 perform pg_temp.role_err(uA,mAg,'agent','no_change','same role is refused (no noise events)');
 perform pg_temp.role_err(uA,mAg,'root','invalid_role','unknown role refused');
 perform pg_temp.role_err(uB,mAg,'supervisor','membership_not_found|not_authorized','tenant B admin cannot change a tenant A member');
 perform pg_temp.role_err(uX,mAg,'supervisor','membership_not_found','outsider cannot see the membership at all');
 perform pg_temp.expect_err('anon',null,format('select public.set_member_role(%L,''agent'')',mAg),'permission denied','anon cannot change roles');
 perform pg_temp.role_err(uA,gen_random_uuid(),'agent','membership_not_found','unknown membership id');
 -- last-admin invariant: two admins; one demotes the other; the demoted one cannot fight back; the remaining admin cannot demote self
 perform pg_temp.check_that(pg_temp.u(uA,format('select public.set_member_role(%L,''manager'')::text',mA2))='','admin demotes the other admin');
 perform pg_temp.role_err(uA2,mA,'agent','role_change_not_permitted','the demoted admin (now manager) cannot demote the remaining admin');
 perform pg_temp.role_err(uA,mA,'manager','cannot_change_own_membership','the remaining admin cannot demote self');
 perform pg_temp.status_err(uA,mA,'inactive','cannot_change_own_membership','the remaining admin cannot deactivate self');
 perform pg_temp.status_err(uA2,mA,'inactive','role_change_not_permitted','a manager cannot deactivate the remaining admin');
 perform pg_temp.check_that((select count(*) from public.organization_memberships where organization_id=o1 and role='admin' and status='active')>=1,'INVARIANT: the organization still has an active admin');

 -- ---- revocation is effective at the database
 perform pg_temp.check_that(pg_temp.u(uAg,format('select count(*)::text from public.import_sources where organization_id=%L',o1))='1','before: agent reads tenant data');
 perform pg_temp.check_that(pg_temp.u(uM,format('select public.set_member_status(%L,''inactive'')::text',mAg))='','manager deactivates an agent');
 perform pg_temp.check_that(pg_temp.u(uAg,format('select count(*)::text from public.import_sources where organization_id=%L',o1))='0','AFTER: the very next query returns no tenant data');
 perform pg_temp.check_that(pg_temp.u(uAg,'select count(*)::text from public.organization_memberships')='0','AFTER: deactivated user sees no active membership');
 perform pg_temp.check_that(pg_temp.u(uAg,'select count(*)::text from public.organizations')='0','AFTER: the organization itself is invisible');
 perform pg_temp.expect_err('authenticated',uAg,format('select public.set_member_role(%L,''agent'')',mAg2),'not_authorized|membership_not_found','AFTER: deactivated user cannot call role RPCs');
 perform pg_temp.expect_err('authenticated',uAg,format('select public.create_organization_invitation(%L,''p@q.co'',''agent'')',o1),'not_authorized','AFTER: deactivated user cannot invite');
 perform pg_temp.status_err(uA,mAg,'inactive','no_change','deactivating twice is refused');
 perform pg_temp.status_err(uA,mAg,'banana','invalid_status','unknown status refused');
 perform pg_temp.status_err(uM,mM2,'inactive','role_change_not_permitted','manager cannot deactivate another manager');
 perform pg_temp.status_err(uM,mM,'inactive','cannot_change_own_membership','manager cannot deactivate self');
 perform pg_temp.status_err(uS,mAg,'active','not_authorized|membership_not_found','supervisor cannot reactivate');
 perform pg_temp.status_err(uB,mAg,'active','membership_not_found|not_authorized','tenant B admin cannot reactivate a tenant A member');
 perform pg_temp.check_that(pg_temp.u(uA,format('select public.set_member_status(%L,''active'')::text',mAg))='','admin reactivates');
 perform pg_temp.check_that(pg_temp.u(uAg,format('select count(*)::text from public.import_sources where organization_id=%L',o1))='1','after reactivation access is back');
 perform pg_temp.check_that(pg_temp.accept(uAg,'nobody@example.com')='','a deactivated-then-reactivated user is unaffected by unrelated acceptance');

 -- ---- team visibility
 perform pg_temp.check_that(pg_temp.u(uA,format('select count(*)::text from public.organization_memberships where organization_id=%L',o1))::int>=8,'admin sees the whole team (including inactive rows)');
 perform pg_temp.check_that(pg_temp.u(uA,format('select count(*)::text from public.organization_memberships where organization_id=%L',o2))='0','admin of A sees none of B''s team');
 perform pg_temp.check_that(pg_temp.u(uAg,'select count(*)::text from public.organization_memberships')='1','agent sees only own membership');
 perform pg_temp.check_that(pg_temp.u(uS,'select count(*)::text from public.organization_memberships')='1','supervisor sees only own membership');

 -- ---- audit trail
 perform pg_temp.check_that(exists(select 1 from public.organization_admin_events where organization_id=o1 and event_type='invite_created' and actor_user_id=uA and target_email='novo.agente@example.com' and details->>'role'='agent'),'audit: invite_created');
 perform pg_temp.check_that(exists(select 1 from public.organization_admin_events where event_type='invite_revoked' and actor_user_id=uA),'audit: invite_revoked');
 perform pg_temp.check_that(exists(select 1 from public.organization_admin_events where event_type='invite_accepted' and actor_user_id=uN and details->>'outcome'='joined'),'audit: invite_accepted (actor = the accepting user)');
 perform pg_temp.check_that(exists(select 1 from public.organization_admin_events where event_type='member_role_changed' and target_user_id=uAg and details->>'from'='agent' and details->>'to'='supervisor'),'audit: member_role_changed with from/to');
 perform pg_temp.check_that(exists(select 1 from public.organization_admin_events where event_type='member_deactivated' and target_user_id=uAg) and exists(select 1 from public.organization_admin_events where event_type='member_reactivated' and target_user_id=uAg),'audit: deactivation and reactivation');
 perform pg_temp.check_that(not exists(select 1 from public.organization_admin_events where details::text ~* '(token|password|secret|apikey|bearer)'),'audit: no token/password/secret content');
 perform pg_temp.check_that((select count(*) from public.organization_admin_events where event_type='member_role_changed' and details->>'from'=details->>'to')=0,'audit: no no-op events');
 perform pg_temp.check_that(pg_temp.u(uAg,'select count(*)::text from public.organization_admin_events')='0' and pg_temp.u(uS,'select count(*)::text from public.organization_admin_events')='0','audit: agent/supervisor cannot read the trail');
 perform pg_temp.check_that(pg_temp.u(uM,format('select count(*)::text from public.organization_admin_events where organization_id=%L',o1))::int>=5,'audit: manager reads the trail');
 perform pg_temp.check_that(pg_temp.u(uB,format('select count(*)::text from public.organization_admin_events where organization_id=%L',o1))='0','audit: tenant B cannot read tenant A trail');
 perform pg_temp.expect_err('service_role',null,format('update public.organization_admin_events set details=''{}'' where organization_id=%L',o1),'admin_events_append_only','audit: not updatable even by service_role');
 perform pg_temp.expect_err('service_role',null,format('delete from public.organization_admin_events where organization_id=%L',o1),'admin_events_append_only','audit: not deletable even by service_role');
 perform pg_temp.expect_err('service_role',null,format('delete from public.organization_invitations where organization_id=%L',o1),'invitation_delete_forbidden','invitations are never deleted');
 perform pg_temp.expect_err('service_role',null,format('update public.organization_invitations set role=''admin'' where id=%L',inv),'invitation_identity_immutable|invitation_already_resolved','invitation identity is immutable');
 perform pg_temp.check_that((select count(*) from public.financial_events)=fe,'no financial event created by any of this');

 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %
%',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED' end,case when k=0 then '' else r end;
end $test$;
