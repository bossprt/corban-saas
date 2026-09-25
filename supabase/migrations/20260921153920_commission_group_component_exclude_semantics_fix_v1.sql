-- CORBAN OS — Commission group component exclude semantics fix V1
-- Same authorized component-limit wave.
-- A table/rule may choose not to repass a component even when the group ceiling is > 0.

create or replace function public.guard_component_payout_group_limit()
returns trigger
language plpgsql
set search_path=''
as $$
declare
  v_limit numeric;
begin
  if new.mode='direct' then
    raise exception 'commission_group_direct_component_mode_forbidden';
  end if;

  select l.max_received_share_pct into v_limit
  from public.commission_group_component_limits l
  join public.commission_component_types t
    on t.id=l.component_type_id and t.is_active
  where l.organization_id=new.organization_id
    and l.group_id=new.group_id
    and l.component_type_id=new.component_type_id;

  if v_limit is null then
    raise exception 'commission_group_component_not_configured';
  end if;

  -- A specific table/rule may always choose to repass nothing.
  if new.mode='exclude' then
    return new;
  end if;

  if new.mode<>'share_of_received'
     or new.share_pct is null
     or new.share_pct<0
     or new.share_pct>v_limit then
    raise exception 'commission_group_component_share_exceeds_limit';
  end if;

  return new;
end
$$;

revoke all on function public.guard_component_payout_group_limit() from public,anon,authenticated;
