-- PREPARED, NOT APPLIED. Action Center (NEXT-WAVE-PLAN-V3, wave E): lifecycle + history of "attention items" produced by DETERMINISTIC rules.
-- The rules themselves live in the application (pure, tested, with evidence); the database owns what must be trustworthy: one active item per key, the status
-- machine, the append-only history and who may decide. No AI, no money movement, no action on business data: an item only points at the screen where a person acts.
-- Additive, SECURITY INVOKER, tenant-scoped, supervisor and above (fail closed for operators).
create table public.operational_attention_items(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 rule_key text not null check (rule_key ~ '^[a-z][a-z0-9_]{2,59}$'),
 dedupe_key text not null check (length(dedupe_key) between 3 and 160),
 severity text not null check (severity in ('critical','high','medium','low')),
 title text not null check (length(btrim(title)) between 1 and 160),
 reason text not null default '' check (length(reason)<=500),
 evidence jsonb not null default '{}'::jsonb check (jsonb_typeof(evidence)='object' and pg_column_size(evidence)<=8192),
 impact text not null default '' check (length(impact)<=300),
 recommendation text not null default '' check (length(recommendation)<=300),
 href text not null check (href ~ '^/app(/[a-z0-9_-]+)*$'),
 status text not null default 'open' check (status in ('open','resolved','dismissed','snoozed')),
 snoozed_until timestamptz,
 assigned_to uuid references auth.users(id) on delete set null,
 first_detected_at timestamptz not null default now(),
 last_detected_at timestamptz not null default now(),
 resolved_at timestamptz,
 decided_by uuid references auth.users(id) on delete set null,
 unique (organization_id,id),
 check (status<>'snoozed' or snoozed_until is not null)
);
-- one ACTIVE item per key (a dismissed item stays "active" so the same condition does not come back as a new alert every load)
create unique index operational_attention_items_active_key on public.operational_attention_items(organization_id,dedupe_key) where status in ('open','snoozed','dismissed');
create index operational_attention_items_org_status_idx on public.operational_attention_items(organization_id,status,severity);
create table public.operational_attention_events(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 item_id uuid not null,
 event text not null check (event in ('detected','severity_changed','resolved','auto_resolved','dismissed','snoozed','reopened','assigned')),
 actor uuid references auth.users(id) on delete set null,
 note text check (note is null or length(note)<=500),
 detail jsonb not null default '{}'::jsonb check (jsonb_typeof(detail)='object'),
 created_at timestamptz not null default now(),
 foreign key (organization_id,item_id) references public.operational_attention_items(organization_id,id) on delete restrict
);
create index operational_attention_events_item_idx on public.operational_attention_events(organization_id,item_id,created_at);

create or replace function public.guard_attention_write() returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='DELETE' or (tg_table_name='operational_attention_events' and tg_op='UPDATE') then raise exception 'attention_records_are_not_deletable'; end if;
 if current_user in ('authenticated','anon') and current_setting('corban.attention_rpc',true) is distinct from 'on' then raise exception 'attention_write_requires_governed_rpc'; end if;
 -- (nested on purpose: plpgsql does not short-circuit "and", and the events table has no rule_key column)
 if tg_table_name='operational_attention_items' and tg_op='UPDATE' then
  if new.organization_id is distinct from old.organization_id or new.rule_key is distinct from old.rule_key or new.dedupe_key is distinct from old.dedupe_key or new.first_detected_at is distinct from old.first_detected_at then raise exception 'attention_identity_is_immutable'; end if;
  -- a resolved item is history: it never comes back (a new detection opens a new item)
  if old.status='resolved' then raise exception 'attention_item_is_resolved'; end if;
 end if;
 return new;
end $$;
create trigger operational_attention_items_00_guard before insert or update or delete on public.operational_attention_items for each row execute function public.guard_attention_write();
create trigger operational_attention_events_00_guard before insert or update or delete on public.operational_attention_events for each row execute function public.guard_attention_write();
alter table public.operational_attention_items enable row level security;
alter table public.operational_attention_events enable row level security;
revoke all on public.operational_attention_items,public.operational_attention_events from public,anon,authenticated;
grant select,insert,update on public.operational_attention_items to authenticated;
grant select,insert on public.operational_attention_events to authenticated;
create policy operational_attention_items_select on public.operational_attention_items for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy operational_attention_items_insert on public.operational_attention_items for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy operational_attention_items_update on public.operational_attention_items for update to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor'])) with check (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy operational_attention_events_select on public.operational_attention_events for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy operational_attention_events_insert on public.operational_attention_events for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));

-- p_items = [{"rule_key","dedupe_key","severity","title","reason","evidence":{},"impact","recommendation","href"}]. p_rule_keys lists the rules that were EVALUATED in this
-- run: an active item of one of those rules that is no longer detected is resolved automatically (the condition cleared). Rules that were not evaluated are untouched.
create or replace function public.sync_attention_items(p_organization uuid,p_rule_keys text[],p_items jsonb) returns jsonb language plpgsql set search_path='' as $$
declare it jsonb; v_id uuid; v_old public.operational_attention_items%rowtype; v_keys text[]:='{}'; v_opened integer:=0; v_updated integer:=0; v_resolved integer:=0; r record;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 if p_organization is null or not public.has_active_organization_role(p_organization,array['admin','manager','supervisor']) then raise exception 'not_authorized'; end if;
 if p_rule_keys is null or coalesce(array_length(p_rule_keys,1),0)>50 then raise exception 'invalid_items'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)>200 then raise exception 'invalid_items'; end if;
 perform pg_advisory_xact_lock(hashtextextended('attention:'||p_organization::text,0));
 perform set_config('corban.attention_rpc','on',true);
 for it in select * from jsonb_array_elements(p_items) loop
  if jsonb_typeof(it)<>'object' or not (it->>'rule_key') = any(p_rule_keys) or (it->>'severity') not in ('critical','high','medium','low') or coalesce(it->>'dedupe_key','')='' then raise exception 'invalid_items'; end if;
  if jsonb_typeof(coalesce(it->'evidence','{}'::jsonb))<>'object' then raise exception 'invalid_items'; end if;
  v_keys:=v_keys||(it->>'dedupe_key');
  select * into v_old from public.operational_attention_items x where x.organization_id=p_organization and x.dedupe_key=it->>'dedupe_key' and x.status in ('open','snoozed','dismissed');
  if not found then
   insert into public.operational_attention_items(organization_id,rule_key,dedupe_key,severity,title,reason,evidence,impact,recommendation,href)
    values(p_organization,it->>'rule_key',it->>'dedupe_key',it->>'severity',it->>'title',coalesce(it->>'reason',''),coalesce(it->'evidence','{}'::jsonb),coalesce(it->>'impact',''),coalesce(it->>'recommendation',''),it->>'href') returning id into v_id;
   insert into public.operational_attention_events(organization_id,item_id,event,actor,detail) values(p_organization,v_id,'detected',auth.uid(),jsonb_build_object('severity',it->>'severity'));
   v_opened:=v_opened+1;
  else
   update public.operational_attention_items set last_detected_at=now(),severity=it->>'severity',title=it->>'title',reason=coalesce(it->>'reason',''),evidence=coalesce(it->'evidence','{}'::jsonb),impact=coalesce(it->>'impact',''),recommendation=coalesce(it->>'recommendation',''),href=it->>'href',
     status=case when v_old.status='snoozed' and v_old.snoozed_until<=now() then 'open' else v_old.status end,
     snoozed_until=case when v_old.status='snoozed' and v_old.snoozed_until<=now() then null else v_old.snoozed_until end
    where id=v_old.id;
   if v_old.severity<>it->>'severity' then insert into public.operational_attention_events(organization_id,item_id,event,actor,detail) values(p_organization,v_old.id,'severity_changed',auth.uid(),jsonb_build_object('from',v_old.severity,'to',it->>'severity')); end if;
   if v_old.status='snoozed' and v_old.snoozed_until<=now() then insert into public.operational_attention_events(organization_id,item_id,event,actor) values(p_organization,v_old.id,'reopened',auth.uid()); end if;
   v_updated:=v_updated+1;
  end if;
 end loop;
 for r in select x.id from public.operational_attention_items x where x.organization_id=p_organization and x.rule_key=any(p_rule_keys) and x.status in ('open','snoozed','dismissed') and not (x.dedupe_key=any(v_keys)) loop
  update public.operational_attention_items set status='resolved',resolved_at=now(),decided_by=null where id=r.id;
  insert into public.operational_attention_events(organization_id,item_id,event,actor) values(p_organization,r.id,'auto_resolved',auth.uid());
  v_resolved:=v_resolved+1;
 end loop;
 perform set_config('corban.attention_rpc','off',true);
 return jsonb_build_object('opened',v_opened,'updated',v_updated,'resolved',v_resolved);
end $$;

create or replace function public.decide_attention_item(p_item uuid,p_action text,p_note text,p_snooze_until timestamptz) returns uuid language plpgsql set search_path='' as $$
declare i public.operational_attention_items%rowtype; v_note text:=nullif(btrim(coalesce(p_note,'')),'');
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into i from public.operational_attention_items x where x.id=p_item for update;
 if not found then raise exception 'item_not_found'; end if;
 if not public.has_active_organization_role(i.organization_id,array['admin','manager','supervisor']) then raise exception 'not_authorized'; end if;
 if p_action is null or p_action not in ('resolve','dismiss','snooze','reopen') then raise exception 'invalid_action'; end if;
 if v_note is not null and length(v_note)>500 then raise exception 'invalid_action'; end if;
 if i.status='resolved' then raise exception 'item_already_resolved'; end if;
 perform set_config('corban.attention_rpc','on',true);
 if p_action='resolve' then
  update public.operational_attention_items set status='resolved',resolved_at=now(),decided_by=auth.uid(),snoozed_until=null where id=i.id;
  insert into public.operational_attention_events(organization_id,item_id,event,actor,note) values(i.organization_id,i.id,'resolved',auth.uid(),v_note);
 elsif p_action='dismiss' then
  -- ignoring a signal is a decision: it needs a reason (audit)
  if v_note is null or length(v_note)<3 then raise exception 'note_required'; end if;
  update public.operational_attention_items set status='dismissed',decided_by=auth.uid(),snoozed_until=null where id=i.id;
  insert into public.operational_attention_events(organization_id,item_id,event,actor,note) values(i.organization_id,i.id,'dismissed',auth.uid(),v_note);
 elsif p_action='snooze' then
  if p_snooze_until is null or p_snooze_until<=now() or p_snooze_until>now()+interval '90 days' then raise exception 'invalid_snooze'; end if;
  update public.operational_attention_items set status='snoozed',snoozed_until=p_snooze_until,decided_by=auth.uid() where id=i.id;
  insert into public.operational_attention_events(organization_id,item_id,event,actor,note,detail) values(i.organization_id,i.id,'snoozed',auth.uid(),v_note,jsonb_build_object('until',p_snooze_until));
 else
  if i.status='open' then raise exception 'invalid_action'; end if;
  update public.operational_attention_items set status='open',snoozed_until=null,decided_by=auth.uid() where id=i.id;
  insert into public.operational_attention_events(organization_id,item_id,event,actor,note) values(i.organization_id,i.id,'reopened',auth.uid(),v_note);
 end if;
 perform set_config('corban.attention_rpc','off',true);
 return i.id;
end $$;

create or replace function public.assign_attention_item(p_item uuid,p_assignee uuid) returns uuid language plpgsql set search_path='' as $$
declare i public.operational_attention_items%rowtype;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into i from public.operational_attention_items x where x.id=p_item for update;
 if not found then raise exception 'item_not_found'; end if;
 if not public.has_active_organization_role(i.organization_id,array['admin','manager']) then raise exception 'not_authorized'; end if;
 if i.status='resolved' then raise exception 'item_already_resolved'; end if;
 if p_assignee is not null and not exists(select 1 from public.organization_memberships m where m.organization_id=i.organization_id and m.user_id=p_assignee and m.status='active') then raise exception 'assignee_not_member'; end if;
 perform set_config('corban.attention_rpc','on',true);
 update public.operational_attention_items set assigned_to=p_assignee where id=i.id;
 insert into public.operational_attention_events(organization_id,item_id,event,actor,detail) values(i.organization_id,i.id,'assigned',auth.uid(),jsonb_build_object('assignee',p_assignee));
 perform set_config('corban.attention_rpc','off',true);
 return i.id;
end $$;
revoke all on function public.guard_attention_write() from public,anon,authenticated;
revoke all on function public.sync_attention_items(uuid,text[],jsonb) from public,anon;
revoke all on function public.decide_attention_item(uuid,text,text,timestamptz) from public,anon;
revoke all on function public.assign_attention_item(uuid,uuid) from public,anon;
grant execute on function public.sync_attention_items(uuid,text[],jsonb) to authenticated;
grant execute on function public.decide_attention_item(uuid,text,text,timestamptz) to authenticated;
grant execute on function public.assign_attention_item(uuid,uuid) to authenticated;
