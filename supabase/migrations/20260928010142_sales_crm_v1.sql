-- Sales CRM v1 (V2 phase, owner decision 27/09/2026): the company's own team sells from campaigns built from spreadsheets.
--   * sales_campaigns: a campaign with its period, the people who work it and how its leads are distributed
--     (queue: sellers take the next one; manual: a supervisor distributes; round_robin: the system alternates);
--   * import of a campaign spreadsheet: whoever is already a client is linked by CPF (or phone) and never duplicated;
--     new people stay as leads (with the CPF, when given) until a seller starts a simulation;
--   * lead stages new > contacted > negotiating > proposal > won | lost. "proposal" and "won" are never set by hand:
--     they follow the client's proposal (created / paid); a rejected or cancelled proposal brings the lead back;
--   * next contact date and notes on the lead timeline; the "take next lead" queue replaces browsing the queue, so a seller
--     never sees personal data of leads that are not theirs.
-- CRM only: no money column, nothing here creates or changes financial truth. Tenant is always derived from the record.

-- 1. Campaigns --------------------------------------------------------------------------------------------------------
create table public.sales_campaigns (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  name text not null check (length(btrim(name)) between 2 and 120),
  description text check (description is null or length(description) <= 500),
  distribution text not null default 'queue' check (distribution in ('queue', 'manual', 'round_robin')),
  starts_on date,
  ends_on date,
  status text not null default 'active' check (status in ('active', 'closed')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sales_campaigns_org_id_key unique (organization_id, id),
  constraint sales_campaigns_period check (starts_on is null or ends_on is null or ends_on >= starts_on)
);
create unique index sales_campaigns_org_name_uidx on public.sales_campaigns (organization_id, lower(btrim(name)));
create index sales_campaigns_created_by_idx on public.sales_campaigns (created_by) where created_by is not null;

create table public.sales_campaign_members (
  organization_id uuid not null,
  campaign_id uuid not null,
  user_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (campaign_id, user_id),
  constraint sales_campaign_members_campaign_fk foreign key (organization_id, campaign_id) references public.sales_campaigns (organization_id, id)
);
create index sales_campaign_members_user_idx on public.sales_campaign_members (user_id);
create index sales_campaign_members_org_campaign_idx on public.sales_campaign_members (organization_id, campaign_id);

create table public.sales_campaign_imports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  campaign_id uuid not null,
  file_name text not null check (length(file_name) between 1 and 255),
  file_sha256 text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  row_count int not null check (row_count >= 0),
  created_count int not null default 0,
  linked_client_count int not null default 0,
  duplicate_count int not null default 0,
  invalid_count int not null default 0,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint sales_campaign_imports_campaign_fk foreign key (organization_id, campaign_id) references public.sales_campaigns (organization_id, id)
);
create index sales_campaign_imports_campaign_idx on public.sales_campaign_imports (organization_id, campaign_id, created_at desc);
create index sales_campaign_imports_created_by_idx on public.sales_campaign_imports (created_by) where created_by is not null;

alter table public.sales_campaigns enable row level security;
alter table public.sales_campaign_members enable row level security;
alter table public.sales_campaign_imports enable row level security;
revoke all on table public.sales_campaigns, public.sales_campaign_members, public.sales_campaign_imports from anon, authenticated;
grant select on table public.sales_campaigns, public.sales_campaign_members, public.sales_campaign_imports to authenticated;
create policy sales_campaigns_select on public.sales_campaigns for select to authenticated
  using (public.has_permission(organization_id, 'leads.view'));
create policy sales_campaign_members_select on public.sales_campaign_members for select to authenticated
  using (public.has_permission(organization_id, 'leads.view'));
create policy sales_campaign_imports_select on public.sales_campaign_imports for select to authenticated
  using (public.has_permission(organization_id, 'leads.approve'));

-- 2. Leads: stages, campaign, CPF, next contact, proposal link ----------------------------------------------------------
alter table public.leads drop constraint leads_converted_consistency;
alter table public.leads drop constraint leads_status_check;
alter table public.leads
  add column campaign_id uuid,
  add column cpf text,
  add column next_contact_at timestamptz,
  add column proposal_id uuid references public.proposals_v2(id),
  add column stage_changed_at timestamptz not null default now(),
  add column won_at timestamptz;

-- Old stages to the new ones. A converted lead became a client: it is negotiating, or further if the client has a proposal.
update public.leads l set status = 'negotiating' where l.status = 'qualified';
update public.leads l
set status = case
      when exists (select 1 from public.proposals_v2 p where p.organization_id = l.organization_id and p.customer_id = l.customer_id and p.status = 'paid') then 'won'
      when exists (select 1 from public.proposals_v2 p where p.organization_id = l.organization_id and p.customer_id = l.customer_id
                   and p.status not in ('rejected', 'cancelled')) then 'proposal'
      else 'negotiating' end
where l.status = 'converted';
update public.leads l set cpf = l.metadata->>'cpf' where l.cpf is null and l.metadata->>'cpf' ~ '^[0-9]{11}$';

alter table public.leads
  add constraint leads_status_check check (status in ('new', 'contacted', 'negotiating', 'proposal', 'won', 'lost')),
  add constraint leads_cpf_format check (cpf is null or cpf ~ '^[0-9]{11}$'),
  add constraint leads_campaign_fk foreign key (organization_id, campaign_id) references public.sales_campaigns (organization_id, id),
  add constraint leads_client_link_consistency check ((customer_id is null) = (converted_at is null));
create unique index leads_campaign_cpf_uidx on public.leads (campaign_id, cpf) where campaign_id is not null and cpf is not null;
create unique index leads_campaign_customer_uidx on public.leads (campaign_id, customer_id) where campaign_id is not null and customer_id is not null;
create index leads_campaign_phone_idx on public.leads (campaign_id, phone) where campaign_id is not null and phone is not null;
create index leads_org_campaign_status_idx on public.leads (organization_id, campaign_id, status);
create index leads_owner_next_contact_idx on public.leads (owner_user_id, next_contact_at) where next_contact_at is not null;
create index leads_proposal_idx on public.leads (proposal_id) where proposal_id is not null;
create index leads_queue_idx on public.leads (organization_id, created_at) where owner_user_id is null;

alter table public.lead_events drop constraint lead_events_event_type_check;
alter table public.lead_events add constraint lead_events_event_type_check check (event_type in
  ('created', 'imported', 'status_changed', 'owner_changed', 'converted', 'client_linked', 'note', 'next_contact',
   'proposal_linked', 'won', 'reactivated'));

-- Visibility: only the leads the caller's data scope reaches. The open queue is no longer browsable: a seller takes
-- the next lead with take_next_lead and sees only how many are waiting (lead_queue_count).
drop policy leads_scope on public.leads;
create policy leads_scope on public.leads as restrictive to authenticated
  using (private.can_see_owner(organization_id, coalesce(owner_user_id, created_by)))
  with check (private.can_see_owner(organization_id, coalesce(owner_user_id, created_by)));

-- 3. Helpers -----------------------------------------------------------------------------------------------------------
-- The caller may work a lead: active member with leads.edit who reaches the lead's owner.
create or replace function private.lead_workable(p_org uuid, p_owner uuid, p_created_by uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and public.has_permission(p_org, 'leads.edit')
     and private.can_see_owner(p_org, coalesce(p_owner, p_created_by))
$$;
revoke all on function private.lead_workable(uuid, uuid, uuid) from public, anon;
grant execute on function private.lead_workable(uuid, uuid, uuid) to authenticated;

-- Unassigned open leads the caller may take: campaigns in queue mode the caller works (a campaign without members is
-- open to every seller), and leads without a campaign when the company's API distribution is the queue.
create or replace function private.caller_queue_leads(p_org uuid, p_campaign uuid)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select l.id from public.leads l
  left join public.sales_campaigns c on c.organization_id = l.organization_id and c.id = l.campaign_id
  where l.organization_id = p_org and l.owner_user_id is null and l.status in ('new', 'contacted', 'negotiating')
    and (p_campaign is null or l.campaign_id = p_campaign)
    and public.has_permission(p_org, 'leads.edit')
    and case when l.campaign_id is null then
          exists (select 1 from public.organization_lead_settings s where s.organization_id = p_org and s.distribution = 'queue')
        else c.status = 'active' and c.distribution = 'queue'
          and (not exists (select 1 from public.sales_campaign_members m where m.campaign_id = c.id)
               or exists (select 1 from public.sales_campaign_members m where m.campaign_id = c.id and m.user_id = (select auth.uid())))
        end
$$;
revoke all on function private.caller_queue_leads(uuid, uuid) from public, anon;
grant execute on function private.caller_queue_leads(uuid, uuid) to authenticated;

-- A user that can own leads in the company: active member whose role has leads.edit.
create or replace function private.can_own_leads(p_org uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.organization_memberships m
    join public.organization_roles r on r.organization_id = m.organization_id and r.id = m.role_id
    where m.organization_id = p_org and m.user_id = p_user and m.status = 'active' and r.is_active
      and (r.tier = 'admin' or 'leads.edit' = any (r.permissions)))
$$;
revoke all on function private.can_own_leads(uuid, uuid) from public, anon;
grant execute on function private.can_own_leads(uuid, uuid) to authenticated;

-- 4. Lead writes (replaces the v1 dispatcher) ----------------------------------------------------------------------------
create or replace function private.lead_write(p_org uuid, p_lead uuid, p_op text, p_args jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := (select auth.uid());
  v_role text;
  l public.leads%rowtype;
  v_id uuid;
  v_customer uuid;
  v_cpf text;
  v_phone text;
  v_campaign public.sales_campaigns%rowtype;
  v_status text := p_args->>'status';
begin
  v_role := private.caller_role_in(p_org);
  if v_user is null or v_role is null then raise exception 'lead_forbidden'; end if;

  if p_op = 'create' then
    if not public.has_permission(p_org, 'leads.create') then raise exception 'lead_forbidden'; end if;
    v_cpf := nullif(regexp_replace(coalesce(p_args->>'cpf', ''), '\D', '', 'g'), '');
    if v_cpf is not null and not private.is_valid_cpf(v_cpf) then raise exception 'invalid_cpf'; end if;
    v_phone := private.normalize_phone(p_args->>'phone');
    if nullif(p_args->>'campaign_id', '') is not null then
      select * into v_campaign from public.sales_campaigns where organization_id = p_org and id = (p_args->>'campaign_id')::uuid;
      if not found or v_campaign.status <> 'active' then raise exception 'campaign_not_active'; end if;
      if exists (select 1 from public.leads x where x.campaign_id = v_campaign.id
                 and ((v_cpf is not null and x.cpf = v_cpf) or (v_phone is not null and x.phone = v_phone))) then
        raise exception 'lead_already_in_campaign';
      end if;
    end if;
    if v_cpf is not null then
      select c.id into v_customer from public.clients c where c.organization_id = p_org and c.cpf = v_cpf and c.deleted_at is null;
    end if;
    insert into public.leads (organization_id, channel, campaign_id, campaign, external_ref, full_name, phone, email, cpf,
                              customer_id, converted_at, owner_user_id, assigned_at, metadata, created_by)
    values (p_org, p_args->>'channel', v_campaign.id, coalesce(v_campaign.name, nullif(p_args->>'campaign', '')), nullif(p_args->>'external_ref', ''),
            btrim(p_args->>'full_name'), coalesce(v_phone, nullif(p_args->>'phone', '')), nullif(lower(p_args->>'email'), ''), v_cpf,
            v_customer, case when v_customer is not null then now() end, v_user, now(), coalesce(p_args->'metadata', '{}'::jsonb), v_user)
    on conflict (organization_id, channel, external_ref) where external_ref is not null do nothing
    returning id into v_id;
    if v_id is null then
      select id into v_id from public.leads where organization_id = p_org and channel = p_args->>'channel' and external_ref = nullif(p_args->>'external_ref', '');
      return v_id;
    end if;
    insert into public.lead_events (organization_id, lead_id, event_type, to_status, actor_user_id, detail)
    values (p_org, v_id, 'created', 'new', v_user, jsonb_build_object('channel', p_args->>'channel', 'campaign_id', v_campaign.id, 'client_linked', v_customer is not null));
    return v_id;
  end if;

  select * into l from public.leads where id = p_lead and organization_id = p_org for update;
  if not found or not private.lead_workable(p_org, l.owner_user_id, l.created_by) then raise exception 'lead_forbidden'; end if;

  if p_op = 'status' then
    if l.status = 'won' then raise exception 'lead_already_won'; end if;
    -- "proposal" and "won" follow the client's proposal; they are never set by hand.
    if v_status is null or v_status not in ('new', 'contacted', 'negotiating', 'lost') then raise exception 'invalid_lead_status'; end if;
    if v_status = 'lost' and nullif(btrim(p_args->>'lost_reason'), '') is null then raise exception 'lost_reason_required'; end if;
    if length(coalesce(p_args->>'lost_reason', '')) > 300 then raise exception 'lost_reason_too_long'; end if;
    if l.status = 'lost' and v_status <> 'lost' and v_role not in ('admin', 'manager', 'supervisor') then raise exception 'lead_reactivation_requires_supervisor'; end if;
    if l.status = 'proposal' and v_status <> 'lost' then raise exception 'lead_has_open_proposal'; end if;
    if v_status = l.status then return l.id; end if;
    update public.leads
    set status = v_status, lost_reason = case when v_status = 'lost' then btrim(p_args->>'lost_reason') end,
        next_contact_at = case when v_status = 'lost' then null else next_contact_at end,
        stage_changed_at = now(), updated_at = now()
    where id = l.id;
    insert into public.lead_events (organization_id, lead_id, event_type, from_status, to_status, actor_user_id, detail)
    values (p_org, l.id, case when l.status = 'lost' then 'reactivated' else 'status_changed' end, l.status, v_status, v_user,
            jsonb_build_object('lost_reason', p_args->>'lost_reason'));
    return l.id;
  end if;

  if p_op = 'convert' then
    -- Start a sale: the lead becomes (or is recognized as) a client by CPF; the lead moves to negotiating.
    if l.status in ('lost', 'won') then raise exception 'lead_closed'; end if;
    v_customer := l.customer_id;
    if v_customer is null then
      v_cpf := coalesce(nullif(regexp_replace(coalesce(p_args->>'cpf', ''), '\D', '', 'g'), ''), l.cpf);
      if v_cpf is null or not private.is_valid_cpf(v_cpf) then raise exception 'invalid_cpf'; end if;
      if not public.has_permission(p_org, 'clientes.create') then raise exception 'lead_forbidden'; end if;
      select u.client_id into v_customer
      from private.upsert_client_core(p_org, v_cpf, l.full_name, l.phone, l.email, 'lead:' || l.channel, coalesce(l.owner_user_id, v_user)) u;
      update public.leads set customer_id = v_customer, converted_at = now(), cpf = v_cpf, updated_at = now() where id = l.id;
      insert into public.lead_events (organization_id, lead_id, event_type, actor_user_id, detail)
      values (p_org, l.id, 'client_linked', v_user, jsonb_build_object('customer_id', v_customer));
    end if;
    if l.status in ('new', 'contacted') then
      update public.leads set status = 'negotiating', stage_changed_at = now(), updated_at = now() where id = l.id;
      insert into public.lead_events (organization_id, lead_id, event_type, from_status, to_status, actor_user_id)
      values (p_org, l.id, 'status_changed', l.status, 'negotiating', v_user);
    end if;
    return v_customer;
  end if;

  if p_op = 'note' then
    if nullif(btrim(p_args->>'text'), '') is null or length(p_args->>'text') > 1000 then raise exception 'invalid_note'; end if;
    insert into public.lead_events (organization_id, lead_id, event_type, actor_user_id, detail)
    values (p_org, l.id, 'note', v_user, jsonb_build_object('text', btrim(p_args->>'text')));
    update public.leads set updated_at = now() where id = l.id;
    return l.id;
  end if;

  if p_op = 'next_contact' then
    if l.status in ('lost', 'won') then raise exception 'lead_closed'; end if;
    update public.leads set next_contact_at = nullif(p_args->>'at', '')::timestamptz, updated_at = now() where id = l.id;
    insert into public.lead_events (organization_id, lead_id, event_type, actor_user_id, detail)
    values (p_org, l.id, 'next_contact', v_user, jsonb_build_object('at', nullif(p_args->>'at', '')));
    -- The first scheduled return counts as the first contact.
    if l.status = 'new' then
      update public.leads set status = 'contacted', stage_changed_at = now() where id = l.id;
      insert into public.lead_events (organization_id, lead_id, event_type, from_status, to_status, actor_user_id)
      values (p_org, l.id, 'status_changed', 'new', 'contacted', v_user);
    end if;
    return l.id;
  end if;

  raise exception 'invalid_lead_operation';
end $$;
revoke all on function private.lead_write(uuid, uuid, text, jsonb) from public, anon;
grant execute on function private.lead_write(uuid, uuid, text, jsonb) to authenticated;

-- Existing-lead operations derive the tenant FROM THE LEAD as the caller sees it (RLS), then validate inside lead_write.
create or replace function public.add_lead_note(p_lead_id uuid, p_text text)
returns uuid language sql security invoker set search_path = '' as $$
  select private.lead_write((select l.organization_id from public.leads l where l.id = p_lead_id), p_lead_id, 'note', jsonb_build_object('text', p_text))
$$;
create or replace function public.set_lead_next_contact(p_lead_id uuid, p_at timestamptz)
returns uuid language sql security invoker set search_path = '' as $$
  select private.lead_write((select l.organization_id from public.leads l where l.id = p_lead_id), p_lead_id, 'next_contact', jsonb_build_object('at', p_at))
$$;
create or replace function public.start_lead_sale(p_lead_id uuid, p_cpf text default null)
returns uuid language sql security invoker set search_path = '' as $$
  select private.lead_write((select l.organization_id from public.leads l where l.id = p_lead_id), p_lead_id, 'convert', jsonb_build_object('cpf', p_cpf))
$$;
create or replace function public.create_sales_lead(p_organization_id uuid, p_full_name text, p_phone text default null, p_cpf text default null,
                                                    p_email text default null, p_campaign_id uuid default null)
returns uuid language sql security invoker set search_path = '' as $$
  select private.lead_write(p_organization_id, null, 'create', jsonb_build_object('channel', 'manual', 'full_name', p_full_name, 'phone', p_phone,
                            'cpf', p_cpf, 'email', p_email, 'campaign_id', p_campaign_id))
$$;
revoke all on function public.add_lead_note(uuid, text), public.set_lead_next_contact(uuid, timestamptz), public.start_lead_sale(uuid, text),
  public.create_sales_lead(uuid, text, text, text, text, uuid) from public, anon;
grant execute on function public.add_lead_note(uuid, text), public.set_lead_next_contact(uuid, timestamptz), public.start_lead_sale(uuid, text),
  public.create_sales_lead(uuid, text, text, text, text, uuid) to authenticated;

-- 5. Queue and distribution ----------------------------------------------------------------------------------------------
create or replace function public.lead_queue_count(p_org uuid, p_campaign uuid default null)
returns int language sql stable security definer set search_path = '' as $$
  select case when (select auth.uid()) is null then 0 else (select count(*)::int from private.caller_queue_leads(p_org, p_campaign)) end
$$;

-- Take the oldest waiting lead of the caller's queue (skip locked: two sellers never get the same lead).
create or replace function public.take_next_lead(p_org uuid, p_campaign uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_user uuid := (select auth.uid()); v_lead uuid;
begin
  if v_user is null or not public.has_permission(p_org, 'leads.edit') then raise exception 'not_authorized'; end if;
  select l.id into v_lead from public.leads l
  where l.id in (select q from private.caller_queue_leads(p_org, p_campaign) q) and l.owner_user_id is null
  order by l.created_at, l.id
  limit 1 for update skip locked;
  if v_lead is null then return null; end if;
  update public.leads set owner_user_id = v_user, assigned_at = now(), updated_at = now() where id = v_lead;
  insert into public.lead_events (organization_id, lead_id, event_type, actor_user_id, detail)
  values (p_org, v_lead, 'owner_changed', v_user, jsonb_build_object('mode', 'queue', 'owner_user_id', v_user));
  return v_lead;
end $$;

-- Manual distribution by a supervisor: chosen leads, or the N oldest waiting leads of a campaign, to one seller.
create or replace function public.assign_leads(p_org uuid, p_owner uuid, p_lead_ids uuid[] default null, p_campaign uuid default null, p_count int default null)
returns int language plpgsql security definer set search_path = '' as $$
declare v_user uuid := (select auth.uid()); v_ids uuid[]; n int;
begin
  if v_user is null or not public.has_permission(p_org, 'leads.approve') then raise exception 'not_authorized'; end if;
  if p_owner is null or not private.can_own_leads(p_org, p_owner) then raise exception 'invalid_lead_owner'; end if;
  if p_lead_ids is not null then
    if cardinality(p_lead_ids) > 500 then raise exception 'too_many_leads'; end if;
    select array_agg(l.id) into v_ids from public.leads l
    where l.organization_id = p_org and l.id = any (p_lead_ids) and l.status not in ('won', 'lost')
      and private.can_see_owner(p_org, coalesce(l.owner_user_id, l.created_by));
  elsif p_campaign is not null and p_count between 1 and 1000 then
    select array_agg(x.id) into v_ids from (
      select l.id from public.leads l
      where l.organization_id = p_org and l.campaign_id = p_campaign and l.owner_user_id is null and l.status in ('new', 'contacted', 'negotiating')
        and private.can_see_owner(p_org, coalesce(l.owner_user_id, l.created_by))
      order by l.created_at, l.id limit p_count for update skip locked) x;
  else
    raise exception 'invalid_assignment';
  end if;
  if v_ids is null then return 0; end if;
  update public.leads set owner_user_id = p_owner, assigned_at = now(), updated_at = now()
  where id = any (v_ids) and owner_user_id is distinct from p_owner;
  get diagnostics n = row_count;
  insert into public.lead_events (organization_id, lead_id, event_type, actor_user_id, detail)
  select p_org, x, 'owner_changed', v_user, jsonb_build_object('mode', 'manual', 'owner_user_id', p_owner) from unnest(v_ids) x;
  return n;
end $$;

-- Claim a specific unassigned lead: supervisors, or a lead of the caller's queue.
create or replace function public.claim_lead(p_lead uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_org uuid; n int;
begin
  select organization_id into v_org from public.leads where id = p_lead;
  if v_org is null or auth.uid() is null or not public.has_permission(v_org, 'leads.edit') then raise exception 'not_authorized'; end if;
  if not public.has_permission(v_org, 'leads.approve') and not exists (select 1 from private.caller_queue_leads(v_org, null) q where q = p_lead) then
    raise exception 'not_authorized';
  end if;
  update public.leads set owner_user_id = auth.uid(), assigned_at = now(), updated_at = now()
  where id = p_lead and owner_user_id is null and status in ('new', 'contacted', 'negotiating');
  get diagnostics n = row_count;
  if n = 0 then raise exception 'lead_already_taken'; end if;
  insert into public.lead_events (organization_id, lead_id, event_type, actor_user_id, detail)
  values (v_org, p_lead, 'owner_changed', auth.uid(), jsonb_build_object('mode', 'claim', 'owner_user_id', auth.uid()));
end $$;

revoke all on function public.lead_queue_count(uuid, uuid), public.take_next_lead(uuid, uuid), public.assign_leads(uuid, uuid, uuid[], uuid, int),
  public.claim_lead(uuid) from public, anon;
grant execute on function public.lead_queue_count(uuid, uuid), public.take_next_lead(uuid, uuid), public.assign_leads(uuid, uuid, uuid[], uuid, int),
  public.claim_lead(uuid) to authenticated;

-- 6. Campaigns and spreadsheet import ------------------------------------------------------------------------------------
create or replace function public.save_sales_campaign(p_org uuid, p_id uuid, p_name text, p_description text, p_distribution text,
                                                      p_starts_on date, p_ends_on date, p_status text, p_members uuid[])
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_user uuid := (select auth.uid()); v_id uuid := p_id; v_bad uuid;
begin
  if v_user is null or not public.has_permission(p_org, 'leads.approve') then raise exception 'not_authorized'; end if;
  if p_distribution not in ('queue', 'manual', 'round_robin') then raise exception 'invalid_distribution'; end if;
  if coalesce(p_status, 'active') not in ('active', 'closed') then raise exception 'invalid_campaign_status'; end if;
  if cardinality(coalesce(p_members, '{}')) > 200 then raise exception 'too_many_members'; end if;
  select m into v_bad from unnest(coalesce(p_members, '{}')) m where not private.can_own_leads(p_org, m) limit 1;
  if v_bad is not null then raise exception 'invalid_campaign_member'; end if;
  if p_distribution = 'round_robin' and cardinality(coalesce(p_members, '{}')) = 0 then raise exception 'round_robin_needs_members'; end if;
  begin
    if v_id is null then
      insert into public.sales_campaigns (organization_id, name, description, distribution, starts_on, ends_on, status, created_by)
      values (p_org, btrim(p_name), nullif(btrim(coalesce(p_description, '')), ''), p_distribution, p_starts_on, p_ends_on, coalesce(p_status, 'active'), v_user)
      returning id into v_id;
    else
      update public.sales_campaigns
      set name = btrim(p_name), description = nullif(btrim(coalesce(p_description, '')), ''), distribution = p_distribution,
          starts_on = p_starts_on, ends_on = p_ends_on, status = coalesce(p_status, 'active'), updated_at = now()
      where organization_id = p_org and id = v_id;
      if not found then raise exception 'campaign_not_found'; end if;
    end if;
  exception when unique_violation then raise exception 'campaign_name_taken';
  end;
  delete from public.sales_campaign_members where campaign_id = v_id and not (user_id = any (coalesce(p_members, '{}')));
  insert into public.sales_campaign_members (organization_id, campaign_id, user_id)
  select p_org, v_id, m from unnest(coalesce(p_members, '{}')) m on conflict do nothing;
  return v_id;
end $$;

-- One chunk of a campaign spreadsheet (read in the browser). Each row: {name, cpf, phone, phone2, email, info:{label: text}}.
-- Rules: a valid CPF is kept (an invalid one is dropped, not guessed); a known client (CPF, else phone) is linked and never
-- changed; the same CPF, client or phone twice in the campaign is skipped; a row needs a name and a CPF or phone.
-- round_robin campaigns spread the new leads among the members, fewest open leads in the campaign first.
create or replace function public.import_campaign_leads(p_campaign uuid, p_file_name text, p_file_sha256 text, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := (select auth.uid());
  c public.sales_campaigns%rowtype;
  r jsonb;
  v_name text; v_cpf text; v_phone text; v_phone2 text; v_email text; v_info jsonb; v_customer uuid; v_client_name text;
  v_members uuid[]; v_next int := 0; v_owner uuid; v_lead uuid;
  n_created int := 0; n_linked int := 0; n_dup int := 0; n_invalid int := 0; v_import uuid;
begin
  select * into c from public.sales_campaigns where id = p_campaign;
  if not found or v_user is null or not public.has_permission(c.organization_id, 'leads.approve') then raise exception 'not_authorized'; end if;
  if c.status <> 'active' then raise exception 'campaign_not_active'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 2000 then raise exception 'invalid_rows'; end if;
  if coalesce(p_file_sha256, '') !~ '^[0-9a-f]{64}$' or length(coalesce(btrim(p_file_name), '')) not between 1 and 255 then raise exception 'invalid_file'; end if;
  perform pg_advisory_xact_lock(hashtext('sales_campaign:' || c.id::text));

  if c.distribution = 'round_robin' then
    select array_agg(m.user_id order by (select count(*) from public.leads x where x.campaign_id = c.id and x.owner_user_id = m.user_id
                                          and x.status not in ('won', 'lost')), m.created_at, m.user_id)
    into v_members
    from public.sales_campaign_members m where m.campaign_id = c.id and private.can_own_leads(c.organization_id, m.user_id);
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_customer := null; v_client_name := null;
    v_name := nullif(btrim(coalesce(r->>'name', '')), '');
    v_cpf := nullif(regexp_replace(coalesce(r->>'cpf', ''), '\D', '', 'g'), '');
    -- Spreadsheets drop the leading zeros of a CPF kept as a number.
    if v_cpf is not null and length(v_cpf) between 9 and 10 then v_cpf := lpad(v_cpf, 11, '0'); end if;
    if v_cpf is not null and not private.is_valid_cpf(v_cpf) then v_cpf := null; end if;
    v_phone := private.normalize_phone(r->>'phone');
    v_phone2 := private.normalize_phone(r->>'phone2');
    if v_phone is null then v_phone := v_phone2; v_phone2 := null; end if;
    v_email := nullif(lower(btrim(coalesce(r->>'email', ''))), '');
    if v_email is not null and v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then v_email := null; end if;
    v_info := case when jsonb_typeof(r->'info') = 'object' then r->'info' else '{}'::jsonb end;

    if v_cpf is not null then
      select cl.id, cl.full_name into v_customer, v_client_name from public.clients cl
      where cl.organization_id = c.organization_id and cl.cpf = v_cpf and cl.deleted_at is null;
    end if;
    if v_customer is null and v_phone is not null then
      select x.customer_id into v_customer from public.client_contacts x
      where x.organization_id = c.organization_id and x.kind = 'phone' and x.value = v_phone
      order by x.last_seen_at desc limit 1;
      if v_customer is not null then
        select cl.full_name, cl.cpf into v_client_name, v_cpf from public.clients cl where cl.id = v_customer and cl.deleted_at is null;
        if v_client_name is null then v_customer := null; end if;
      end if;
    end if;
    v_name := coalesce(v_name, v_client_name);

    if v_name is null or length(v_name) not between 2 and 200 or (v_cpf is null and v_phone is null)
       or octet_length(v_info::text) > 6000 or (select count(*) from jsonb_object_keys(v_info)) > 40 then
      n_invalid := n_invalid + 1;
      continue;
    end if;
    if exists (select 1 from public.leads x where x.campaign_id = c.id
               and ((v_cpf is not null and x.cpf = v_cpf) or (v_customer is not null and x.customer_id = v_customer)
                    or (v_phone is not null and x.phone = v_phone))) then
      n_dup := n_dup + 1;
      continue;
    end if;

    v_owner := null;
    if cardinality(coalesce(v_members, '{}')) > 0 then
      v_owner := v_members[(v_next % cardinality(v_members)) + 1];
      v_next := v_next + 1;
    end if;
    insert into public.leads (organization_id, status, channel, campaign_id, campaign, full_name, phone, email, cpf, customer_id, converted_at,
                              owner_user_id, assigned_at, metadata, created_by, created_at)
    values (c.organization_id, 'new', 'import', c.id, c.name, v_name, v_phone, v_email, v_cpf, v_customer, case when v_customer is not null then now() end,
            v_owner, case when v_owner is not null then now() end,
            jsonb_build_object('info', v_info) || case when v_phone2 is not null then jsonb_build_object('phone2', v_phone2) else '{}'::jsonb end,
            v_user, clock_timestamp())  -- file order is queue order
    returning id into v_lead;
    insert into public.lead_events (organization_id, lead_id, event_type, to_status, actor_user_id, detail)
    values (c.organization_id, v_lead, 'imported', 'new', v_user,
            jsonb_build_object('campaign_id', c.id, 'file_sha256', p_file_sha256, 'client_linked', v_customer is not null, 'owner_user_id', v_owner));
    n_created := n_created + 1;
    if v_customer is not null then n_linked := n_linked + 1; end if;
  end loop;

  insert into public.sales_campaign_imports (organization_id, campaign_id, file_name, file_sha256, row_count, created_count, linked_client_count,
                                             duplicate_count, invalid_count, created_by)
  values (c.organization_id, c.id, btrim(p_file_name), p_file_sha256, jsonb_array_length(p_rows), n_created, n_linked, n_dup, n_invalid, v_user)
  returning id into v_import;
  return jsonb_build_object('import_id', v_import, 'created', n_created, 'linked_clients', n_linked, 'duplicates', n_dup, 'invalid', n_invalid);
end $$;

revoke all on function public.save_sales_campaign(uuid, uuid, text, text, text, date, date, text, uuid[]), public.import_campaign_leads(uuid, text, text, jsonb)
  from public, anon;
grant execute on function public.save_sales_campaign(uuid, uuid, text, text, text, date, date, text, uuid[]), public.import_campaign_leads(uuid, text, text, jsonb)
  to authenticated;

-- 7. Stage follows the client's proposal -------------------------------------------------------------------------------
-- A new proposal of the client moves its open leads to "proposal"; paid moves them to "won"; rejected or cancelled brings
-- them back to "negotiating" so the seller keeps working the client.
create or replace function private.leads_follow_proposal()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    with moved as (
      update public.leads l set status = 'proposal', proposal_id = new.id, stage_changed_at = now(), updated_at = now()
      where l.organization_id = new.organization_id and l.customer_id = new.customer_id and l.status in ('new', 'contacted', 'negotiating')
      returning l.id, l.organization_id)
    insert into public.lead_events (organization_id, lead_id, event_type, to_status, actor_user_id, detail)
    select organization_id, id, 'proposal_linked', 'proposal', (select auth.uid()), jsonb_build_object('proposal_id', new.id) from moved;
  elsif new.status is distinct from old.status and new.status = 'paid' then
    with moved as (
      update public.leads l set status = 'won', won_at = now(), next_contact_at = null, stage_changed_at = now(), updated_at = now()
      where l.proposal_id = new.id and l.status = 'proposal'
      returning l.id, l.organization_id)
    insert into public.lead_events (organization_id, lead_id, event_type, from_status, to_status, actor_user_id, detail)
    select organization_id, id, 'won', 'proposal', 'won', (select auth.uid()), jsonb_build_object('proposal_id', new.id) from moved;
  elsif new.status is distinct from old.status and new.status in ('rejected', 'cancelled') then
    with moved as (
      update public.leads l set status = 'negotiating', proposal_id = null, stage_changed_at = now(), updated_at = now()
      where l.proposal_id = new.id and l.status = 'proposal'
      returning l.id, l.organization_id)
    insert into public.lead_events (organization_id, lead_id, event_type, from_status, to_status, actor_user_id, detail)
    select organization_id, id, 'status_changed', 'proposal', 'negotiating', (select auth.uid()),
           jsonb_build_object('proposal_id', new.id, 'proposal_status', new.status) from moved;
  end if;
  return null;
end $$;
revoke all on function private.leads_follow_proposal() from public, anon, authenticated;
create trigger proposals_v2_80_leads_follow after insert or update of status on public.proposals_v2
  for each row execute function private.leads_follow_proposal();

-- 8. API intake: new stages, CPF column and client link --------------------------------------------------------------------
create or replace function public.api_ingest_lead(p_key text, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  k public.api_keys%rowtype;
  v_recent int;
  v_name text := btrim(coalesce(p_payload->>'full_name', ''));
  v_phone text := private.normalize_phone(p_payload->>'phone');
  v_email text := nullif(lower(btrim(coalesce(p_payload->>'email', ''))), '');
  v_cpf text := nullif(regexp_replace(coalesce(p_payload->>'cpf', ''), '\D', '', 'g'), '');
  v_ref text := nullif(btrim(coalesce(p_payload->>'external_ref', '')), '');
  v_campaign text := nullif(btrim(coalesce(p_payload->>'campaign', '')), '');
  v_meta jsonb := coalesce(p_payload->'metadata', '{}'::jsonb);
  v_client uuid;
  v_lead uuid;
  v_status text;
begin
  select * into k from public.api_keys where key_hash = encode(extensions.digest(coalesce(p_key, ''), 'sha256'), 'hex');
  if not found or k.revoked_at is not null then return jsonb_build_object('error', 'invalid_api_key'); end if;

  select count(*) into v_recent from public.api_request_log l where l.api_key_id = k.id and l.occurred_at > now() - interval '1 minute';
  if v_recent >= k.rate_limit_per_minute then
    insert into public.api_request_log (api_key_id, organization_id, endpoint, outcome) values (k.id, k.organization_id, 'leads.create', 'rate_limited');
    return jsonb_build_object('error', 'rate_limited');
  end if;
  update public.api_keys set last_used_at = now() where id = k.id;

  if not ('leads.write' = any (k.scopes)) then
    insert into public.api_request_log (api_key_id, organization_id, endpoint, outcome) values (k.id, k.organization_id, 'leads.create', 'forbidden');
    return jsonb_build_object('error', 'insufficient_scope');
  end if;
  if not exists (select 1 from public.organization_modules m where m.organization_id = k.organization_id and m.module_key = 'api' and m.enabled)
     or not exists (select 1 from public.organization_modules m where m.organization_id = k.organization_id and m.module_key = 'leads' and m.enabled)
     or not exists (select 1 from public.organizations o where o.id = k.organization_id and coalesce(o.is_active, true)) then
    insert into public.api_request_log (api_key_id, organization_id, endpoint, outcome) values (k.id, k.organization_id, 'leads.create', 'module_disabled');
    return jsonb_build_object('error', 'module_disabled');
  end if;

  if length(v_name) not between 2 and 200 then return jsonb_build_object('error', 'invalid_full_name'); end if;
  if v_phone is null and v_email is null then return jsonb_build_object('error', 'phone_or_email_required'); end if;
  if v_email is not null and v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then return jsonb_build_object('error', 'invalid_email'); end if;
  if v_cpf is not null and not private.is_valid_cpf(v_cpf) then return jsonb_build_object('error', 'invalid_cpf'); end if;
  if v_ref is not null and length(v_ref) > 120 then return jsonb_build_object('error', 'invalid_external_ref'); end if;
  if jsonb_typeof(v_meta) <> 'object' or octet_length(v_meta::text) > 6000 then return jsonb_build_object('error', 'invalid_metadata'); end if;

  if v_ref is not null then
    select l.id, l.status into v_lead, v_status from public.leads l where l.organization_id = k.organization_id and l.channel = 'api' and l.external_ref = v_ref;
    if v_lead is not null then
      insert into public.api_request_log (api_key_id, organization_id, endpoint, outcome) values (k.id, k.organization_id, 'leads.create', 'duplicate');
      return jsonb_build_object('id', v_lead, 'status', v_status, 'duplicate', true);
    end if;
  end if;

  -- An open lead with the same phone: return it and note the new contact.
  if v_phone is not null then
    select l.id, l.status into v_lead, v_status from public.leads l
    where l.organization_id = k.organization_id and l.status in ('new', 'contacted', 'negotiating', 'proposal') and private.normalize_phone(l.phone) = v_phone
    order by l.created_at limit 1;
    if v_lead is not null then
      insert into public.lead_events (organization_id, lead_id, event_type, actor_user_id, detail)
      values (k.organization_id, v_lead, 'note', null, jsonb_build_object('kind', 'api_contact_again', 'campaign', v_campaign, 'external_ref', v_ref));
      insert into public.api_request_log (api_key_id, organization_id, endpoint, outcome) values (k.id, k.organization_id, 'leads.create', 'duplicate');
      return jsonb_build_object('id', v_lead, 'status', v_status, 'duplicate', true);
    end if;
  end if;

  -- Existing client by CPF, else by phone: linked for the seller; the client record is not changed here.
  if v_cpf is not null then
    select c.id into v_client from public.clients c where c.organization_id = k.organization_id and c.cpf = v_cpf and c.deleted_at is null;
  end if;
  if v_client is null and v_phone is not null then
    select x.customer_id into v_client from public.client_contacts x
    where x.organization_id = k.organization_id and x.kind = 'phone' and x.value = v_phone
    order by x.last_seen_at desc limit 1;
  end if;

  insert into public.leads (organization_id, status, channel, campaign, external_ref, full_name, phone, email, cpf, customer_id, converted_at, metadata)
  values (k.organization_id, 'new', 'api', v_campaign, v_ref, v_name, v_phone, v_email, v_cpf, v_client, case when v_client is not null then now() end,
          v_meta || jsonb_build_object('api_key_id', k.id))
  returning id into v_lead;
  insert into public.lead_events (organization_id, lead_id, event_type, to_status, actor_user_id, detail)
  values (k.organization_id, v_lead, 'created', 'new', null, jsonb_build_object('channel', 'api', 'campaign', v_campaign, 'api_key_id', k.id));
  insert into public.api_request_log (api_key_id, organization_id, endpoint, outcome) values (k.id, k.organization_id, 'leads.create', 'created');
  return jsonb_build_object('id', v_lead, 'status', 'new', 'duplicate', false, 'matched_client', v_client is not null);
end $$;

-- 9. Numbers per campaign, seller and stage, as the caller sees them (security invoker: RLS decides what is counted).
create or replace function public.sales_lead_counts(p_org uuid)
returns table (campaign_id uuid, owner_user_id uuid, status text, total bigint)
language sql stable security invoker set search_path = '' as $$
  select l.campaign_id, l.owner_user_id, l.status, count(*) from public.leads l where l.organization_id = p_org group by 1, 2, 3
$$;
revoke all on function public.sales_lead_counts(uuid) from public, anon;
grant execute on function public.sales_lead_counts(uuid) to authenticated;
