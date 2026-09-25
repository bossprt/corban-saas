-- PREPARED, NOT APPLIED. Foundation for the provider-agnostic AI import agent (memory of confirmed column mappings) and AI metering / credits
-- (NEXT-WAVE-PLAN-V3, waves C and D). Additive, SECURITY INVOKER, no secret, no external call, no price: nothing here can spend money by itself.
-- AI is OFF by default for every tenant (organization_ai_limits.enabled=false, no credits). The provider cost is stored apart from the credits charged to the tenant.
-- Ledger and events are append-only. All writes go through governed RPCs (guard tokens); credits/limits can only be granted by service_role (platform).

-- ---------------------------------------------------------------- C. confirmed mapping memory (per origin + layout fingerprint)
create table public.import_layout_mappings(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 source_label text not null check (length(btrim(source_label)) between 1 and 120),
 layout_fingerprint text not null check (layout_fingerprint ~ '^[0-9a-f]{64}$'),
 version integer not null check (version>0),
 mapping jsonb not null check (jsonb_typeof(mapping)='object'),
 unknown_columns jsonb not null default '[]'::jsonb check (jsonb_typeof(unknown_columns)='array'),
 confidence numeric(5,4) check (confidence is null or confidence between 0 and 1),
 provider text check (provider is null or length(provider) between 1 and 40),
 model text check (model is null or length(model) between 1 and 80),
 status text not null default 'confirmed' check (status in ('confirmed','superseded')),
 confirmed_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 unique (organization_id,id)
);
create unique index import_layout_mappings_version_key on public.import_layout_mappings(organization_id,lower(btrim(source_label)),layout_fingerprint,version);
create unique index import_layout_mappings_one_confirmed on public.import_layout_mappings(organization_id,lower(btrim(source_label)),layout_fingerprint) where status='confirmed';

create or replace function public.guard_import_layout_mapping() returns trigger language plpgsql set search_path='' as $$
begin
 if current_user in ('authenticated','anon') and current_setting('corban.mapping_rpc',true) is distinct from 'on' then raise exception 'mapping_write_requires_governed_rpc'; end if;
 if tg_op='UPDATE' then
  -- a confirmed mapping is history: the only allowed change is confirmed -> superseded
  if old.status<>'confirmed' or new.status<>'superseded' or (to_jsonb(new)-'status') is distinct from (to_jsonb(old)-'status') then raise exception 'mapping_is_immutable'; end if;
 end if;
 return new;
end $$;
create trigger import_layout_mappings_00_guard before insert or update on public.import_layout_mappings for each row execute function public.guard_import_layout_mapping();
alter table public.import_layout_mappings enable row level security;
revoke all on public.import_layout_mappings from public,anon,authenticated;
grant select,insert,update on public.import_layout_mappings to authenticated;
create policy import_layout_mappings_select on public.import_layout_mappings for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy import_layout_mappings_insert on public.import_layout_mappings for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy import_layout_mappings_update on public.import_layout_mappings for update to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor'])) with check (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));

-- p_mapping = {"<canonical field>":"<column header in the file>"}. Canonical fields are a closed list: nothing outside it (and no free SQL/JSON structure) is stored.
create or replace function public.confirm_import_mapping(p_organization uuid,p_source_label text,p_fingerprint text,p_mapping jsonb,p_unknown jsonb,p_confidence numeric,p_provider text,p_model text)
returns uuid language plpgsql set search_path='' as $$
declare k text; v_ver integer; v_id uuid; v_allowed text[]:=array['bank','agreement','product_table','contract_type','term','coefficient','rate','received_commission','valid_from','valid_until','production_origin'];
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 if p_organization is null or not public.has_active_organization_role(p_organization,array['admin','manager','supervisor']) then raise exception 'not_authorized'; end if;
 if p_source_label is null or length(btrim(p_source_label)) not between 1 and 120 then raise exception 'invalid_mapping'; end if;
 if p_fingerprint is null or p_fingerprint !~ '^[0-9a-f]{64}$' then raise exception 'invalid_mapping'; end if;
 if p_mapping is null or jsonb_typeof(p_mapping)<>'object' or p_mapping='{}'::jsonb then raise exception 'invalid_mapping'; end if;
 for k in select jsonb_object_keys(p_mapping) loop
  if k<>all(v_allowed) or jsonb_typeof(p_mapping->k)<>'string' or length(p_mapping->>k) not between 1 and 120 then raise exception 'invalid_mapping'; end if;
 end loop;
 if p_unknown is null or jsonb_typeof(p_unknown)<>'array' or jsonb_array_length(p_unknown)>200 then raise exception 'invalid_mapping'; end if;
 if exists(select 1 from jsonb_array_elements(p_unknown) u where jsonb_typeof(u)<>'string' or length(u #>> '{}')>120) then raise exception 'invalid_mapping'; end if;
 if p_confidence is not null and (p_confidence<0 or p_confidence>1) then raise exception 'invalid_mapping'; end if;
 perform set_config('corban.mapping_rpc','on',true);
 select coalesce(max(m.version),0)+1 into v_ver from public.import_layout_mappings m where m.organization_id=p_organization and lower(btrim(m.source_label))=lower(btrim(p_source_label)) and m.layout_fingerprint=p_fingerprint;
 update public.import_layout_mappings m set status='superseded' where m.organization_id=p_organization and lower(btrim(m.source_label))=lower(btrim(p_source_label)) and m.layout_fingerprint=p_fingerprint and m.status='confirmed';
 insert into public.import_layout_mappings(organization_id,source_label,layout_fingerprint,version,mapping,unknown_columns,confidence,provider,model,confirmed_by)
  values(p_organization,btrim(p_source_label),p_fingerprint,v_ver,p_mapping,p_unknown,p_confidence,nullif(p_provider,''),nullif(p_model,''),auth.uid()) returning id into v_id;
 perform set_config('corban.mapping_rpc','off',true);
 return v_id;
end $$;

-- ---------------------------------------------------------------- D. metering: limits, jobs, events, credit ledger (append-only)
create table public.organization_ai_limits(
 organization_id uuid primary key references public.organizations(id) on delete restrict,
 enabled boolean not null default false,
 monthly_credit_limit numeric(18,4) not null default 0 check (monthly_credit_limit>=0),
 updated_by uuid references auth.users(id) on delete set null,
 updated_at timestamptz not null default now()
);
create table public.ai_usage_jobs(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 capability text not null check (capability in ('import_mapping','import_pdf_extraction','operational_summary')),
 provider text not null check (length(provider) between 1 and 40),
 model text not null check (length(model) between 1 and 80),
 status text not null default 'reserved' check (status in ('reserved','succeeded','failed','cancelled')),
 source_ref text check (source_ref is null or length(source_ref) between 1 and 200),
 estimated_credits numeric(18,4) not null check (estimated_credits>0),
 credits_charged numeric(18,4) check (credits_charged is null or credits_charged>=0),
 estimated_provider_cost numeric(18,6) check (estimated_provider_cost is null or estimated_provider_cost>=0),
 actual_provider_cost numeric(18,6) check (actual_provider_cost is null or actual_provider_cost>=0),
 cost_currency char(3) not null default 'USD',
 input_units bigint check (input_units is null or input_units>=0),
 output_units bigint check (output_units is null or output_units>=0),
 idempotency_key text not null check (length(idempotency_key) between 8 and 120),
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 settled_at timestamptz,
 unique (organization_id,id), unique (organization_id,idempotency_key)
);
create index ai_usage_jobs_month_idx on public.ai_usage_jobs(organization_id,created_at);
create table public.ai_credit_ledger(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 kind text not null check (kind in ('grant','reserve','release','charge','adjustment')),
 credits numeric(18,4) not null check (credits<>0),
 job_id uuid,
 idempotency_key text not null check (length(idempotency_key) between 8 and 140),
 note text check (note is null or length(note)<=300),
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 unique (organization_id,idempotency_key),
 foreign key (organization_id,job_id) references public.ai_usage_jobs(organization_id,id) on delete restrict,
 check ((kind in ('grant','release') and credits>0) or (kind in ('reserve','charge') and credits<0) or kind='adjustment')
);
create index ai_credit_ledger_org_idx on public.ai_credit_ledger(organization_id,created_at);
create table public.ai_usage_events(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 job_id uuid not null,
 event text not null check (length(event) between 1 and 60),
 detail jsonb not null default '{}'::jsonb check (jsonb_typeof(detail)='object'),
 created_at timestamptz not null default now(),
 foreign key (organization_id,job_id) references public.ai_usage_jobs(organization_id,id) on delete restrict
);
create index ai_usage_events_job_idx on public.ai_usage_events(organization_id,job_id);

create or replace function public.guard_ai_write() returns trigger language plpgsql set search_path='' as $$
begin
 -- ledger and events are append-only, for everyone
 if tg_table_name in ('ai_credit_ledger','ai_usage_events') and tg_op in ('UPDATE','DELETE') then raise exception 'ai_records_are_append_only'; end if;
 if tg_op='DELETE' then raise exception 'ai_records_are_append_only'; end if;
 if current_user in ('authenticated','anon') and current_setting('corban.ai_rpc',true) is distinct from 'on' then raise exception 'ai_write_requires_governed_rpc'; end if;
 if tg_table_name='ai_usage_jobs' and tg_op='UPDATE' then
  -- a settled job never changes again; only the settlement columns may move, and only once
  if old.status<>'reserved' then raise exception 'job_already_settled'; end if;
  if (to_jsonb(new)-'status'-'credits_charged'-'actual_provider_cost'-'input_units'-'output_units'-'settled_at') is distinct from (to_jsonb(old)-'status'-'credits_charged'-'actual_provider_cost'-'input_units'-'output_units'-'settled_at') then raise exception 'job_identity_is_immutable'; end if;
 end if;
 return new;
end $$;
create trigger organization_ai_limits_00_guard before insert or update or delete on public.organization_ai_limits for each row execute function public.guard_ai_write();
create trigger ai_usage_jobs_00_guard before insert or update or delete on public.ai_usage_jobs for each row execute function public.guard_ai_write();
create trigger ai_credit_ledger_00_guard before insert or update or delete on public.ai_credit_ledger for each row execute function public.guard_ai_write();
create trigger ai_usage_events_00_guard before insert or update or delete on public.ai_usage_events for each row execute function public.guard_ai_write();
alter table public.organization_ai_limits enable row level security;
alter table public.ai_usage_jobs enable row level security;
alter table public.ai_credit_ledger enable row level security;
alter table public.ai_usage_events enable row level security;
revoke all on public.organization_ai_limits,public.ai_usage_jobs,public.ai_credit_ledger,public.ai_usage_events from public,anon,authenticated;
grant select on public.organization_ai_limits,public.ai_usage_jobs,public.ai_credit_ledger,public.ai_usage_events to authenticated;
grant insert,update on public.ai_usage_jobs to authenticated;
grant insert on public.ai_credit_ledger,public.ai_usage_events to authenticated;
-- users read credits and usage (supervisor+), never tokens as a unit; agents see nothing
create policy organization_ai_limits_select on public.organization_ai_limits for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy ai_usage_jobs_select on public.ai_usage_jobs for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy ai_credit_ledger_select on public.ai_credit_ledger for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy ai_usage_events_select on public.ai_usage_events for select to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy ai_usage_jobs_insert on public.ai_usage_jobs for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy ai_usage_jobs_update on public.ai_usage_jobs for update to authenticated using (public.has_active_organization_role(organization_id,array['admin','manager','supervisor'])) with check (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy ai_credit_ledger_insert on public.ai_credit_ledger for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy ai_usage_events_insert on public.ai_usage_events for insert to authenticated with check (public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));

create or replace function public.ai_credit_balance(p_organization uuid) returns numeric language plpgsql stable set search_path='' as $$
begin
 if auth.uid() is null or p_organization is null or not public.has_active_organization_role(p_organization,array['admin','manager','supervisor']) then raise exception 'not_authorized'; end if;
 return coalesce((select sum(l.credits) from public.ai_credit_ledger l where l.organization_id=p_organization),0);
end $$;

-- Reserve BEFORE any paid call. Refused (nothing written) when AI is off, the balance is short or the monthly ceiling would be exceeded.
-- Idempotent by key: the same key returns the same job and never reserves twice.
create or replace function public.reserve_ai_job(p_organization uuid,p_capability text,p_provider text,p_model text,p_estimated_credits numeric,p_estimated_cost numeric,p_source_ref text,p_idempotency_key text)
returns uuid language plpgsql set search_path='' as $$
declare l public.organization_ai_limits%rowtype; j public.ai_usage_jobs%rowtype; v_bal numeric; v_month numeric; v_id uuid; v_has_limits boolean;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 if p_organization is null or not public.has_active_organization_role(p_organization,array['admin','manager','supervisor']) then raise exception 'not_authorized'; end if;
 if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 120 then raise exception 'invalid_ai_job'; end if;
 if p_capability is null or p_capability not in ('import_mapping','import_pdf_extraction','operational_summary') then raise exception 'invalid_ai_job'; end if;
 if p_provider is null or length(p_provider) not between 1 and 40 or p_model is null or length(p_model) not between 1 and 80 then raise exception 'invalid_ai_job'; end if;
 if p_estimated_credits is null or p_estimated_credits<=0 or p_estimated_credits>1000000 then raise exception 'invalid_ai_job'; end if;
 if p_estimated_cost is not null and p_estimated_cost<0 then raise exception 'invalid_ai_job'; end if;
 -- serialise reservations per tenant (balance and ceiling checks must not race); an advisory lock needs no table privilege
 perform pg_advisory_xact_lock(hashtextextended(p_organization::text,0));
 select * into l from public.organization_ai_limits x where x.organization_id=p_organization;
 v_has_limits:=found;
 select * into j from public.ai_usage_jobs x where x.organization_id=p_organization and x.idempotency_key=p_idempotency_key;
 if found then
  if j.capability<>p_capability or j.estimated_credits<>p_estimated_credits then raise exception 'idempotency_conflict'; end if;
  return j.id;
 end if;
 if not v_has_limits or not l.enabled then raise exception 'ai_disabled'; end if;
 v_bal:=coalesce((select sum(x.credits) from public.ai_credit_ledger x where x.organization_id=p_organization),0);
 if v_bal<p_estimated_credits then raise exception 'insufficient_credits'; end if;
 v_month:=coalesce((select sum(coalesce(x.credits_charged,x.estimated_credits)) from public.ai_usage_jobs x where x.organization_id=p_organization and x.status in ('reserved','succeeded') and x.created_at>=date_trunc('month',now())),0);
 if v_month+p_estimated_credits>l.monthly_credit_limit then raise exception 'monthly_limit_exceeded'; end if;
 perform set_config('corban.ai_rpc','on',true);
 insert into public.ai_usage_jobs(organization_id,capability,provider,model,source_ref,estimated_credits,estimated_provider_cost,idempotency_key,created_by)
  values(p_organization,p_capability,p_provider,p_model,p_source_ref,p_estimated_credits,p_estimated_cost,p_idempotency_key,auth.uid()) returning id into v_id;
 insert into public.ai_credit_ledger(organization_id,kind,credits,job_id,idempotency_key,created_by) values(p_organization,'reserve',-p_estimated_credits,v_id,'reserve:'||v_id,auth.uid());
 insert into public.ai_usage_events(organization_id,job_id,event,detail) values(p_organization,v_id,'reserved',jsonb_build_object('capability',p_capability));
 perform set_config('corban.ai_rpc','off',true);
 return v_id;
end $$;

-- Settle once. The reservation is released and the credits actually used are charged (never more than reserved). Repeating the same outcome is a no-op.
create or replace function public.settle_ai_job(p_job uuid,p_outcome text,p_credits_charged numeric,p_actual_cost numeric,p_input_units bigint,p_output_units bigint)
returns uuid language plpgsql set search_path='' as $$
declare j public.ai_usage_jobs%rowtype; v_charge numeric;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into j from public.ai_usage_jobs x where x.id=p_job for update;
 if not found then raise exception 'job_not_found'; end if;
 if not public.has_active_organization_role(j.organization_id,array['admin','manager','supervisor']) then raise exception 'not_authorized'; end if;
 if p_outcome is null or p_outcome not in ('succeeded','failed','cancelled') then raise exception 'invalid_ai_job'; end if;
 if j.status<>'reserved' then
  if j.status=p_outcome then return j.id; end if;
  raise exception 'job_already_settled';
 end if;
 v_charge:=case when p_outcome='succeeded' then coalesce(p_credits_charged,j.estimated_credits) else 0 end;
 if v_charge<0 or v_charge>j.estimated_credits then raise exception 'charge_exceeds_reservation'; end if;
 if p_actual_cost is not null and p_actual_cost<0 then raise exception 'invalid_ai_job'; end if;
 perform set_config('corban.ai_rpc','on',true);
 update public.ai_usage_jobs set status=p_outcome,credits_charged=v_charge,actual_provider_cost=p_actual_cost,input_units=p_input_units,output_units=p_output_units,settled_at=now() where id=j.id;
 insert into public.ai_credit_ledger(organization_id,kind,credits,job_id,idempotency_key,created_by) values(j.organization_id,'release',j.estimated_credits,j.id,'release:'||j.id,auth.uid());
 if v_charge>0 then insert into public.ai_credit_ledger(organization_id,kind,credits,job_id,idempotency_key,created_by) values(j.organization_id,'charge',-v_charge,j.id,'charge:'||j.id,auth.uid()); end if;
 insert into public.ai_usage_events(organization_id,job_id,event,detail) values(j.organization_id,j.id,p_outcome,jsonb_build_object('credits_charged',v_charge));
 perform set_config('corban.ai_rpc','off',true);
 return j.id;
end $$;

-- PLATFORM ONLY (service_role): grant credits and switch AI on for a tenant. A tenant can never give itself credits or raise its own ceiling.
create or replace function public.platform_grant_ai_credits(p_organization uuid,p_credits numeric,p_idempotency_key text,p_note text)
returns uuid language plpgsql set search_path='' as $$
declare v_id uuid;
begin
 if p_organization is null or p_credits is null or p_credits<=0 or p_credits>100000000 or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 140 then raise exception 'invalid_grant'; end if;
 if not exists(select 1 from public.organizations o where o.id=p_organization) then raise exception 'invalid_grant'; end if;
 insert into public.ai_credit_ledger(organization_id,kind,credits,idempotency_key,note) values(p_organization,'grant',p_credits,p_idempotency_key,left(p_note,300))
  on conflict (organization_id,idempotency_key) do nothing returning id into v_id;
 if v_id is null then select l.id into v_id from public.ai_credit_ledger l where l.organization_id=p_organization and l.idempotency_key=p_idempotency_key; end if;
 return v_id;
end $$;
create or replace function public.platform_set_ai_limits(p_organization uuid,p_enabled boolean,p_monthly_limit numeric) returns void language plpgsql set search_path='' as $$
begin
 if p_organization is null or p_enabled is null or p_monthly_limit is null or p_monthly_limit<0 or p_monthly_limit>100000000 then raise exception 'invalid_limit'; end if;
 if not exists(select 1 from public.organizations o where o.id=p_organization) then raise exception 'invalid_limit'; end if;
 insert into public.organization_ai_limits(organization_id,enabled,monthly_credit_limit) values(p_organization,p_enabled,p_monthly_limit)
  on conflict (organization_id) do update set enabled=excluded.enabled,monthly_credit_limit=excluded.monthly_credit_limit,updated_at=now();
end $$;

revoke all on function public.guard_import_layout_mapping() from public,anon,authenticated;
revoke all on function public.guard_ai_write() from public,anon,authenticated;
revoke all on function public.confirm_import_mapping(uuid,text,text,jsonb,jsonb,numeric,text,text) from public,anon;
revoke all on function public.ai_credit_balance(uuid) from public,anon;
revoke all on function public.reserve_ai_job(uuid,text,text,text,numeric,numeric,text,text) from public,anon;
revoke all on function public.settle_ai_job(uuid,text,numeric,numeric,bigint,bigint) from public,anon;
revoke all on function public.platform_grant_ai_credits(uuid,numeric,text,text) from public,anon,authenticated;
revoke all on function public.platform_set_ai_limits(uuid,boolean,numeric) from public,anon,authenticated;
grant execute on function public.confirm_import_mapping(uuid,text,text,jsonb,jsonb,numeric,text,text) to authenticated;
grant execute on function public.ai_credit_balance(uuid) to authenticated;
grant execute on function public.reserve_ai_job(uuid,text,text,text,numeric,numeric,text,text) to authenticated;
grant execute on function public.settle_ai_job(uuid,text,numeric,numeric,bigint,bigint) to authenticated;
grant execute on function public.platform_grant_ai_credits(uuid,numeric,text,text) to service_role;
grant execute on function public.platform_set_ai_limits(uuid,boolean,numeric) to service_role;
