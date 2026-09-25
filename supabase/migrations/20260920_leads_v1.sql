-- PREPARED, NOT APPLIED (Human Gate: new production DDL). Lead -> Customer -> Proposal.
-- Audit result: no lead entity exists (customers are created directly; only clients.original_source records provenance).
-- Smallest V2-compatible model: a tenant-scoped LEAD register with append-only timeline. It is CRM only:
--   * no financial or commission column, no link to financial tables; it can never create or prove financial truth;
--   * provenance is first class (channel, campaign, external reference) for WhatsApp / Meta / API / import origins;
--   * idempotent intake by (organization, channel, external_ref) so a provider webhook can be replayed safely;
--   * status changes and conversion go through RPCs (guard token), the customer link is write-once;
--   * tenant is derived from the lead (or, for intake, an EXPLICIT organization validated against membership).
create table public.leads (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id),
 status text not null default 'new' check (status in ('new','contacted','qualified','converted','lost')),
 channel text not null check (channel in ('whatsapp','meta_ads','api','import','manual','referral','other')),
 campaign text,
 external_ref text,
 full_name text not null check (length(btrim(full_name)) between 2 and 200),
 phone text,
 email text,
 owner_user_id uuid references auth.users(id),
 customer_id uuid,
 converted_at timestamptz,
 lost_reason text,
 metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata)='object' and octet_length(metadata::text)<=8000),
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 constraint leads_customer_fk foreign key (organization_id,customer_id) references public.clients(organization_id,id),
 constraint leads_converted_consistency check ((status='converted')=(customer_id is not null and converted_at is not null)),
 constraint leads_lost_needs_reason check (status<>'lost' or nullif(btrim(lost_reason),'') is not null)
);
create unique index leads_org_channel_ref_uidx on public.leads(organization_id,channel,external_ref) where external_ref is not null;
create unique index leads_customer_uidx on public.leads(customer_id) where customer_id is not null;
create index leads_org_status_idx on public.leads(organization_id,status,created_at desc);
create index leads_owner_idx on public.leads(owner_user_id) where owner_user_id is not null;
create index leads_created_by_idx on public.leads(created_by) where created_by is not null;

create table public.lead_events (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id),
 lead_id uuid not null references public.leads(id) on delete restrict,
 event_type text not null check (event_type in ('created','status_changed','owner_changed','converted','note','reactivated')),
 from_status text,
 to_status text,
 actor_user_id uuid references auth.users(id),
 detail jsonb not null default '{}'::jsonb check (jsonb_typeof(detail)='object' and octet_length(detail::text)<=4000),
 created_at timestamptz not null default now()
);
create index lead_events_lead_idx on public.lead_events(lead_id,created_at);
create index lead_events_org_idx on public.lead_events(organization_id);
create index lead_events_actor_idx on public.lead_events(actor_user_id) where actor_user_id is not null;

alter table public.leads enable row level security;
alter table public.lead_events enable row level security;
revoke all on table public.leads,public.lead_events from anon,authenticated;
grant select on table public.leads,public.lead_events to authenticated;
create policy leads_select_member on public.leads for select to authenticated using (public.is_active_organization_member(organization_id));
create policy lead_events_select_member on public.lead_events for select to authenticated using (public.is_active_organization_member(organization_id));
-- No INSERT/UPDATE/DELETE policies or grants: every write goes through the governed RPCs below (SECURITY INVOKER + policies
-- are not needed because the RPCs are the only writers and run with the table owner's rights via the private definer helper).

-- Same helper as in 20260920_column_security_and_tenant_derivation_v1 (idempotent create-or-replace; keeps this migration self-contained).
create schema if not exists private;
revoke all on schema private from public,anon;
grant usage on schema private to authenticated;
create or replace function private.caller_role_in(p_org uuid)
returns text language sql stable security definer set search_path='' as $$
 select m.role from public.organization_memberships m where m.organization_id=p_org and m.user_id=(select auth.uid()) and m.status='active' limit 1
$$;
revoke all on function private.caller_role_in(uuid) from public,anon;
grant execute on function private.caller_role_in(uuid) to authenticated;

create or replace function private.lead_write(p_org uuid,p_lead uuid,p_op text,p_args jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_user uuid:=(select auth.uid());v_role text;l public.leads%rowtype;v_id uuid;v_customer uuid;
begin
 v_role:=private.caller_role_in(p_org);
 if v_user is null or v_role is null then raise exception 'lead_forbidden'; end if;
 if p_op='create' then
  insert into public.leads(organization_id,channel,campaign,external_ref,full_name,phone,email,owner_user_id,metadata,created_by)
  values(p_org,p_args->>'channel',nullif(p_args->>'campaign',''),nullif(p_args->>'external_ref',''),p_args->>'full_name',nullif(p_args->>'phone',''),nullif(lower(p_args->>'email'),''),v_user,coalesce(p_args->'metadata','{}'::jsonb),v_user)
  on conflict (organization_id,channel,external_ref) where external_ref is not null do nothing returning id into v_id;
  if v_id is null then select id into v_id from public.leads where organization_id=p_org and channel=p_args->>'channel' and external_ref=nullif(p_args->>'external_ref',''); return v_id; end if;
  insert into public.lead_events(organization_id,lead_id,event_type,to_status,actor_user_id,detail) values(p_org,v_id,'created','new',v_user,jsonb_build_object('channel',p_args->>'channel','campaign',p_args->>'campaign'));
  return v_id;
 end if;
 select * into l from public.leads where id=p_lead and organization_id=p_org for update;
 if not found then raise exception 'lead_forbidden'; end if;
 if p_op='status' then
  if l.status in ('converted') then raise exception 'lead_already_converted'; end if;
  if p_args->>'status' not in ('new','contacted','qualified','lost') then raise exception 'invalid_lead_status'; end if;
  if p_args->>'status'='lost' and nullif(btrim(p_args->>'lost_reason'),'') is null then raise exception 'lost_reason_required'; end if;
  if l.status='lost' and p_args->>'status'<>'lost' and v_role not in ('admin','manager','supervisor') then raise exception 'lead_reactivation_requires_supervisor'; end if;
  update public.leads set status=p_args->>'status',lost_reason=case when p_args->>'status'='lost' then p_args->>'lost_reason' else null end,updated_at=now() where id=l.id;
  insert into public.lead_events(organization_id,lead_id,event_type,from_status,to_status,actor_user_id,detail) values(p_org,l.id,case when l.status='lost' then 'reactivated' else 'status_changed' end,l.status,p_args->>'status',v_user,jsonb_build_object('lost_reason',p_args->>'lost_reason'));
  return l.id;
 end if;
 if p_op='convert' then
  if l.status='converted' then return l.customer_id; end if;
  if l.status='lost' then raise exception 'lost_lead_must_be_reactivated'; end if;
  if p_args->>'cpf' !~ '^[0-9]{11}$' then raise exception 'invalid_cpf_format'; end if;
  insert into public.clients(organization_id,full_name,cpf,phone,email,original_source) values(p_org,l.full_name,p_args->>'cpf',l.phone,l.email,'lead:'||l.channel) returning id into v_customer;
  insert into public.customer_timeline_events(organization_id,customer_id,event_type,source,actor_user_id) values(p_org,v_customer,'customer.created','lead_conversion',v_user);
  update public.leads set status='converted',customer_id=v_customer,converted_at=now(),updated_at=now() where id=l.id;
  insert into public.lead_events(organization_id,lead_id,event_type,from_status,to_status,actor_user_id,detail) values(p_org,l.id,'converted',l.status,'converted',v_user,jsonb_build_object('customer_id',v_customer));
  return v_customer;
 end if;
 raise exception 'invalid_lead_operation';
end $$;
revoke all on function private.lead_write(uuid,uuid,text,jsonb) from public,anon;
grant execute on function private.lead_write(uuid,uuid,text,jsonb) to authenticated;

-- Intake needs an EXPLICIT organization (no resource exists yet): validated against an active membership inside lead_write.
create or replace function public.create_lead(p_organization_id uuid,p_channel text,p_full_name text,p_phone text default null,p_email text default null,p_campaign text default null,p_external_ref text default null,p_metadata jsonb default '{}'::jsonb)
returns uuid language sql security invoker set search_path='' as $$
 select private.lead_write(p_organization_id,null,'create',jsonb_build_object('channel',p_channel,'full_name',p_full_name,'phone',p_phone,'email',p_email,'campaign',p_campaign,'external_ref',p_external_ref,'metadata',coalesce(p_metadata,'{}'::jsonb)))
$$;
-- Existing-lead operations derive the tenant FROM THE LEAD, then validate membership in that tenant.
create or replace function public.set_lead_status(p_lead_id uuid,p_status text,p_lost_reason text default null)
returns uuid language sql security invoker set search_path='' as $$
 select private.lead_write((select l.organization_id from public.leads l where l.id=p_lead_id),p_lead_id,'status',jsonb_build_object('status',p_status,'lost_reason',p_lost_reason))
$$;
create or replace function public.convert_lead_to_customer(p_lead_id uuid,p_cpf text)
returns uuid language sql security invoker set search_path='' as $$
 select private.lead_write((select l.organization_id from public.leads l where l.id=p_lead_id),p_lead_id,'convert',jsonb_build_object('cpf',p_cpf))
$$;
revoke all on function public.create_lead(uuid,text,text,text,text,text,text,jsonb),public.set_lead_status(uuid,text,text),public.convert_lead_to_customer(uuid,text) from public,anon;
grant execute on function public.create_lead(uuid,text,text,text,text,text,text,jsonb),public.set_lead_status(uuid,text,text),public.convert_lead_to_customer(uuid,text) to authenticated;
