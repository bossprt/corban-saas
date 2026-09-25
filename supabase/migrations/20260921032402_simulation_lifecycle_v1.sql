-- CORBAN OS — Simulation lifecycle V1
-- PREPARED ONLY. Requires explicit Human Gate before LIVE apply.
-- Fail-closed lifecycle for terminal simulation states.

create or replace function public.guard_simulation_selected_immutable()
returns trigger
language plpgsql
set search_path=''
as $$
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
       or new.expected_commission_amount is distinct from old.expected_commission_amount
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
$$;

revoke all on function public.guard_simulation_selected_immutable() from public,anon,authenticated;

create or replace function public.close_simulation(
  p_simulation_id uuid,
  p_target_status text
)
returns uuid
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_sim public.simulations%rowtype;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if p_target_status not in ('cancelled','expired') then raise exception 'invalid_target_status'; end if;

  select s.* into v_sim
  from public.simulations s
  where s.id=p_simulation_id
    and public.is_active_organization_member(s.organization_id)
  for update;

  if v_sim.id is null then raise exception 'simulation_not_found_or_forbidden'; end if;
  if not public.has_active_organization_role(v_sim.organization_id,array['admin','manager','supervisor']) then
    raise exception 'forbidden';
  end if;
  if v_sim.status<>'calculated' then raise exception 'simulation_not_closable'; end if;
  if exists(
    select 1 from public.proposals_v2 p
    where p.organization_id=v_sim.organization_id
      and p.simulation_id=v_sim.id
  ) then raise exception 'simulation_has_proposal'; end if;

  perform set_config('corban.simulation_rpc','on',true);
  update public.simulations
  set status=p_target_status,updated_at=now()
  where organization_id=v_sim.organization_id and id=v_sim.id;
  perform set_config('corban.simulation_rpc','off',true);

  return v_sim.id;
end
$$;

revoke all on function public.close_simulation(uuid,text) from public,anon;
grant execute on function public.close_simulation(uuid,text) to authenticated;
