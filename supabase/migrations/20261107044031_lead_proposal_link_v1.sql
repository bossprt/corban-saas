-- Sale closed in the CRM (audit 06/11/2026, fluxo Vendas -> Esteira):
-- 1. The proposal created from a lead remembers that lead (proposals_v2.origin_lead_id, nullable, set once at creation).
-- 2. private.leads_follow_proposal: a proposal with an origin lead moves only that lead (and points it at this proposal),
--    instead of every open lead of the same client. Proposals without an origin lead (all old rows, Nova proposta,
--    imports) keep the previous behaviour: open leads of the client follow it.
-- 3. public.close_lead_sale: "Venda fechada" from the lead. Same proposal as create_proposal_from_simulation, plus the
--    seller (the one chosen in the close dialog, else the seller linked to the lead's owner, else the seller linked to the
--    closing user; none -> seller_required so the screen asks) and the origin lead. With a seller the commission is
--    calculated on insert (proposals_v2_90_auto_calculate), as for a proposal typed in the Esteira.
-- Contract: tests/security/lead-proposal-link-contract.sql

alter table public.proposals_v2 add column if not exists origin_lead_id uuid;
comment on column public.proposals_v2.origin_lead_id is 'Lead whose "Venda fechada" created this proposal (null for older rows and other origins). Set once.';
create index if not exists proposals_v2_origin_lead_idx on public.proposals_v2 (organization_id, origin_lead_id) where origin_lead_id is not null;

-- The origin lead is part of the proposal's identity: never changed after creation.
create or replace function private.guard_proposal_origin_lead()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.origin_lead_id is distinct from old.origin_lead_id then raise exception 'proposal_origin_lead_is_immutable'; end if;
  return new;
end $$;
revoke all on function private.guard_proposal_origin_lead() from public, anon, authenticated;
drop trigger if exists proposals_v2_05_origin_lead_immutable on public.proposals_v2;
create trigger proposals_v2_05_origin_lead_immutable before update of origin_lead_id on public.proposals_v2
  for each row execute function private.guard_proposal_origin_lead();

create or replace function private.leads_follow_proposal()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.origin_lead_id is not null then
      -- Created from a lead: that lead follows this proposal (even if it was following an older one).
      with moved as (
        update public.leads l set status = 'proposal', proposal_id = new.id,
               stage_changed_at = case when l.status = 'proposal' then l.stage_changed_at else now() end, updated_at = now()
        where l.organization_id = new.organization_id and l.id = new.origin_lead_id and l.status in ('new', 'contacted', 'negotiating', 'proposal')
        returning l.id, l.organization_id)
      insert into public.lead_events (organization_id, lead_id, event_type, to_status, actor_user_id, detail)
      select organization_id, id, 'proposal_linked', 'proposal', (select auth.uid()), jsonb_build_object('proposal_id', new.id) from moved;
    else
      with moved as (
        update public.leads l set status = 'proposal', proposal_id = new.id, stage_changed_at = now(), updated_at = now()
        where l.organization_id = new.organization_id and l.customer_id = new.customer_id and l.status in ('new', 'contacted', 'negotiating')
        returning l.id, l.organization_id)
      insert into public.lead_events (organization_id, lead_id, event_type, to_status, actor_user_id, detail)
      select organization_id, id, 'proposal_linked', 'proposal', (select auth.uid()), jsonb_build_object('proposal_id', new.id) from moved;
    end if;
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

-- Invoker, like create_proposal_from_simulation: RLS still decides which lead, simulation, client and seller the caller sees.
create or replace function public.close_lead_sale(p_lead uuid, p_simulation uuid, p_seller uuid default null)
returns uuid language plpgsql set search_path to '' as $function$
declare
  l public.leads%rowtype;
  v_sim public.simulations%rowtype;
  v_customer public.clients%rowtype;
  v_version public.product_table_versions%rowtype;
  v_table public.product_tables%rowtype;
  v_org uuid;
  v_seller uuid;
  v_proposal_id uuid;
  v_pricing_at timestamptz;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into l from public.leads x where x.id = p_lead;
  if l.id is null or not public.is_active_organization_member(l.organization_id)
     or not private.can_see_owner(l.organization_id, coalesce(l.owner_user_id, l.created_by)) then raise exception 'lead_not_found'; end if;
  v_org := l.organization_id;

  select s.* into v_sim from public.simulations s where s.id = p_simulation and s.organization_id = v_org for update;
  if v_sim.id is null then raise exception 'simulation_not_found_or_forbidden'; end if;
  if l.customer_id is null or v_sim.customer_id is distinct from l.customer_id then raise exception 'simulation_not_of_lead_client'; end if;
  if v_sim.status <> 'calculated' then raise exception 'simulation_not_available_for_proposal'; end if;

  -- The seller: chosen in the close dialog, else the lead's owner, else whoever closes the sale (when they are a seller).
  if p_seller is not null then
    if not exists (select 1 from public.commercial_sellers s where s.organization_id = v_org and s.id = p_seller and s.is_active) then
      raise exception 'seller_not_found';
    end if;
    v_seller := p_seller;
  else
    select s.id into v_seller from public.commercial_sellers s
    where s.organization_id = v_org and s.is_active and l.owner_user_id is not null and s.user_id = l.owner_user_id order by s.created_at limit 1;
    if v_seller is null then
      select s.id into v_seller from public.commercial_sellers s
      where s.organization_id = v_org and s.is_active and s.user_id = auth.uid() order by s.created_at limit 1;
    end if;
    if v_seller is null then raise exception 'seller_required'; end if;
  end if;

  v_pricing_at := coalesce(nullif(v_sim.input_snapshot->>'pricing_effective_at', '')::timestamptz, v_sim.created_at);
  select c.* into v_customer from public.clients c where c.organization_id = v_org and c.id = v_sim.customer_id and c.deleted_at is null;
  if v_customer.id is null then raise exception 'customer_not_available'; end if;

  -- Validated against the instant of the simulation, never against today's pricing (as create_proposal_from_simulation).
  select v.* into v_version from public.product_table_versions v
  where v.organization_id = v_org and v.id = v_sim.product_table_version_id and v.status in ('published', 'superseded')
    and coalesce(v.effective_from, v.published_at, v.created_at) <= v_pricing_at
    and (v.effective_until is null or v_pricing_at < v.effective_until);
  if v_version.id is null then raise exception 'simulation_pricing_version_not_available'; end if;
  select pt.* into v_table from public.product_tables pt where pt.organization_id = v_org and pt.id = v_version.product_table_id;
  if v_table.id is null then raise exception 'product_table_not_available'; end if;

  perform set_config('corban.proposal_rpc', 'on', true);
  insert into public.proposals_v2(
    organization_id, customer_id, simulation_id, product_table_version_id, status,
    requested_amount, released_amount, installment_amount, term, rate, coefficient,
    customer_snapshot, commercial_snapshot, attribution_snapshot, created_by, contract_type_id, seller_id, origin_lead_id
  ) values (
    v_org, v_customer.id, v_sim.id, v_version.id, 'draft',
    v_sim.requested_amount, v_sim.released_amount, v_sim.installment_amount, v_sim.term, v_sim.rate, v_sim.coefficient,
    jsonb_build_object('full_name', v_customer.full_name, 'cpf', v_customer.cpf, 'phone', v_customer.phone, 'email', v_customer.email),
    jsonb_build_object(
      'pricing_effective_at', v_pricing_at,
      'product_table', jsonb_build_object('id', v_table.id, 'code', v_table.code, 'name', v_table.name),
      'table_version', jsonb_build_object('id', v_version.id, 'version', v_version.version, 'effective_from', v_version.effective_from,
                                          'effective_until', v_version.effective_until, 'rate', v_version.rate, 'coefficient', v_version.coefficient)),
    jsonb_build_object('original_source', v_customer.original_source, 'lead_id', l.id),
    auth.uid(),
    (select ct.id from public.contract_types ct where ct.id = nullif(v_sim.input_snapshot->>'contract_type_id', '')::uuid
       and (ct.organization_id is null or ct.organization_id = v_org)),
    v_seller, l.id
  ) returning id into v_proposal_id;
  perform set_config('corban.proposal_rpc', 'off', true);

  perform set_config('corban.simulation_rpc', 'on', true);
  update public.simulations set status = 'selected', updated_at = now() where organization_id = v_org and id = v_sim.id;
  perform set_config('corban.simulation_rpc', 'off', true);

  return v_proposal_id;
exception when others then
  perform set_config('corban.proposal_rpc', 'off', true);
  perform set_config('corban.simulation_rpc', 'off', true);
  raise;
end
$function$;

revoke all on function public.close_lead_sale(uuid, uuid, uuid) from public, anon;
grant execute on function public.close_lead_sale(uuid, uuid, uuid) to authenticated;
