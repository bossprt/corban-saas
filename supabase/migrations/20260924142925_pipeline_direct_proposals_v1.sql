-- F3 step 1: direct proposals, pipeline moves, lead distribution and goals (approved by the owner, MAPA-OPERACAO §4, §1).
--
-- Proposals: created directly (before digitization, or already digitized with the bank number/ADE), besides the
-- existing simulation path. The same bank + ADE never creates a second proposal.
-- Pipeline: default stages per company now include "Paga"; a pendency carries a reason and a due date and, once
-- solved, returns the proposal to analysis. "Paga" can be set by anyone allowed to edit the pipeline, with a mandatory
-- note; it is recorded as manual evidence and the bank report confirms it later (reconciliation, F5).
-- Leads: each company chooses round robin, open queue or manual distribution and marks who receives leads.
-- Goals: monthly target per seller, measured by the released amount of proposals paid in the month.

-- Stages ----------------------------------------------------------------------------------------------------------

create or replace function private.ensure_default_stages(p_org uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
begin
  perform set_config('corban.operational_rpc', 'on', true);
  insert into public.operational_stages (organization_id, code, name, canonical_state, sort_order, sla_minutes, is_active)
  select p_org, s.code, s.name, s.state, s.ord, s.sla, true
  from (values
    ('fila_digitacao', 'Aguardando digitação', 'digitization_queue', 10, 1440),
    ('digitando',      'Em digitação',         'digitizing',         20, 480),
    ('enviada',        'Em análise no banco',  'submitted',          30, 4320),
    ('pendencia',      'Pendência',            'pending_external',   40, 2880),
    ('aprovada',       'Aprovada',             'approved',           50, 2880),
    ('paga',           'Paga',                 'paid',               60, null),
    ('recusada',       'Recusada',             'rejected',           70, null),
    ('cancelada',      'Cancelada',            'cancelled',          80, null)
  ) as s(code, name, state, ord, sla)
  -- A company that already has a stage for a state keeps its own naming.
  where not exists (select 1 from public.operational_stages x where x.organization_id = p_org and x.canonical_state = s.state);
  perform set_config('corban.operational_rpc', 'off', true);
end
$$;

revoke all on function private.ensure_default_stages(uuid) from public, anon, authenticated;

create or replace function public.organizations_default_stages()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  perform private.ensure_default_stages(new.id);
  return new;
end
$$;

revoke all on function public.organizations_default_stages() from public, anon, authenticated;

create trigger organizations_30_default_stages
  after insert on public.organizations
  for each row execute function public.organizations_default_stages();

do $$
declare v_org uuid;
begin
  for v_org in select id from public.organizations loop
    perform private.ensure_default_stages(v_org);
  end loop;
end $$;

-- Pendency details on the case.
alter table public.operational_cases
  add column pendency_reason text check (pendency_reason is null or length(btrim(pendency_reason)) between 3 and 500),
  add column pendency_due_at timestamptz;

-- Manual payment evidence ------------------------------------------------------------------------------------------

alter table public.proposal_status_evidence alter column import_decision_id drop not null;
alter table public.proposal_status_evidence
  add column source text not null default 'import' check (source in ('import','manual')),
  add column note text check (note is null or length(btrim(note)) between 3 and 500),
  add constraint proposal_status_evidence_source_fields check (
    (source = 'import' and import_decision_id is not null) or (source = 'manual' and note is not null)
  );

-- Pipeline moves that the existing transition does not cover ---------------------------------------------------------
-- pending_external with reason and due date, pending_external back to submitted, and paid (manual, with note).
-- Every other move is delegated to transition_operational_case, unchanged.
create or replace function public.move_operational_case(
  p_case_id uuid, p_to_state text, p_note text default null, p_pendency_due_at timestamptz default null
)
returns text
language plpgsql
security definer
set search_path to ''
as $$
declare
  c public.operational_cases%rowtype;
  v_stage uuid;
  v_sla integer;
  v_status text;
begin
  select * into c from public.operational_cases where id = p_case_id for update;
  if not found or not public.is_active_organization_member(c.organization_id) then raise exception 'operational_case_not_found_or_forbidden'; end if;
  -- The caller must see the proposal (scope) and be allowed to edit the pipeline.
  if not exists (
    select 1 from public.proposals_v2 p
    where p.id = c.proposal_id and private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by)
  ) then raise exception 'operational_case_not_found_or_forbidden'; end if;
  if not public.has_permission(c.organization_id, 'esteira.edit') then raise exception 'not_authorized'; end if;

  if not (
    (p_to_state = 'pending_external' and c.canonical_state in ('submitted','approved')) or
    (p_to_state = 'submitted' and c.canonical_state = 'pending_external') or
    (p_to_state = 'paid' and c.canonical_state in ('submitted','pending_external','approved'))
  ) then
    -- Not one of the new moves: the governed transition decides (and enforces its own rules).
    return public.transition_operational_case(p_case_id, p_to_state, null);
  end if;

  if p_to_state in ('pending_external','paid') and (p_note is null or length(btrim(p_note)) < 3) then raise exception 'note_required'; end if;
  if p_to_state = 'pending_external' and (p_pendency_due_at is null or p_pendency_due_at < now()) then raise exception 'pendency_due_required'; end if;

  select s.id, s.sla_minutes into v_stage, v_sla from public.operational_stages s
  where s.organization_id = c.organization_id and s.canonical_state = p_to_state and s.is_active
  order by s.sort_order, s.created_at limit 1;
  if v_stage is null then raise exception 'target_operational_stage_not_configured'; end if;

  perform set_config('corban.operational_rpc', 'on', true);
  perform set_config('corban.proposal_rpc', 'on', true);
  update public.operational_cases
  set current_stage_id = v_stage,
      canonical_state = p_to_state,
      entered_stage_at = now(),
      due_at = case when v_sla is null then null else now() + make_interval(mins => v_sla) end,
      pendency_reason = case when p_to_state = 'pending_external' then btrim(p_note) else null end,
      pendency_due_at = case when p_to_state = 'pending_external' then p_pendency_due_at else null end,
      updated_at = now()
  where id = c.id;

  select p.status into v_status from public.proposals_v2 p where p.id = c.proposal_id for update;
  if p_to_state = 'paid' then
    -- The proposal status machine only allows approved -> paid.
    if v_status in ('digitization') then
      update public.proposals_v2 set status = 'submitted', updated_at = now() where id = c.proposal_id;
      v_status := 'submitted';
    end if;
    if v_status = 'submitted' then
      update public.proposals_v2 set status = 'approved', updated_at = now() where id = c.proposal_id;
    end if;
    perform set_config('corban.paid_evidence_rpc', 'on', true);
    update public.proposals_v2 set status = 'paid', updated_at = now() where id = c.proposal_id;
    insert into public.proposal_status_evidence (organization_id, proposal_id, import_decision_id, canonical_status, raw_status, evidenced_at, created_by, source, note)
    values (c.organization_id, c.proposal_id, null, 'paid', 'manual', now(), auth.uid(), 'manual', btrim(p_note));
    perform set_config('corban.paid_evidence_rpc', 'off', true);
  elsif v_status not in ('submitted') and p_to_state in ('submitted','pending_external') then
    if v_status = 'digitization' then
      update public.proposals_v2 set status = 'submitted', updated_at = now() where id = c.proposal_id;
    end if;
  end if;

  insert into public.operational_events (organization_id, operational_case_id, event_type, from_state, to_state, source, actor_user_id, metadata)
  values (c.organization_id, c.id, 'state_transition', c.canonical_state, p_to_state, 'corban_os', auth.uid(),
          jsonb_build_object('note', nullif(btrim(coalesce(p_note, '')), ''), 'pendency_due_at', p_pendency_due_at));
  perform set_config('corban.operational_rpc', 'off', true);
  perform set_config('corban.proposal_rpc', 'off', true);
  return p_to_state;
end
$$;

revoke all on function public.move_operational_case(uuid, text, text, timestamptz) from public, anon;
grant execute on function public.move_operational_case(uuid, text, text, timestamptz) to authenticated;

-- Direct proposals -----------------------------------------------------------------------------------------------------

-- Creates a proposal without a simulation. p_stage: 'digitization_queue' (to be digitized) or 'submitted' (already
-- digitized; the ADE is then required). Same bank + ADE returns the existing proposal (duplicate = true).
create or replace function public.create_direct_proposal(
  p_org uuid, p_customer_id uuid, p_table_version_id uuid, p_seller_id uuid,
  p_requested_amount numeric, p_released_amount numeric, p_installment_amount numeric, p_term int,
  p_ade text, p_stage text
)
returns table (proposal_id uuid, duplicate boolean)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_client public.clients%rowtype;
  v_bank_key text;
  v_bank_name text;
  v_table_name text;
  v_ade text := nullif(btrim(coalesce(p_ade, '')), '');
  v_existing uuid;
  v_id uuid;
  v_stage uuid;
  v_sla integer;
begin
  if auth.uid() is null or not public.is_active_organization_member(p_org) then raise exception 'not_authorized'; end if;
  if not public.has_permission(p_org, 'propostas.create') then raise exception 'not_authorized'; end if;
  if p_stage not in ('digitization_queue','submitted') then raise exception 'invalid_stage'; end if;
  if p_stage = 'submitted' and v_ade is null then raise exception 'ade_required'; end if;
  if v_ade is not null and (length(v_ade) > 60 or v_ade !~ '^[A-Za-z0-9./-]+$') then raise exception 'invalid_ade'; end if;
  if coalesce(p_requested_amount, 0) < 0 or coalesce(p_released_amount, 0) < 0 or coalesce(p_installment_amount, 0) < 0 then raise exception 'invalid_amount'; end if;
  if p_released_amount is null and p_requested_amount is null then raise exception 'amount_required'; end if;
  if p_term is not null and (p_term < 1 or p_term > 420) then raise exception 'invalid_term'; end if;

  select * into v_client from public.clients c where c.organization_id = p_org and c.id = p_customer_id and c.deleted_at is null;
  if not found or not private.can_see_client_row(p_org, v_client.id, v_client.owner_user_id) then raise exception 'client_not_found'; end if;
  if p_seller_id is not null and not exists (select 1 from public.commercial_sellers s where s.organization_id = p_org and s.id = p_seller_id and s.is_active) then
    raise exception 'seller_not_found';
  end if;

  select coalesce(ob.tech_key, b.code, b.name), coalesce(ob.name, b.name), t.name into v_bank_key, v_bank_name, v_table_name
  from public.product_table_versions v
  join public.product_tables t on t.id = v.product_table_id and t.organization_id = v.organization_id
  join public.organization_product_routes r on r.id = t.route_id and r.organization_id = t.organization_id
  left join public.organization_banks ob on ob.id = r.org_bank_id and ob.organization_id = r.organization_id
  left join public.banks b on b.id = r.bank_id
  where v.organization_id = p_org and v.id = p_table_version_id and v.status = 'published';
  if v_bank_key is null then raise exception 'table_not_found'; end if;

  -- Same bank + ADE: the proposal already exists.
  if v_ade is not null then
    perform pg_advisory_xact_lock(hashtext(p_org::text || ':' || lower(v_bank_key) || ':' || v_ade));
    select e.proposal_id into v_existing from public.proposal_external_identities e
    where e.organization_id = p_org and lower(e.institution_key) = lower(v_bank_key) and e.external_proposal_number = v_ade;
    if v_existing is not null then return query select v_existing, true; return; end if;
  end if;

  perform set_config('corban.proposal_rpc', 'on', true);
  insert into public.proposals_v2 (organization_id, customer_id, simulation_id, product_table_version_id, status, external_proposal_id,
                                   requested_amount, released_amount, installment_amount, term, customer_snapshot, commercial_snapshot, seller_id, created_by)
  values (p_org, p_customer_id, null, p_table_version_id, case when p_stage = 'submitted' then 'submitted' else 'digitization' end, v_ade,
          p_requested_amount, p_released_amount, p_installment_amount, p_term,
          jsonb_build_object('full_name', v_client.full_name, 'cpf', v_client.cpf),
          jsonb_build_object('origin', 'direct', 'bank', v_bank_name, 'table', v_table_name, 'table_version_id', p_table_version_id),
          p_seller_id, auth.uid())
  returning id into v_id;

  if v_ade is not null then
    insert into public.proposal_external_identities (organization_id, proposal_id, institution_key, external_proposal_number, source)
    values (p_org, v_id, v_bank_key, v_ade, 'manual');
  end if;

  select s.id, s.sla_minutes into v_stage, v_sla from public.operational_stages s
  where s.organization_id = p_org and s.canonical_state = p_stage and s.is_active order by s.sort_order limit 1;
  if v_stage is null then raise exception 'target_operational_stage_not_configured'; end if;

  perform set_config('corban.operational_rpc', 'on', true);
  insert into public.operational_cases (organization_id, proposal_id, current_stage_id, canonical_state, owner_user_id, entered_stage_at, due_at)
  values (p_org, v_id, v_stage, p_stage, auth.uid(), now(), case when v_sla is null then null else now() + make_interval(mins => v_sla) end);
  perform set_config('corban.operational_rpc', 'off', true);
  perform set_config('corban.proposal_rpc', 'off', true);
  return query select v_id, false;
end
$$;

revoke all on function public.create_direct_proposal(uuid, uuid, uuid, uuid, numeric, numeric, numeric, int, text, text) from public, anon;
grant execute on function public.create_direct_proposal(uuid, uuid, uuid, uuid, numeric, numeric, numeric, int, text, text) to authenticated;

-- Lead distribution ------------------------------------------------------------------------------------------------------

create table public.organization_lead_settings (
  organization_id uuid primary key references public.organizations(id) on delete restrict,
  distribution text not null default 'manual' check (distribution in ('round_robin','queue','manual')),
  updated_at timestamptz not null default now(),
  updated_by uuid
);

alter table public.organization_lead_settings enable row level security;
revoke all on table public.organization_lead_settings from anon, authenticated;
grant select on public.organization_lead_settings to authenticated;
create policy organization_lead_settings_select_member on public.organization_lead_settings for select to authenticated
  using (public.is_active_organization_member(organization_id));

alter table public.organization_memberships add column receives_leads boolean not null default false;
alter table public.leads add column assigned_at timestamptz;

-- Next receiver in round robin: the eligible member who received a lead longest ago.
create or replace function private.next_lead_owner(p_org uuid)
returns uuid
language sql
stable
security definer
set search_path to ''
as $$
  select m.user_id
  from public.organization_memberships m
  where m.organization_id = p_org and m.status = 'active' and m.receives_leads
  order by (select max(l.assigned_at) from public.leads l where l.organization_id = p_org and l.owner_user_id = m.user_id) nulls first, m.created_at
  limit 1
$$;

revoke all on function private.next_lead_owner(uuid) from public, anon, authenticated;

-- Applies the company's distribution to a lead that has no owner (called after API ingestion).
create or replace function private.distribute_lead(p_org uuid, p_lead uuid)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare v_mode text; v_owner uuid;
begin
  select distribution into v_mode from public.organization_lead_settings where organization_id = p_org;
  if coalesce(v_mode, 'manual') <> 'round_robin' then return null; end if;
  v_owner := private.next_lead_owner(p_org);
  if v_owner is null then return null; end if;
  update public.leads set owner_user_id = v_owner, assigned_at = now(), updated_at = now()
  where organization_id = p_org and id = p_lead and owner_user_id is null;
  insert into public.lead_events (organization_id, lead_id, event_type, actor_user_id, detail)
  values (p_org, p_lead, 'owner_changed', null, jsonb_build_object('mode', 'round_robin', 'owner_user_id', v_owner));
  return v_owner;
end
$$;

revoke all on function private.distribute_lead(uuid, uuid) from public, anon, authenticated;

create or replace function public.set_lead_distribution(p_org uuid, p_distribution text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or private.caller_role_in(p_org) not in ('admin','manager') then raise exception 'not_authorized'; end if;
  if p_distribution not in ('round_robin','queue','manual') then raise exception 'invalid_distribution'; end if;
  insert into public.organization_lead_settings (organization_id, distribution, updated_by) values (p_org, p_distribution, auth.uid())
  on conflict (organization_id) do update set distribution = excluded.distribution, updated_at = now(), updated_by = auth.uid();
end
$$;

revoke all on function public.set_lead_distribution(uuid, text) from public, anon;
grant execute on function public.set_lead_distribution(uuid, text) to authenticated;

create or replace function public.set_member_receives_leads(p_membership_id uuid, p_receives boolean)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.organization_memberships where id = p_membership_id;
  if v_org is null or auth.uid() is null or private.caller_role_in(v_org) not in ('admin','manager') then raise exception 'not_authorized'; end if;
  perform set_config('corban.membership_rpc', 'on', true);
  update public.organization_memberships set receives_leads = coalesce(p_receives, false), updated_at = now() where id = p_membership_id;
  perform set_config('corban.membership_rpc', 'off', true);
end
$$;

revoke all on function public.set_member_receives_leads(uuid, boolean) from public, anon;
grant execute on function public.set_member_receives_leads(uuid, boolean) to authenticated;

-- Open queue: an unassigned lead is taken by the first member allowed to edit leads.
create or replace function public.claim_lead(p_lead uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare v_org uuid; v_mode text; n int;
begin
  select organization_id into v_org from public.leads where id = p_lead;
  if v_org is null or auth.uid() is null or not public.has_permission(v_org, 'leads.edit') then raise exception 'not_authorized'; end if;
  select distribution into v_mode from public.organization_lead_settings where organization_id = v_org;
  if coalesce(v_mode, 'manual') <> 'queue' and private.caller_role_in(v_org) not in ('admin','manager','supervisor') then raise exception 'not_authorized'; end if;
  update public.leads set owner_user_id = auth.uid(), assigned_at = now(), updated_at = now()
  where id = p_lead and owner_user_id is null and status in ('new','contacted','qualified');
  get diagnostics n = row_count;
  if n = 0 then raise exception 'lead_already_taken'; end if;
  insert into public.lead_events (organization_id, lead_id, event_type, actor_user_id, detail)
  values (v_org, p_lead, 'owner_changed', auth.uid(), jsonb_build_object('mode', coalesce(v_mode, 'manual'), 'owner_user_id', auth.uid()));
end
$$;

revoke all on function public.claim_lead(uuid) from public, anon;
grant execute on function public.claim_lead(uuid) to authenticated;

-- Unassigned leads are visible to members who can take them (queue) besides the usual scope.
drop policy if exists leads_scope on public.leads;
create policy leads_scope on public.leads as restrictive for all to authenticated
  using (private.can_see_owner(organization_id, coalesce(owner_user_id, created_by))
         or (owner_user_id is null and exists (
               select 1 from public.organization_lead_settings s where s.organization_id = leads.organization_id and s.distribution = 'queue')
             and public.has_permission(organization_id, 'leads.edit')))
  with check (private.can_see_owner(organization_id, coalesce(owner_user_id, created_by)));

-- API ingestion distributes new leads (wraps the existing function).
create or replace function public.api_ingest_lead_distributed(p_key text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare v_result jsonb; v_org uuid;
begin
  v_result := public.api_ingest_lead(p_key, p_payload);
  if v_result ? 'id' and not coalesce((v_result->>'duplicate')::boolean, false) then
    select organization_id into v_org from public.leads where id = (v_result->>'id')::uuid;
    perform private.distribute_lead(v_org, (v_result->>'id')::uuid);
  end if;
  return v_result;
end
$$;

revoke all on function public.api_ingest_lead_distributed(text, jsonb) from public, anon, authenticated;
grant execute on function public.api_ingest_lead_distributed(text, jsonb) to service_role;

-- Goals ---------------------------------------------------------------------------------------------------------------

create table public.seller_goals (
  organization_id uuid not null references public.organizations(id) on delete restrict,
  user_id uuid not null,
  month date not null check (extract(day from month) = 1),
  target_amount numeric(14,2) not null check (target_amount >= 0),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (organization_id, user_id, month)
);

alter table public.seller_goals enable row level security;
revoke all on table public.seller_goals from anon, authenticated;
grant select on public.seller_goals to authenticated;
create policy seller_goals_select_scope on public.seller_goals for select to authenticated
  using (public.is_active_organization_member(organization_id) and private.can_see_owner(organization_id, user_id));

create or replace function public.set_seller_goal(p_org uuid, p_user_id uuid, p_month date, p_target_amount numeric)
returns void
language plpgsql
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or private.caller_role_in(p_org) not in ('admin','manager','supervisor') then raise exception 'not_authorized'; end if;
  if not private.can_see_owner(p_org, p_user_id) then raise exception 'not_authorized'; end if;
  if p_target_amount is null or p_target_amount < 0 or p_target_amount > 999999999999 then raise exception 'invalid_amount'; end if;
  if not exists (select 1 from public.organization_memberships m where m.organization_id = p_org and m.user_id = p_user_id and m.status = 'active') then raise exception 'membership_not_found'; end if;
  insert into public.seller_goals (organization_id, user_id, month, target_amount, updated_by)
  values (p_org, p_user_id, date_trunc('month', p_month)::date, round(p_target_amount, 2), auth.uid())
  on conflict (organization_id, user_id, month) do update set target_amount = excluded.target_amount, updated_at = now(), updated_by = auth.uid();
end
$$;

revoke all on function public.set_seller_goal(uuid, uuid, date, numeric) from public, anon;
grant execute on function public.set_seller_goal(uuid, uuid, date, numeric) to authenticated;

-- Goal progress for the month: released amount of proposals paid in the month, attributed to the seller's user
-- (seller binding, else creator). Returns only people the caller may see.
create or replace function public.goal_progress(p_org uuid, p_month date)
returns table (user_id uuid, target_amount numeric, paid_amount numeric, paid_count int)
language sql
stable
security definer
set search_path to ''
as $$
  with month as (select date_trunc('month', p_month) as start, date_trunc('month', p_month) + interval '1 month' as stop),
  paid as (
    select private.proposal_owner(p.organization_id, p.seller_id, p.created_by) as owner, coalesce(p.released_amount, p.requested_amount, 0) as amount
    from public.proposals_v2 p
    join public.operational_cases c on c.proposal_id = p.id and c.organization_id = p.organization_id
    cross join month
    where p.organization_id = p_org and p.status = 'paid' and c.canonical_state = 'paid'
      and c.entered_stage_at >= month.start and c.entered_stage_at < month.stop
  ),
  people as (
    select g.user_id from public.seller_goals g, month where g.organization_id = p_org and g.month = month.start::date
    union select owner from paid where owner is not null
  )
  select pe.user_id,
         coalesce((select g.target_amount from public.seller_goals g, month where g.organization_id = p_org and g.user_id = pe.user_id and g.month = month.start::date), 0),
         coalesce((select sum(pd.amount) from paid pd where pd.owner = pe.user_id), 0),
         coalesce((select count(*) from paid pd where pd.owner = pe.user_id), 0)::int
  from people pe
  where public.is_active_organization_member(p_org) and private.can_see_owner(p_org, pe.user_id)
$$;

revoke all on function public.goal_progress(uuid, date) from public, anon;
grant execute on function public.goal_progress(uuid, date) to authenticated;
