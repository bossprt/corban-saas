-- PREPARED, NOT APPLIED (Human Gate: new production DDL).
-- Persistent, tenant-scoped register of import conflicts. Findings are ADVISORY: they route rows to human review and can
-- never publish financial truth (auto_publish_allowed is fixed to false by CHECK). Source evidence is preserved: every
-- conflict links to the immutable raw rows involved and is never rewritten; only the resolution columns can change.
--
-- Kinds: duplicate_row, duplicate_file, multi_source_same_proposal, contradictory_status, ambiguous_identity,
--        correction_replay, cross_tenant_attempt, unknown_schema, unresolved_matching, missing_identity.
-- Writers: record_import_conflicts (detector output for ONE batch; tenant derived from the batch) and
--          resolve_import_conflict (human resolution with a note). Both are SECURITY INVOKER; direct writes are blocked
--          by a guard trigger token.
create table public.import_conflicts (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id),
 batch_id uuid not null references public.import_batches(id),
 kind text not null check (kind in ('duplicate_row','duplicate_file','multi_source_same_proposal','contradictory_status','ambiguous_identity','correction_replay','cross_tenant_attempt','unknown_schema','unresolved_matching','missing_identity')),
 severity text not null check (severity in ('info','review','block')),
 identity_key text,
 detail jsonb not null default '{}'::jsonb check (jsonb_typeof(detail)='object' and octet_length(detail::text)<=8000),
 fingerprint text not null,
 auto_publish_allowed boolean not null default false check (auto_publish_allowed=false),
 status text not null default 'open' check (status in ('open','resolved','dismissed')),
 resolution_note text,
 resolved_by uuid references auth.users(id),
 resolved_at timestamptz,
 created_at timestamptz not null default now(),
 unique(organization_id,fingerprint)
);
create table public.import_conflict_rows (
 conflict_id uuid not null references public.import_conflicts(id) on delete restrict,
 organization_id uuid not null references public.organizations(id),
 raw_row_id uuid not null references public.import_raw_rows(id),
 primary key(conflict_id,raw_row_id)
);
create index import_conflicts_org_status_idx on public.import_conflicts(organization_id,status,created_at desc);
create index import_conflicts_batch_idx on public.import_conflicts(batch_id);
create index import_conflicts_resolved_by_idx on public.import_conflicts(resolved_by) where resolved_by is not null;
create index import_conflict_rows_org_idx on public.import_conflict_rows(organization_id);
create index import_conflict_rows_raw_idx on public.import_conflict_rows(raw_row_id);

alter table public.import_conflicts enable row level security;
alter table public.import_conflict_rows enable row level security;
revoke all on table public.import_conflicts,public.import_conflict_rows from anon,authenticated;
grant select,insert,update on table public.import_conflicts to authenticated;
grant select,insert on table public.import_conflict_rows to authenticated;
create policy import_conflicts_select_supervisor_plus on public.import_conflicts for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy import_conflicts_insert_supervisor_plus on public.import_conflicts for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy import_conflicts_update_supervisor_plus on public.import_conflicts for update to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor'])) with check (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy import_conflict_rows_select_supervisor_plus on public.import_conflict_rows for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy import_conflict_rows_insert_supervisor_plus on public.import_conflict_rows for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));

-- Same-tenant, same-batch + immutability guard (independent of the RPCs).
create or replace function public.guard_import_conflict_write()
returns trigger language plpgsql set search_path='' as $$
declare b_org uuid;
begin
 if tg_op='INSERT' then
  if current_setting('corban.import_conflict_rpc',true) is distinct from 'on' then raise exception 'import_conflict_requires_governed_rpc'; end if;
  select organization_id into b_org from public.import_batches where id=new.batch_id;
  if b_org is null or b_org<>new.organization_id then raise exception 'import_conflict_tenant_mismatch'; end if;
  return new;
 end if;
 -- UPDATE: only the resolution columns may change, only open -> resolved/dismissed, and only with a note.
 if new.organization_id is distinct from old.organization_id or new.batch_id is distinct from old.batch_id or new.kind is distinct from old.kind
    or new.severity is distinct from old.severity or new.identity_key is distinct from old.identity_key or new.detail is distinct from old.detail
    or new.fingerprint is distinct from old.fingerprint or new.created_at is distinct from old.created_at or new.auto_publish_allowed is distinct from old.auto_publish_allowed then
  raise exception 'import_conflict_evidence_is_immutable';
 end if;
 if new.status is distinct from old.status then
  if old.status<>'open' then raise exception 'import_conflict_already_closed'; end if;
  if nullif(btrim(new.resolution_note),'') is null then raise exception 'resolution_note_required'; end if;
  new.resolved_by:=(select auth.uid()); new.resolved_at:=now();
 elsif new.resolution_note is distinct from old.resolution_note or new.resolved_by is distinct from old.resolved_by or new.resolved_at is distinct from old.resolved_at then
  raise exception 'import_conflict_evidence_is_immutable';
 end if;
 return new;
end $$;
revoke all on function public.guard_import_conflict_write() from public,anon,authenticated;
create trigger trg_import_conflict_write before insert or update on public.import_conflicts for each row execute function public.guard_import_conflict_write();

create or replace function public.guard_import_conflict_row_write()
returns trigger language plpgsql set search_path='' as $$
declare c_org uuid; r_org uuid; c_batch uuid; r_batch uuid;
begin
 if current_setting('corban.import_conflict_rpc',true) is distinct from 'on' then raise exception 'import_conflict_requires_governed_rpc'; end if;
 select organization_id,batch_id into c_org,c_batch from public.import_conflicts where id=new.conflict_id;
 select organization_id,batch_id into r_org,r_batch from public.import_raw_rows where id=new.raw_row_id;
 if c_org is null or c_org<>new.organization_id or r_org is distinct from c_org or r_batch is distinct from c_batch then raise exception 'import_conflict_tenant_or_batch_mismatch'; end if;
 return new;
end $$;
revoke all on function public.guard_import_conflict_row_write() from public,anon,authenticated;
create trigger trg_import_conflict_row_write before insert on public.import_conflict_rows for each row execute function public.guard_import_conflict_row_write();

-- Detector output for ONE batch. Tenant derived from the batch (never from the caller); idempotent by fingerprint.
-- p_findings: [{kind,severity,identityKey,detail,rawRowIds:[uuid...]}]. Rows referenced must belong to that batch.
create or replace function public.record_import_conflicts(p_batch_id uuid,p_findings jsonb)
returns integer language plpgsql set search_path='' as $$
declare b record;f jsonb;v_fp text;v_id uuid;v_new integer:=0;v_row uuid;v_rows uuid[];
begin
 if jsonb_typeof(p_findings)<>'array' then raise exception 'findings_must_be_array'; end if;
 if jsonb_array_length(p_findings)>500 then raise exception 'too_many_findings'; end if;
 select id,organization_id into b from public.import_batches where id=p_batch_id;
 if not found or not public.has_active_organization_role(b.organization_id,array['admin','manager','supervisor']) then raise exception 'batch_not_found_or_forbidden'; end if;
 perform set_config('corban.import_conflict_rpc','on',true);
 for f in select value from jsonb_array_elements(p_findings) loop
  select coalesce(array_agg(distinct x::uuid order by x::uuid),'{}') into v_rows from jsonb_array_elements_text(coalesce(f->'rawRowIds','[]'::jsonb)) x;
  -- a conflict without preserved raw evidence is not a conflict record
  if cardinality(v_rows)=0 then raise exception 'conflict_evidence_required'; end if;
  if exists(select 1 from unnest(v_rows) rid where not exists(select 1 from public.import_raw_rows r where r.id=rid and r.batch_id=p_batch_id and r.organization_id=b.organization_id)) then
   perform set_config('corban.import_conflict_rpc','off',true);
   raise exception 'conflict_row_not_in_batch';
  end if;
  v_fp:=encode(extensions.digest(concat_ws('|',p_batch_id::text,f->>'kind',coalesce(f->>'identityKey',''),array_to_string(v_rows,',')),'sha256'),'hex');
  insert into public.import_conflicts(organization_id,batch_id,kind,severity,identity_key,detail,fingerprint)
  values(b.organization_id,p_batch_id,f->>'kind',f->>'severity',nullif(f->>'identityKey',''),coalesce(f->'detail','{}'::jsonb),v_fp)
  on conflict(organization_id,fingerprint) do nothing returning id into v_id;
  if v_id is not null then
   v_new:=v_new+1;
   foreach v_row in array v_rows loop insert into public.import_conflict_rows(conflict_id,organization_id,raw_row_id) values(v_id,b.organization_id,v_row); end loop;
  end if;
  v_id:=null;
 end loop;
 perform set_config('corban.import_conflict_rpc','off',true);
 return v_new;
end $$;
revoke all on function public.record_import_conflicts(uuid,jsonb) from public,anon;
grant execute on function public.record_import_conflicts(uuid,jsonb) to authenticated;

create or replace function public.resolve_import_conflict(p_conflict_id uuid,p_status text,p_note text)
returns void language plpgsql set search_path='' as $$
declare v_org uuid;
begin
 if p_status not in ('resolved','dismissed') then raise exception 'invalid_status'; end if;
 if p_note is null or length(btrim(p_note)) not between 10 and 2000 then raise exception 'resolution_note_length_invalid'; end if;
 select organization_id into v_org from public.import_conflicts where id=p_conflict_id;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'conflict_not_found_or_forbidden'; end if;
 update public.import_conflicts set status=p_status,resolution_note=p_note where id=p_conflict_id and organization_id=v_org;
end $$;
revoke all on function public.resolve_import_conflict(uuid,text,text) from public,anon;
grant execute on function public.resolve_import_conflict(uuid,text,text) to authenticated;
