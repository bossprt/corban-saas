-- CORBAN OS — Commission group payout ceiling V1
-- PREPARED ONLY. Requires explicit Human Gate before LIVE apply.
-- A commission group defines a maximum share of what the organization received.

alter table public.commission_groups
  add column max_received_share_pct numeric(9,6) not null default 100
  check (max_received_share_pct >= 0 and max_received_share_pct <= 100);

comment on column public.commission_groups.max_received_share_pct is
  'Maximum percentage of the commission received by the organization that may be repassed to this group.';

update public.commission_groups
set calculation_basis='percent_of_received_commission'
where calculation_basis<>'percent_of_received_commission';

alter table public.commission_groups
  alter column calculation_basis set default 'percent_of_received_commission';

create or replace function public.guard_commission_group_received_basis()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if new.calculation_basis is distinct from 'percent_of_received_commission' then
    raise exception 'commission_group_received_basis_required';
  end if;
  if new.max_received_share_pct is null
     or new.max_received_share_pct<0
     or new.max_received_share_pct>100 then
    raise exception 'commission_group_limit_invalid';
  end if;
  return new;
end
$$;

drop trigger if exists commission_groups_20_received_basis_guard on public.commission_groups;
create trigger commission_groups_20_received_basis_guard
before insert or update on public.commission_groups
for each row execute function public.guard_commission_group_received_basis();

revoke all on function public.guard_commission_group_received_basis() from public,anon,authenticated;

create or replace function public.assert_commission_group_share_within_limit(
  p_organization uuid,
  p_group uuid,
  p_share numeric
)
returns void
language plpgsql
stable
security invoker
set search_path=''
as $$
declare
  v_limit numeric;
begin
  if p_share is null or p_share<0 or p_share>100 then
    raise exception 'invalid_shares';
  end if;

  select g.max_received_share_pct into v_limit
  from public.commission_groups g
  where g.organization_id=p_organization
    and g.id=p_group
    and g.is_active
    and g.calculation_basis='percent_of_received_commission';

  if v_limit is null then
    raise exception 'commission_group_not_found';
  end if;

  if p_share>v_limit then
    raise exception 'commission_group_share_exceeds_limit';
  end if;
end
$$;

revoke all on function public.assert_commission_group_share_within_limit(uuid,uuid,numeric) from public,anon;
grant execute on function public.assert_commission_group_share_within_limit(uuid,uuid,numeric) to authenticated;


create or replace function public.guard_commission_share_limit()
returns trigger
language plpgsql
set search_path=''
as $$
declare
  v_pct numeric;
begin
  if tg_table_name='commercial_condition_shares' then
    v_pct:=new.share_pct;
  elsif tg_table_name='payout_policy_items' then
    v_pct:=new.pct;
  elsif tg_table_name='component_payout_policy_items' then
    if new.mode<>'share_of_received' then
      return new;
    end if;
    v_pct:=new.share_pct;
  else
    raise exception 'unsupported_commission_share_table';
  end if;

  perform public.assert_commission_group_share_within_limit(
    new.organization_id,
    new.group_id,
    v_pct
  );

  return new;
end
$$;

revoke all on function public.guard_commission_share_limit() from public,anon,authenticated;

drop trigger if exists commercial_condition_shares_15_group_limit on public.commercial_condition_shares;
create trigger commercial_condition_shares_15_group_limit
before insert or update of share_pct,group_id,organization_id
on public.commercial_condition_shares
for each row execute function public.guard_commission_share_limit();

drop trigger if exists payout_policy_items_15_group_limit on public.payout_policy_items;
create trigger payout_policy_items_15_group_limit
before insert or update of pct,group_id,organization_id
on public.payout_policy_items
for each row execute function public.guard_commission_share_limit();

drop trigger if exists component_payout_policy_items_15_group_limit on public.component_payout_policy_items;
create trigger component_payout_policy_items_15_group_limit
before insert or update of share_pct,mode,group_id,organization_id
on public.component_payout_policy_items
for each row execute function public.guard_commission_share_limit();
