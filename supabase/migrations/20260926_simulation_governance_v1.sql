-- PREPARED, NOT APPLIED. Governed write path for public.simulations. Forward-only, no data touched, no SECURITY DEFINER.
--
-- Finding (proved against the LIVE schema): any active member, including an agent, could INSERT/UPDATE simulations directly through the API
-- with arbitrary requested/installment/rate/coefficient, a forged created_by and an arbitrary expected_commission_amount. create_proposal_from_simulation
-- copies that commission into the proposal, so a forged number would have flowed into the commercial record. The app action already computed the
-- values correctly, but the database did not require it.
--
-- Rules after this migration:
--   * the ONLY way to create a simulation is public.create_simulation(customer, published table version, amount, term): tenant is DERIVED from the
--     customer row, the version must belong to that tenant and be published, rate/coefficient come from the version, the installment is computed
--     here, created_by is auth.uid(), expected_commission_amount and released_amount stay NULL (no governed source exists for them yet);
--   * direct INSERT/UPDATE/DELETE by authenticated/anon is refused by a guard trigger (GUC corban.simulation_rpc); column privileges shrink to what the
--     RPCs need (INSERT of the derived columns, UPDATE of status/updated_at);
--   * a simulation that already originated a proposal stays immutable (existing guard_simulation_selected_immutable is kept).
-- create_proposal_from_simulation is re-declared with ONE change: the status flip to 'selected' runs inside the simulation guard token.

create or replace function public.create_simulation(p_customer_id uuid, p_table_version_id uuid, p_requested_amount numeric, p_term integer)
 returns uuid language plpgsql set search_path='' as $$
declare v_customer public.clients%rowtype; v_version public.product_table_versions%rowtype; v_amount numeric; v_installment numeric; v_id uuid;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 if p_requested_amount is null or p_requested_amount<=0 or p_requested_amount>999999999 then raise exception 'invalid_amount'; end if;
 if p_term is null or p_term<=0 or p_term>600 then raise exception 'invalid_term'; end if;
 v_amount:=round(p_requested_amount,2);
 -- the customer row is visible only through the caller's RLS; the tenant is whatever that row says, never a parameter
 select c.* into v_customer from public.clients c where c.id=p_customer_id and c.deleted_at is null;
 if v_customer.id is null then raise exception 'customer_not_found_or_forbidden'; end if;
 if not public.is_active_organization_member(v_customer.organization_id) then raise exception 'not_authorized'; end if;
 select v.* into v_version from public.product_table_versions v where v.id=p_table_version_id and v.organization_id=v_customer.organization_id and v.status='published';
 if v_version.id is null then raise exception 'published_table_version_not_available'; end if;
 if v_version.term_min is not null and p_term<v_version.term_min then raise exception 'term_below_table_minimum'; end if;
 if v_version.term_max is not null and p_term>v_version.term_max then raise exception 'term_above_table_maximum'; end if;
 v_installment:=case when v_version.coefficient is not null and v_version.coefficient>0 then round(v_amount*v_version.coefficient,2) else null end;
 perform set_config('corban.simulation_rpc','on',true);
 -- table metadata is deliberately NOT copied into the snapshot: it may carry commercial terms that agents must not read
 insert into public.simulations(organization_id,customer_id,product_table_version_id,status,requested_amount,installment_amount,term,rate,coefficient,input_snapshot,result_snapshot,created_by)
 values(v_customer.organization_id,v_customer.id,v_version.id,'calculated',v_amount,v_installment,p_term,v_version.rate,v_version.coefficient,
        jsonb_build_object('requested_amount',v_amount,'term',p_term),
        jsonb_build_object('calculation',case when v_installment is null then 'manual_pending' else 'requested_amount_x_coefficient' end),
        auth.uid())
 returning id into v_id;
 perform set_config('corban.simulation_rpc','off',true);
 return v_id;
end $$;

create or replace function public.guard_simulation_write() returns trigger language plpgsql set search_path='' as $$
begin
 if current_user in ('authenticated','anon') then
  if tg_op='DELETE' then raise exception 'simulation_delete_forbidden'; end if;
  if current_setting('corban.simulation_rpc',true) is distinct from 'on' then raise exception 'simulation_write_requires_governed_rpc'; end if;
 end if;
 if tg_op='DELETE' then return old; end if;
 return new;
end $$;
create trigger simulations_00_governed_write before insert or update or delete on public.simulations for each row execute function public.guard_simulation_write();

revoke insert,update,delete on public.simulations from authenticated;
grant insert(organization_id,customer_id,product_table_version_id,status,requested_amount,installment_amount,term,rate,coefficient,input_snapshot,result_snapshot,created_by) on public.simulations to authenticated;
grant update(status,updated_at) on public.simulations to authenticated;

create or replace function public.create_proposal_from_simulation(p_simulation_id uuid)
 returns uuid language plpgsql set search_path to '' as $function$
declare
  v_org uuid; v_sim public.simulations%rowtype; v_customer public.clients%rowtype;
  v_version public.product_table_versions%rowtype; v_table public.product_tables%rowtype; v_proposal_id uuid;
begin
  select s.* into v_sim from public.simulations s
  where s.id=p_simulation_id and public.is_active_organization_member(s.organization_id) for update;
  if v_sim.id is null then raise exception 'simulation_not_found_or_forbidden'; end if;
  if v_sim.status <> 'calculated' then raise exception 'simulation_not_available_for_proposal'; end if;
  v_org := v_sim.organization_id;
  select c.* into v_customer from public.clients c where c.organization_id=v_org and c.id=v_sim.customer_id and c.deleted_at is null;
  if v_customer.id is null then raise exception 'customer_not_available'; end if;
  select v.* into v_version from public.product_table_versions v where v.organization_id=v_org and v.id=v_sim.product_table_version_id and v.status='published';
  if v_version.id is null then raise exception 'published_table_version_not_available'; end if;
  select pt.* into v_table from public.product_tables pt where pt.organization_id=v_org and pt.id=v_version.product_table_id;
  if v_table.id is null then raise exception 'product_table_not_available'; end if;
  perform set_config('corban.proposal_rpc','on',true);
  insert into public.proposals_v2 (
    organization_id, customer_id, simulation_id, product_table_version_id, status,
    requested_amount, released_amount, installment_amount, term, rate, coefficient,
    expected_commission_amount, customer_snapshot, commercial_snapshot, attribution_snapshot, created_by
  ) values (
    v_org, v_customer.id, v_sim.id, v_version.id, 'draft',
    v_sim.requested_amount, v_sim.released_amount, v_sim.installment_amount,
    v_sim.term, v_sim.rate, v_sim.coefficient, v_sim.expected_commission_amount,
    jsonb_build_object('full_name', v_customer.full_name, 'cpf', v_customer.cpf, 'phone', v_customer.phone, 'email', v_customer.email),
    jsonb_build_object(
      'product_table', jsonb_build_object('id',v_table.id,'code',v_table.code,'name',v_table.name),
      'table_version', jsonb_build_object('id',v_version.id,'version',v_version.version,'rate',v_version.rate,'coefficient',v_version.coefficient)),
    jsonb_build_object('original_source', v_customer.original_source),
    auth.uid()
  ) returning id into v_proposal_id;
  perform set_config('corban.proposal_rpc','off',true);
  perform set_config('corban.simulation_rpc','on',true);
  update public.simulations set status='selected', updated_at=now() where organization_id=v_org and id=v_sim.id;
  perform set_config('corban.simulation_rpc','off',true);
  return v_proposal_id;
end;
$function$;

revoke all on function public.guard_simulation_write() from public,anon,authenticated;
revoke all on function public.create_simulation(uuid,uuid,numeric,integer) from public,anon;
grant execute on function public.create_simulation(uuid,uuid,numeric,integer) to authenticated;
