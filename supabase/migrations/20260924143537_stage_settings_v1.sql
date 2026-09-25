-- F3 step 2: companies edit their pipeline stages (name, order, time limit, active) through a governed RPC.
-- A stage keeps its canonical state (money and reporting rules depend on it); the last active stage of a state
-- cannot be switched off, and a stage holding open proposals cannot be switched off either.

create or replace function public.guard_operational_stage_identity()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id
     or new.code is distinct from old.code or new.canonical_state is distinct from old.canonical_state then
    raise exception 'operational_stage_identity_immutable';
  end if;
  new.updated_at := now();
  return new;
end
$$;

revoke all on function public.guard_operational_stage_identity() from public, anon, authenticated;

create trigger operational_stages_00_identity
  before update on public.operational_stages
  for each row execute function public.guard_operational_stage_identity();

create or replace function public.update_operational_stage(p_stage_id uuid, p_name text, p_sort_order int, p_sla_minutes int, p_is_active boolean)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare s public.operational_stages%rowtype;
begin
  select * into s from public.operational_stages where id = p_stage_id for update;
  if not found or auth.uid() is null or private.caller_role_in(s.organization_id) not in ('admin','manager') then raise exception 'not_authorized'; end if;
  if p_name is null or length(btrim(p_name)) not between 2 and 60 then raise exception 'invalid_stage_name'; end if;
  if p_sort_order is null or p_sort_order < 0 or p_sort_order > 10000 then raise exception 'invalid_stage_order'; end if;
  if p_sla_minutes is not null and (p_sla_minutes < 0 or p_sla_minutes > 525600) then raise exception 'invalid_stage_sla'; end if;
  if s.is_active and not coalesce(p_is_active, true) then
    if not exists (select 1 from public.operational_stages x where x.organization_id = s.organization_id and x.canonical_state = s.canonical_state and x.is_active and x.id <> s.id) then
      raise exception 'last_stage_of_state';
    end if;
    if exists (select 1 from public.operational_cases c where c.organization_id = s.organization_id and c.current_stage_id = s.id) then
      raise exception 'stage_in_use';
    end if;
  end if;
  update public.operational_stages
  set name = btrim(p_name), sort_order = p_sort_order, sla_minutes = p_sla_minutes, is_active = coalesce(p_is_active, true)
  where id = s.id;
end
$$;

revoke all on function public.update_operational_stage(uuid, text, int, int, boolean) from public, anon;
grant execute on function public.update_operational_stage(uuid, text, int, int, boolean) to authenticated;
