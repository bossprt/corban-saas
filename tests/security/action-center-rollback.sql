-- Rollback-only adversarial harness for 20261006_action_center_v1. Run the migration text first (same transaction until LIVE), then this DO block.
do $test$
declare
 o1 uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid(); uMg uuid:=gen_random_uuid(); uSv uuid:=gen_random_uuid(); uAg uuid:=gen_random_uuid(); uB uuid:=gen_random_uuid(); uR uuid:=gen_random_uuid();
 it text; it2 text; a uuid; b uuid; c uuid; res text; r text; k int;
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
 create function pg_temp.pg_err(q text,pat text,label text) returns void language plpgsql as $f$
 declare msg text;
 begin
  begin execute q; msg:=null; exception when others then msg:=sqlerrm; end;
  if msg is null then insert into t_res values(label||' [UNEXPECTED SUCCESS]',false);
  elsif msg !~ pat then insert into t_res values(label||' [got: '||msg||']',false);
  else insert into t_res values(label,true); end if;
 end $f$;
 create function pg_temp.check_that(cond boolean,label text) returns void language plpgsql as $f$
 begin insert into t_res values(label,coalesce(cond,false)); end $f$;
 create function pg_temp.sync(p_uid uuid,p_org uuid,p_rules text,p_items text) returns text language sql as $f$
  select pg_temp.u(p_uid,format('select public.sync_attention_items(%L,%L::text[],%L::jsonb)::text',p_org,p_rules,p_items)) $f$;
 create function pg_temp.item(p_rule text,p_key text,p_sev text) returns text language sql as $f$
  select json_build_object('rule_key',p_rule,'dedupe_key',p_key,'severity',p_sev,'title','Titulo '||p_key,'reason','porque','evidence',json_build_object('count',3),'impact','impacto','recommendation','faca isto','href','/app/operacao')::text $f$;
 insert into auth.users(id) values(uMg),(uSv),(uAg),(uB),(uR);
 insert into public.organizations(id,name,document) values(o1,'ATT-A','doc-'||o1),(o2,'ATT-B','doc-'||o2);
 insert into public.organization_memberships(organization_id,user_id,role,status) values(o1,uMg,'manager','active'),(o1,uSv,'supervisor','active'),(o1,uAg,'agent','active'),(o1,uR,'supervisor','inactive'),(o2,uB,'admin','active');
 it:='['||pg_temp.item('overdue_cases','overdue_cases','high')||','||pg_temp.item('stale_leads','stale_leads','medium')||','||pg_temp.item('failed_runs','failed_runs','critical')||']';

 res:=pg_temp.sync(uSv,o1,'{overdue_cases,stale_leads,failed_runs}',it);
 perform pg_temp.check_that(res like '%"opened": 3%' and res like '%"resolved": 0%','a supervisor syncs three detected signals: three items opened');
 perform pg_temp.check_that((select count(*) from public.operational_attention_events where event='detected')=3 and (select count(*) from public.operational_attention_items where status='open')=3,'each item has its "detected" event');
 res:=pg_temp.sync(uSv,o1,'{overdue_cases,stale_leads,failed_runs}',it);
 perform pg_temp.check_that(res like '%"opened": 0%' and res like '%"updated": 3%' and (select count(*) from public.operational_attention_items)=3 and (select count(*) from public.operational_attention_events)=3,'syncing again changes nothing structural: same 3 items, no duplicate history');
 res:=pg_temp.sync(uSv,o1,'{overdue_cases,stale_leads,failed_runs}','['||pg_temp.item('overdue_cases','overdue_cases','critical')||','||pg_temp.item('stale_leads','stale_leads','medium')||','||pg_temp.item('failed_runs','failed_runs','critical')||']');
 perform pg_temp.check_that((select severity='critical' from public.operational_attention_items where dedupe_key='overdue_cases') and exists(select 1 from public.operational_attention_events where event='severity_changed' and detail->>'from'='high' and detail->>'to'='critical'),'a severity change is recorded with from/to');
 -- auto resolve: only the rules that were evaluated
 res:=pg_temp.sync(uSv,o1,'{overdue_cases,stale_leads}','['||pg_temp.item('overdue_cases','overdue_cases','critical')||']');
 perform pg_temp.check_that(res like '%"resolved": 1%' and (select status='resolved' and resolved_at is not null from public.operational_attention_items where dedupe_key='stale_leads') and (select status='open' from public.operational_attention_items where dedupe_key='failed_runs'),'a cleared condition resolves automatically; a rule that was not evaluated (failed_runs) is untouched');
 perform pg_temp.check_that(exists(select 1 from public.operational_attention_events e join public.operational_attention_items i on i.id=e.item_id where i.dedupe_key='stale_leads' and e.event='auto_resolved'),'the auto resolution is in the history');
 res:=pg_temp.sync(uSv,o1,'{stale_leads}','['||pg_temp.item('stale_leads','stale_leads','low')||']');
 perform pg_temp.check_that((select count(*) from public.operational_attention_items where dedupe_key='stale_leads')=2 and (select count(*) from public.operational_attention_items where dedupe_key='stale_leads' and status='open')=1,'a resolved item is history: the condition coming back opens a NEW item');
 -- validation
 perform pg_temp.expect_err(uSv,format($q$select public.sync_attention_items(%L,'{a_rule}'::text[],%L::jsonb)$q$,o1,'['||pg_temp.item('a_rule','k1','urgent')||']'),'invalid_items','an unknown severity is refused');
 perform pg_temp.expect_err(uSv,format($q$select public.sync_attention_items(%L,'{a_rule}'::text[],%L::jsonb)$q$,o1,'['||pg_temp.item('other_rule','k1','low')||']'),'invalid_items','an item of a rule that was not declared as evaluated is refused');
 perform pg_temp.expect_err(uSv,format($q$select public.sync_attention_items(%L,'{a_rule}'::text[],%L::jsonb)$q$,o1,'[{"rule_key":"a_rule","severity":"low","title":"x","href":"/app/x"}]'),'invalid_items','a missing dedupe key is refused');
 perform pg_temp.expect_err(uSv,format($q$select public.sync_attention_items(%L,'{a_rule}'::text[],%L::jsonb)$q$,o1,'[{"rule_key":"a_rule","dedupe_key":"k9","severity":"low","title":"x","href":"/app/x","evidence":[1]}]'),'invalid_items','evidence must be an object');
 perform pg_temp.expect_err(uSv,format($q$select public.sync_attention_items(%L,'{a_rule}'::text[],%L::jsonb)$q$,o1,'[{"rule_key":"a_rule","dedupe_key":"k9","severity":"low","title":"x","href":"https://evil.example/x"}]'),'check constraint|violates','an external link is refused (internal /app paths only)');
 perform pg_temp.expect_err(uSv,format($q$select public.sync_attention_items(%L,'{a_rule}'::text[],%L::jsonb)$q$,o1,'{"a":1}'),'invalid_items','items must be an array');
 perform pg_temp.expect_err(uSv,format($q$select public.sync_attention_items(%L,'{a_rule}'::text[],(select jsonb_agg(%L::jsonb) from generate_series(1,201)))$q$,o1,pg_temp.item('a_rule','k1','low')),'invalid_items','more than 200 items refused');
 perform pg_temp.expect_err(uAg,format($q$select public.sync_attention_items(%L,'{a_rule}'::text[],'[]'::jsonb)$q$,o1),'not_authorized','an agent cannot sync');
 perform pg_temp.expect_err(uR,format($q$select public.sync_attention_items(%L,'{a_rule}'::text[],'[]'::jsonb)$q$,o1),'not_authorized','an inactive supervisor cannot');
 perform pg_temp.expect_err(uB,format($q$select public.sync_attention_items(%L,'{a_rule}'::text[],'[]'::jsonb)$q$,o1),'not_authorized','tenant B cannot write into tenant A');
 -- decisions
 select id into a from public.operational_attention_items where dedupe_key='overdue_cases';
 select id into b from public.operational_attention_items where dedupe_key='failed_runs';
 perform pg_temp.expect_err(uSv,format($q$select public.decide_attention_item(%L,'dismiss',null,null)$q$,a),'note_required','ignoring a signal needs a reason');
 perform pg_temp.expect_err(uSv,format($q$select public.decide_attention_item(%L,'dismiss','  ',null)$q$,a),'note_required','a blank reason is not a reason');
 perform pg_temp.check_that(pg_temp.u(uSv,format($q$select public.decide_attention_item(%L,'dismiss','ja tratado por telefone',null)::text$q$,a))=a::text,'dismiss with a reason');
 perform pg_temp.check_that((select status='dismissed' and decided_by=uSv from public.operational_attention_items where id=a) and exists(select 1 from public.operational_attention_events where item_id=a and event='dismissed' and note='ja tratado por telefone'),'dismissed, with who and why in the history');
 res:=pg_temp.sync(uSv,o1,'{overdue_cases}','['||pg_temp.item('overdue_cases','overdue_cases','critical')||']');
 perform pg_temp.check_that((select count(*) from public.operational_attention_items where dedupe_key='overdue_cases')=1 and (select status='dismissed' from public.operational_attention_items where id=a),'a dismissed signal does not come back as a new alert while the condition persists');
 perform pg_temp.check_that(pg_temp.u(uSv,format($q$select public.decide_attention_item(%L,'reopen',null,null)::text$q$,a))=a::text,'a dismissed item can be reopened (call returns the item)');
 perform pg_temp.check_that((select status='open' from public.operational_attention_items where id=a),'a dismissed item can be reopened');
 perform pg_temp.expect_err(uSv,format($q$select public.decide_attention_item(%L,'reopen',null,null)$q$,a),'invalid_action','an open item cannot be reopened');
 perform pg_temp.expect_err(uSv,format($q$select public.decide_attention_item(%L,'snooze',null,now()-interval '1 hour')$q$,b),'invalid_snooze','snoozing into the past is refused');
 perform pg_temp.expect_err(uSv,format($q$select public.decide_attention_item(%L,'snooze',null,now()+interval '91 days')$q$,b),'invalid_snooze','snoozing beyond 90 days is refused');
 perform pg_temp.expect_err(uSv,format($q$select public.decide_attention_item(%L,'snooze',null,null)$q$,b),'invalid_snooze','snoozing without a date is refused');
 perform pg_temp.check_that(pg_temp.u(uSv,format($q$select public.decide_attention_item(%L,'snooze','volto amanha',now()+interval '1 day')::text$q$,b))=b::text,'snooze for a day (call returns the item)');
 perform pg_temp.check_that((select status='snoozed' and snoozed_until>now() from public.operational_attention_items where id=b),'snooze for a day');
 update public.operational_attention_items set snoozed_until=now()-interval '1 minute' where id=b;
 res:=pg_temp.sync(uSv,o1,'{failed_runs}','['||pg_temp.item('failed_runs','failed_runs','critical')||']');
 perform pg_temp.check_that((select status='open' and snoozed_until is null from public.operational_attention_items where id=b) and exists(select 1 from public.operational_attention_events where item_id=b and event='reopened'),'an expired snooze reopens the item on the next sync');
 perform pg_temp.expect_err(uAg,format($q$select public.decide_attention_item(%L,'resolve',null,null)$q$,a),'not_authorized|item_not_found','an agent cannot decide');
 perform pg_temp.expect_err(uB,format($q$select public.decide_attention_item(%L,'resolve',null,null)$q$,a),'item_not_found','tenant B cannot even see the item');
 perform pg_temp.expect_err(uSv,format($q$select public.decide_attention_item(%L,'delete',null,null)$q$,a),'invalid_action','unknown action refused');
 perform pg_temp.check_that(pg_temp.u(uMg,format($q$select public.decide_attention_item(%L,'resolve','feito',null)::text$q$,b))=b::text,'a manager resolves an item (call returns the item)');
 perform pg_temp.check_that((select status='resolved' and decided_by=uMg from public.operational_attention_items where id=b),'a manager resolves an item');
 perform pg_temp.expect_err(uSv,format($q$select public.decide_attention_item(%L,'reopen',null,null)$q$,b),'item_already_resolved','a resolved item stays resolved');
 perform pg_temp.pg_err(format($q$update public.operational_attention_items set status='open' where id=%L$q$,b),'attention_item_is_resolved','even the platform cannot revive a resolved item');
 -- assignment
 perform pg_temp.check_that(pg_temp.u(uMg,format($q$select public.assign_attention_item(%L,%L)::text$q$,a,uSv))=a::text,'a manager assigns an item to an active member (call returns the item)');
 perform pg_temp.check_that((select assigned_to=uSv from public.operational_attention_items where id=a),'a manager assigns an item to an active member');
 perform pg_temp.expect_err(uSv,format($q$select public.assign_attention_item(%L,%L)$q$,a,uSv),'not_authorized','a supervisor cannot assign');
 perform pg_temp.expect_err(uMg,format($q$select public.assign_attention_item(%L,%L)$q$,a,uB),'assignee_not_member','the assignee must be an active member of the same tenant');
 perform pg_temp.expect_err(uMg,format($q$select public.assign_attention_item(%L,%L)$q$,a,uR),'assignee_not_member','an inactive member cannot be assigned');
 -- direct writes, history, visibility
 perform pg_temp.expect_err(uSv,format($q$insert into public.operational_attention_items(organization_id,rule_key,dedupe_key,severity,title,href) values(%L,'x_rule','kk1','low','t','/app/x')$q$,o1),'attention_write_requires_governed_rpc','direct insert refused');
 perform pg_temp.expect_err(uSv,format($q$update public.operational_attention_items set severity='low' where id=%L$q$,a),'attention_write_requires_governed_rpc','direct update refused');
 perform pg_temp.expect_err(uSv,format($q$delete from public.operational_attention_items where id=%L$q$,a),'permission denied','items are never deleted');
 perform pg_temp.expect_err(uSv,format($q$insert into public.operational_attention_events(organization_id,item_id,event) values(%L,%L,'resolved')$q$,o1,a),'attention_write_requires_governed_rpc','the history cannot be forged directly');
 perform pg_temp.pg_err(format($q$update public.operational_attention_events set note='x' where item_id=%L$q$,a),'attention_records_are_not_deletable','history cannot be edited, even by the platform');
 perform pg_temp.pg_err(format($q$delete from public.operational_attention_events where item_id=%L$q$,a),'attention_records_are_not_deletable','history cannot be deleted');
 perform pg_temp.check_that(pg_temp.u(uAg,'select (select count(*) from public.operational_attention_items)+(select count(*) from public.operational_attention_events)')::int=0,'FAIL CLOSED: agents read no item and no history');
 perform pg_temp.check_that(pg_temp.u(uB,'select (select count(*) from public.operational_attention_items)+(select count(*) from public.operational_attention_events)')::int=0,'tenant B reads nothing of tenant A');
 perform pg_temp.check_that(pg_temp.u(uSv,'select count(*)::text from public.operational_attention_items')::int>=3,'a supervisor reads the own tenant items');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prosecdef and n.nspname in ('public','private') and p.proname not in ('attach_import_batch_adapter','caller_role_in','commercial_route','import_row_evidence','lead_write','list_import_rows','bootstrap_organization_admin','get_user_organization_id')),'DEFINER inventory unchanged');
 perform pg_temp.check_that(not exists(select 1 from pg_proc p,lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) x where p.pronamespace='public'::regnamespace and p.proname in ('sync_attention_items','decide_attention_item','assign_attention_item') and (x.grantee=0 or x.grantee=(select oid from pg_roles where rolname='anon'))),'no Action Center function executable by PUBLIC or anon');
 select string_agg(case when pass then 'ok   ' else 'FAIL ' end||label,E'\n' order by pass,label),count(*) filter (where not pass) into r,k from t_res;
 raise exception 'RESULTS: %',case when k=0 then 'ALL PASS ('||(select count(*) from t_res)||' checks)' else k||' FAILED: '||left(r,1500) end;
end $test$;
