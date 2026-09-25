-- CORBAN OS — Seller commission visibility scope V1
-- PREPARED ONLY. Requires explicit Human Gate before LIVE apply.
-- Owner policy:
-- - seller/user sees only own frozen seller commission;
-- - admin/manager see all seller commissions;
-- - supervisor sees only sellers explicitly supervised;
-- - company financial truth remains separate from seller commission.

alter table public.commercial_sellers
  add column user_id uuid;

alter table public.commercial_sellers
  add constraint commercial_sellers_org_user_fk
  foreign key (organization_id,user_id)
  references public.organization_memberships(organization_id,user_id)
  on delete restrict;

create unique index commercial_sellers_org_user_key
  on public.commercial_sellers(organization_id,user_id)
  where user_id is not null;

create table public.seller_supervisions(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  supervisor_user_id uuid not null,
  seller_id uuid not null,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id,id),
  unique (organization_id,supervisor_user_id,seller_id),
  foreign key (organization_id,supervisor_user_id)
    references public.organization_memberships(organization_id,user_id) on delete restrict,
  foreign key (organization_id,seller_id)
    references public.commercial_sellers(organization_id,id) on delete restrict
);

create index seller_supervisions_supervisor_idx
  on public.seller_supervisions(organization_id,supervisor_user_id)
  where is_active;
create index seller_supervisions_seller_idx
  on public.seller_supervisions(organization_id,seller_id)
  where is_active;

create or replace function public.guard_seller_supervision()
returns trigger
language plpgsql
set search_path=''
as $$
declare
  v_role text;
  v_status text;
begin
  if tg_op='DELETE' then raise exception 'seller_supervision_delete_forbidden'; end if;

  select m.role,m.status into v_role,v_status
  from public.organization_memberships m
  where m.organization_id=new.organization_id
    and m.user_id=new.supervisor_user_id;

  if v_role is distinct from 'supervisor' or v_status is distinct from 'active' then
    raise exception 'active_supervisor_membership_required';
  end if;

  if not exists(
    select 1 from public.commercial_sellers s
    where s.organization_id=new.organization_id
      and s.id=new.seller_id
      and s.is_active
  ) then
    raise exception 'active_seller_required';
  end if;

  if tg_op='INSERT' then
    if current_user in ('authenticated','anon') then new.created_by:=auth.uid(); end if;
    new.updated_by:=new.created_by;
  else
    if new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.supervisor_user_id is distinct from old.supervisor_user_id
       or new.seller_id is distinct from old.seller_id
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at
    then raise exception 'seller_supervision_identity_is_immutable'; end if;
    if current_user in ('authenticated','anon') then new.updated_by:=auth.uid(); end if;
    new.updated_at:=now();
  end if;

  return new;
end
$$;

create trigger seller_supervisions_00_guard
before insert or update or delete on public.seller_supervisions
for each row execute function public.guard_seller_supervision();

create or replace function public.set_seller_user(
  p_seller_id uuid,
  p_user_id uuid
)
returns uuid
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_org uuid;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;

  select s.organization_id into v_org
  from public.commercial_sellers s
  where s.id=p_seller_id
  for update;

  if v_org is null then raise exception 'seller_not_found'; end if;
  if not public.has_active_organization_role(v_org,array['admin','manager']) then
    raise exception 'forbidden';
  end if;

  if p_user_id is not null and not exists(
    select 1 from public.organization_memberships m
    where m.organization_id=v_org
      and m.user_id=p_user_id
      and m.status='active'
  ) then raise exception 'active_membership_required'; end if;

  update public.commercial_sellers
  set user_id=p_user_id,updated_at=now()
  where organization_id=v_org and id=p_seller_id;

  insert into public.organization_admin_events(
    organization_id,actor_user_id,event_type,target_user_id,details
  ) values(
    v_org,auth.uid(),'seller_user_binding_updated',p_user_id,
    jsonb_build_object('seller_id',p_seller_id,'bound_user_id',p_user_id)
  );

  return p_seller_id;
end
$$;

create or replace function public.set_seller_supervision(
  p_seller_id uuid,
  p_supervisor_user_id uuid,
  p_active boolean default true
)
returns uuid
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_org uuid;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;

  select s.organization_id into v_org
  from public.commercial_sellers s
  where s.id=p_seller_id;

  if v_org is null then raise exception 'seller_not_found'; end if;
  if not public.has_active_organization_role(v_org,array['admin','manager']) then
    raise exception 'forbidden';
  end if;

  if not exists(
    select 1 from public.organization_memberships m
    where m.organization_id=v_org
      and m.user_id=p_supervisor_user_id
      and m.role='supervisor'
      and m.status='active'
  ) then raise exception 'active_supervisor_membership_required'; end if;

  insert into public.seller_supervisions(
    organization_id,supervisor_user_id,seller_id,is_active,created_by,updated_by
  ) values(
    v_org,p_supervisor_user_id,p_seller_id,coalesce(p_active,true),auth.uid(),auth.uid()
  )
  on conflict(organization_id,supervisor_user_id,seller_id)
  do update set is_active=excluded.is_active,updated_by=auth.uid(),updated_at=now()
  returning id into v_id;

  insert into public.organization_admin_events(
    organization_id,actor_user_id,event_type,target_user_id,details
  ) values(
    v_org,auth.uid(),'seller_supervision_updated',p_supervisor_user_id,
    jsonb_build_object('seller_id',p_seller_id,'active',coalesce(p_active,true))
  );

  return v_id;
end
$$;

create or replace function public.can_view_seller_commission(
  p_organization_id uuid,
  p_seller_id uuid
)
returns boolean
language sql
stable
security invoker
set search_path=''
as $$
  select
    public.has_active_organization_role(p_organization_id,array['admin','manager'])
    or exists(
      select 1
      from public.commercial_sellers s
      join public.organization_memberships m
        on m.organization_id=s.organization_id
       and m.user_id=s.user_id
       and m.status='active'
      where s.organization_id=p_organization_id
        and s.id=p_seller_id
        and s.is_active
        and s.user_id=auth.uid()
    )
    or (
      public.has_active_organization_role(p_organization_id,array['supervisor'])
      and exists(
        select 1 from public.seller_supervisions ss
        where ss.organization_id=p_organization_id
          and ss.seller_id=p_seller_id
          and ss.supervisor_user_id=auth.uid()
          and ss.is_active
      )
    )
$$;

create table public.proposal_seller_commission_snapshots(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  proposal_id uuid not null,
  seller_id uuid not null,
  commission_group_id uuid not null,
  calculation_status text not null check (calculation_status in ('calculated','unavailable')),
  source_kind text not null check (source_kind in ('condition_group_share','unavailable')),
  calculation_base numeric(18,2),
  effective_pct numeric(18,8),
  amount numeric(18,2),
  currency text not null default 'BRL' check (currency='BRL'),
  condition_id uuid,
  policy_version_id uuid,
  reason text,
  snapshot jsonb not null default '{}'::jsonb,
  frozen_at timestamptz not null default now(),
  unique (organization_id,id),
  unique (proposal_id,seller_id),
  foreign key (organization_id,proposal_id)
    references public.proposals_v2(organization_id,id) on delete restrict,
  foreign key (organization_id,seller_id)
    references public.commercial_sellers(organization_id,id) on delete restrict,
  foreign key (organization_id,commission_group_id)
    references public.commission_groups(organization_id,id) on delete restrict,
  check (
    (calculation_status='calculated' and amount is not null and amount>=0 and effective_pct is not null and calculation_base is not null and reason is null)
    or
    (calculation_status='unavailable' and amount is null and reason is not null)
  )
);

create index proposal_seller_commission_org_seller_idx
  on public.proposal_seller_commission_snapshots(organization_id,seller_id,frozen_at desc);
create index proposal_seller_commission_proposal_idx
  on public.proposal_seller_commission_snapshots(proposal_id);

create or replace function public.guard_seller_commission_snapshot()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if tg_op in ('UPDATE','DELETE') then
    raise exception 'seller_commission_snapshot_is_immutable';
  end if;
  if current_user in ('authenticated','anon')
     and current_setting('corban.seller_commission_snapshot',true) is distinct from 'on' then
    raise exception 'seller_commission_snapshot_write_requires_governed_path';
  end if;
  return new;
end
$$;

create trigger proposal_seller_commission_snapshots_00_guard
before insert or update or delete on public.proposal_seller_commission_snapshots
for each row execute function public.guard_seller_commission_snapshot();

create or replace function public.snapshot_seller_commission(p_proposal_id uuid)
returns uuid
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_org uuid;
  v_seller_id uuid;
  v_seller public.commercial_sellers%rowtype;
  v_sim public.simulations%rowtype;
  v_condition uuid;
  v_base numeric;
  v_share public.commercial_condition_shares%rowtype;
  v_id uuid;
  v_reason text;
begin
  select p.organization_id,p.seller_id
    into v_org,v_seller_id
  from public.proposals_v2 p
  where p.id=p_proposal_id
    and p.seller_id is not null
    and public.has_active_organization_role(p.organization_id,array['admin','manager','supervisor']);

  if v_org is null or v_seller_id is null then return null; end if;

  select s.* into v_seller
  from public.commercial_sellers s
  where s.organization_id=v_org
    and s.id=v_seller_id
    and s.is_active;

  if v_seller.id is null then return null; end if;

  if exists(
    select 1 from public.proposal_seller_commission_snapshots x
    where x.organization_id=v_org and x.proposal_id=p_proposal_id
  ) then
    select x.id into v_id
    from public.proposal_seller_commission_snapshots x
    where x.organization_id=v_org and x.proposal_id=p_proposal_id;
    return v_id;
  end if;

  select s.* into v_sim
  from public.simulations s
  join public.proposals_v2 p
    on p.simulation_id=s.id and p.organization_id=s.organization_id
  where p.id=p_proposal_id and p.organization_id=v_org;

  v_base:=coalesce(v_sim.released_amount,v_sim.requested_amount);

  begin
    v_condition:=nullif(v_sim.input_snapshot->>'condition_id','')::uuid;
  exception when others then
    v_condition:=null;
  end;

  if v_condition is not null then
    select sh.* into v_share
    from public.commercial_condition_shares sh
    where sh.organization_id=v_org
      and sh.condition_id=v_condition
      and sh.group_id=v_seller.commission_group_id;
  end if;

  perform set_config('corban.seller_commission_snapshot','on',true);

  if v_base is not null and v_share.id is not null then
    insert into public.proposal_seller_commission_snapshots(
      organization_id,proposal_id,seller_id,commission_group_id,
      calculation_status,source_kind,calculation_base,effective_pct,amount,
      condition_id,policy_version_id,snapshot
    ) values(
      v_org,p_proposal_id,v_seller.id,v_seller.commission_group_id,
      'calculated','condition_group_share',round(v_base,2),v_share.effective_pct,
      round(v_base*v_share.effective_pct/100,2),
      v_condition,v_share.policy_version_id,
      jsonb_build_object(
        'seller_category',v_seller.seller_category,
        'seller_group_id',v_seller.seller_group_id,
        'commission_group_id',v_seller.commission_group_id,
        'share_source',v_share.source
      )
    ) returning id into v_id;
  else
    v_reason:=case
      when v_sim.id is null then 'simulation_not_available'
      when v_condition is null then 'condition_not_snapshotted'
      when v_base is null then 'calculation_base_not_available'
      when v_share.id is null then 'seller_commission_share_not_resolved'
      else 'seller_commission_not_available'
    end;

    insert into public.proposal_seller_commission_snapshots(
      organization_id,proposal_id,seller_id,commission_group_id,
      calculation_status,source_kind,condition_id,reason,snapshot
    ) values(
      v_org,p_proposal_id,v_seller.id,v_seller.commission_group_id,
      'unavailable','unavailable',v_condition,v_reason,
      jsonb_build_object(
        'seller_category',v_seller.seller_category,
        'seller_group_id',v_seller.seller_group_id,
        'commission_group_id',v_seller.commission_group_id
      )
    ) returning id into v_id;
  end if;

  perform set_config('corban.seller_commission_snapshot','off',true);
  return v_id;
end
$$;

create or replace function public.snapshot_seller_commission_after_component()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if new.seller_id is not null then
    perform public.snapshot_seller_commission(new.proposal_id);
  end if;
  return new;
end
$$;

create trigger proposal_component_snapshot_20_seller_commission
after insert on public.proposal_commercial_component_snapshots
for each row execute function public.snapshot_seller_commission_after_component();

alter table public.seller_supervisions enable row level security;
alter table public.proposal_seller_commission_snapshots enable row level security;

revoke all on public.seller_supervisions,public.proposal_seller_commission_snapshots from public,anon,authenticated;
grant select,insert,update on public.seller_supervisions to authenticated;
grant select,insert on public.proposal_seller_commission_snapshots to authenticated;

drop policy if exists commercial_sellers_select_supervisor on public.commercial_sellers;
create policy commercial_sellers_select_scoped on public.commercial_sellers
for select to authenticated
using (
  public.has_active_organization_role(organization_id,array['admin','manager','supervisor'])
  or user_id=auth.uid()
);

create policy seller_supervisions_select_scoped on public.seller_supervisions
for select to authenticated
using (
  public.has_active_organization_role(organization_id,array['admin','manager'])
  or (
    public.has_active_organization_role(organization_id,array['supervisor'])
    and supervisor_user_id=auth.uid()
  )
);
create policy seller_supervisions_insert_manager on public.seller_supervisions
for insert to authenticated
with check (public.has_active_organization_role(organization_id,array['admin','manager']));
create policy seller_supervisions_update_manager on public.seller_supervisions
for update to authenticated
using (public.has_active_organization_role(organization_id,array['admin','manager']))
with check (public.has_active_organization_role(organization_id,array['admin','manager']));

create policy proposal_seller_commission_select_scoped
on public.proposal_seller_commission_snapshots
for select to authenticated
using (public.can_view_seller_commission(organization_id,seller_id));

create policy proposal_seller_commission_insert_governed
on public.proposal_seller_commission_snapshots
for insert to authenticated
with check (
  public.has_active_organization_role(organization_id,array['admin','manager','supervisor'])
  and current_setting('corban.seller_commission_snapshot',true)='on'
);

drop policy if exists proposal_commercial_component_snapshots_select_supervisor_plus
  on public.proposal_commercial_component_snapshots;
create policy proposal_commercial_component_snapshots_select_scoped
on public.proposal_commercial_component_snapshots
for select to authenticated
using (
  public.has_active_organization_role(organization_id,array['admin','manager'])
  or (
    public.has_active_organization_role(organization_id,array['supervisor'])
    and seller_id is not null
    and public.can_view_seller_commission(organization_id,seller_id)
  )
);

drop policy if exists financial_events_select_supervisor_plus on public.financial_events;
create policy financial_events_select_scoped
on public.financial_events
for select to authenticated
using (
  public.has_active_organization_role(organization_id,array['admin','manager'])
  or (
    public.has_active_organization_role(organization_id,array['supervisor'])
    and proposal_id is not null
    and exists(
      select 1 from public.proposals_v2 p
      where p.organization_id=financial_events.organization_id
        and p.id=financial_events.proposal_id
        and p.seller_id is not null
        and public.can_view_seller_commission(p.organization_id,p.seller_id)
    )
  )
);

drop policy if exists financial_reconciliation_cases_select_supervisor_plus
  on public.financial_reconciliation_cases;
create policy financial_reconciliation_cases_select_scoped
on public.financial_reconciliation_cases
for select to authenticated
using (
  public.has_active_organization_role(organization_id,array['admin','manager'])
  or (
    public.has_active_organization_role(organization_id,array['supervisor'])
    and proposal_id is not null
    and exists(
      select 1 from public.proposals_v2 p
      where p.organization_id=financial_reconciliation_cases.organization_id
        and p.id=financial_reconciliation_cases.proposal_id
        and p.seller_id is not null
        and public.can_view_seller_commission(p.organization_id,p.seller_id)
    )
  )
);

revoke all on function public.guard_seller_supervision() from public,anon,authenticated;
revoke all on function public.guard_seller_commission_snapshot() from public,anon,authenticated;
revoke all on function public.snapshot_seller_commission_after_component() from public,anon,authenticated;

revoke all on function public.set_seller_user(uuid,uuid) from public,anon;
grant execute on function public.set_seller_user(uuid,uuid) to authenticated;
revoke all on function public.set_seller_supervision(uuid,uuid,boolean) from public,anon;
grant execute on function public.set_seller_supervision(uuid,uuid,boolean) to authenticated;
revoke all on function public.can_view_seller_commission(uuid,uuid) from public,anon;
grant execute on function public.can_view_seller_commission(uuid,uuid) to authenticated;
revoke all on function public.snapshot_seller_commission(uuid) from public,anon;
grant execute on function public.snapshot_seller_commission(uuid) to authenticated;
