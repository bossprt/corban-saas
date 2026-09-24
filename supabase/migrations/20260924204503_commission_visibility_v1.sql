-- Commission visibility (owner decision, ADR-0031): a seller sees only their own share, and only on their own proposals.
--
-- 1. The calculation header (percentages of company profit, tax, manager, supervisor, originator and group share) is
--    read only with financeiro.view. Before, the originator could read it through the API and derive what the company
--    received from the bank.
-- 2. The originator reads their own 'originator' lines, by the frozen login or by the seller record (so a seller who
--    got a login after the calculation still sees it), and proposal_commission_mine() gives the screen that view.
-- 3. The ChatGPT-era column expected_commission_amount (proposals_v2, simulations) is removed: readable by any member,
--    empty in production (0 rows), used by no screen. Owner-approved removal.

-- 1-2. Visibility ---------------------------------------------------------------------------------------------------------

create or replace function private.is_commission_originator(p_calc uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
    select 1 from public.proposal_commission_calcs c
    left join public.commercial_sellers s on s.organization_id = c.organization_id and s.id = c.seller_id
    where c.id = p_calc
      and (c.originator_user_id = auth.uid() or s.user_id = auth.uid())
      and public.is_active_organization_member(c.organization_id))
$$;

revoke all on function private.is_commission_originator(uuid) from public, anon;
grant execute on function private.is_commission_originator(uuid) to authenticated;

drop policy proposal_commission_calcs_select on public.proposal_commission_calcs;
create policy proposal_commission_calcs_select on public.proposal_commission_calcs for select to authenticated
  using (public.is_active_organization_member(organization_id)
         and exists (select 1 from public.proposals_v2 p where p.id = proposal_id)
         and public.has_permission(organization_id, 'financeiro.view'));

drop policy proposal_commission_lines_select on public.proposal_commission_lines;
create policy proposal_commission_lines_select on public.proposal_commission_lines for select to authenticated
  using ((public.has_permission(organization_id, 'financeiro.view') and exists (select 1 from public.proposal_commission_calcs c where c.id = calc_id))
         or (line_kind = 'originator' and private.is_commission_originator(calc_id)));

-- The proposal screen for someone without finance access: whether the commission is calculated and, for the seller of
-- the proposal, their own lines. Amounts go out as exact decimal text.
create or replace function public.proposal_commission_mine(p_proposal uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare p public.proposals_v2%rowtype; c public.proposal_commission_calcs%rowtype;
begin
  select * into p from public.proposals_v2 where id = p_proposal;
  if p.id is null or auth.uid() is null or not public.is_active_organization_member(p.organization_id)
     or not private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by) then
    raise exception 'not_authorized';
  end if;
  select * into c from public.proposal_commission_calcs where proposal_id = p.id and status = 'active';
  if c.id is null then return jsonb_build_object('calculated', false); end if;
  if not private.is_commission_originator(c.id) then
    return jsonb_build_object('calculated', true, 'calculated_at', c.calculated_at, 'mine', false);
  end if;
  return jsonb_build_object('calculated', true, 'calculated_at', c.calculated_at, 'mine', true, 'lines',
    coalesce((select jsonb_agg(jsonb_build_object('component_key', l.component_key, 'part', l.part, 'multiplier', l.multiplier, 'amount', l.amount::text)
                               order by l.component_key, l.part)
              from public.proposal_commission_lines l where l.calc_id = c.id and l.line_kind = 'originator'), '[]'::jsonb));
end
$$;

revoke all on function public.proposal_commission_mine(uuid) from public, anon;
grant execute on function public.proposal_commission_mine(uuid) to authenticated;

-- 3. Remove expected_commission_amount -------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.guard_proposal_commercial_snapshot()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op='INSERT'
     or (tg_op='UPDATE' and old.status='draft'
         and new.product_table_version_id is distinct from old.product_table_version_id) then
    if not exists(
      select 1 from public.product_table_versions v
      where v.organization_id=new.organization_id
        and v.id=new.product_table_version_id
        and v.status='published'
    ) then
      raise exception 'proposal_requires_published_product_table_version';
    end if;
  end if;

  if tg_op='UPDATE' and old.status<>'draft' then
    if new.status='draft' then raise exception 'proposal_cannot_return_to_draft'; end if;
    if new.organization_id is distinct from old.organization_id
       or new.customer_id is distinct from old.customer_id
       or new.simulation_id is distinct from old.simulation_id
       or new.product_table_version_id is distinct from old.product_table_version_id
       or new.seller_id is distinct from old.seller_id
       or new.requested_amount is distinct from old.requested_amount
       or new.released_amount is distinct from old.released_amount
       or new.installment_amount is distinct from old.installment_amount
       or new.term is distinct from old.term
       or new.rate is distinct from old.rate
       or new.coefficient is distinct from old.coefficient
       or new.customer_snapshot is distinct from old.customer_snapshot
       or new.commercial_snapshot is distinct from old.commercial_snapshot
       or new.attribution_snapshot is distinct from old.attribution_snapshot
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'proposal_commercial_snapshot_is_immutable_after_draft';
    end if;
  end if;
  return new;
end
$function$;

CREATE OR REPLACE FUNCTION public.create_proposal_from_simulation(p_simulation_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_org uuid;
  v_sim public.simulations%rowtype;
  v_customer public.clients%rowtype;
  v_version public.product_table_versions%rowtype;
  v_table public.product_tables%rowtype;
  v_proposal_id uuid;
  v_pricing_at timestamptz;
begin
  select s.* into v_sim
  from public.simulations s
  where s.id=p_simulation_id
    and public.is_active_organization_member(s.organization_id)
  for update;

  if v_sim.id is null then raise exception 'simulation_not_found_or_forbidden'; end if;
  if v_sim.status<>'calculated' then raise exception 'simulation_not_available_for_proposal'; end if;

  v_org:=v_sim.organization_id;
  v_pricing_at:=coalesce(
    nullif(v_sim.input_snapshot->>'pricing_effective_at','')::timestamptz,
    v_sim.created_at
  );

  select c.* into v_customer
  from public.clients c
  where c.organization_id=v_org and c.id=v_sim.customer_id and c.deleted_at is null;
  if v_customer.id is null then raise exception 'customer_not_available'; end if;

  -- The version is validated against the instant when the simulation was created,
  -- never against today's pricing.
  select v.* into v_version
  from public.product_table_versions v
  where v.organization_id=v_org
    and v.id=v_sim.product_table_version_id
    and v.status in ('published','superseded')
    and coalesce(v.effective_from,v.published_at,v.created_at)<=v_pricing_at
    and (v.effective_until is null or v_pricing_at<v.effective_until);

  if v_version.id is null then raise exception 'simulation_pricing_version_not_available'; end if;

  select pt.* into v_table
  from public.product_tables pt
  where pt.organization_id=v_org and pt.id=v_version.product_table_id;
  if v_table.id is null then raise exception 'product_table_not_available'; end if;

  perform set_config('corban.proposal_rpc','on',true);
  insert into public.proposals_v2(
    organization_id,customer_id,simulation_id,product_table_version_id,status,
    requested_amount,released_amount,installment_amount,term,rate,coefficient,
    customer_snapshot,commercial_snapshot,attribution_snapshot,created_by
  ) values(
    v_org,v_customer.id,v_sim.id,v_version.id,'draft',
    v_sim.requested_amount,v_sim.released_amount,v_sim.installment_amount,
    v_sim.term,v_sim.rate,v_sim.coefficient,
    jsonb_build_object(
      'full_name',v_customer.full_name,'cpf',v_customer.cpf,
      'phone',v_customer.phone,'email',v_customer.email
    ),
    jsonb_build_object(
      'pricing_effective_at',v_pricing_at,
      'product_table',jsonb_build_object('id',v_table.id,'code',v_table.code,'name',v_table.name),
      'table_version',jsonb_build_object(
        'id',v_version.id,'version',v_version.version,
        'effective_from',v_version.effective_from,'effective_until',v_version.effective_until,
        'rate',v_version.rate,'coefficient',v_version.coefficient
      )
    ),
    jsonb_build_object('original_source',v_customer.original_source),
    auth.uid()
  ) returning id into v_proposal_id;
  perform set_config('corban.proposal_rpc','off',true);

  perform set_config('corban.simulation_rpc','on',true);
  update public.simulations
  set status='selected',updated_at=now()
  where organization_id=v_org and id=v_sim.id;
  perform set_config('corban.simulation_rpc','off',true);

  return v_proposal_id;
exception when others then
  perform set_config('corban.proposal_rpc','off',true);
  perform set_config('corban.simulation_rpc','off',true);
  raise;
end
$function$;

CREATE OR REPLACE FUNCTION public.guard_simulation_selected_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if old.status in ('selected','expired','cancelled') then
    if new.organization_id is distinct from old.organization_id
       or new.customer_id is distinct from old.customer_id
       or new.product_table_version_id is distinct from old.product_table_version_id
       or new.requested_amount is distinct from old.requested_amount
       or new.released_amount is distinct from old.released_amount
       or new.installment_amount is distinct from old.installment_amount
       or new.term is distinct from old.term
       or new.rate is distinct from old.rate
       or new.coefficient is distinct from old.coefficient
       or new.input_snapshot is distinct from old.input_snapshot
       or new.result_snapshot is distinct from old.result_snapshot
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'selected_simulation_snapshot_is_immutable';
    end if;
  end if;

  if old.status='selected' and new.status is distinct from old.status then
    raise exception 'selected_simulation_is_terminal';
  end if;
  if old.status in ('expired','cancelled') and new.status is distinct from old.status then
    raise exception 'terminal_simulation_status';
  end if;
  return new;
end
$function$;

alter table public.proposals_v2 drop constraint proposals_v2_amounts_check;
alter table public.simulations drop constraint simulations_amounts_check;
alter table public.proposals_v2 drop column expected_commission_amount;
alter table public.simulations drop column expected_commission_amount;
alter table public.proposals_v2 add constraint proposals_v2_amounts_check check (
  (requested_amount is null or requested_amount >= 0) and (released_amount is null or released_amount >= 0)
  and (installment_amount is null or installment_amount >= 0));
alter table public.simulations add constraint simulations_amounts_check check (
  (requested_amount is null or requested_amount >= 0) and (released_amount is null or released_amount >= 0)
  and (installment_amount is null or installment_amount >= 0));
