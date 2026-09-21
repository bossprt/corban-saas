-- CORBAN OS — Smart Import policy scope guard V1
-- PREPARED ONLY. Requires explicit Human Gate before LIVE apply.
-- Defense-in-depth: a component payout policy may only attach to a condition inside the policy's declared bank/agreement/table scope.

create or replace function public.guard_condition_component_policy()
returns trigger
language plpgsql
set search_path=''
as $$
declare
  v_status text;
  v_table_id uuid;
  v_bank_id uuid;
  v_agreement_id uuid;
  v_policy public.component_payout_policies%rowtype;
begin
  select v.status,t.id,r.org_bank_id,r.org_agreement_id
    into v_status,v_table_id,v_bank_id,v_agreement_id
  from public.commercial_conditions c
  join public.product_table_versions v
    on v.id=c.product_table_version_id and v.organization_id=c.organization_id
  join public.product_tables t
    on t.id=v.product_table_id and t.organization_id=v.organization_id
  join public.organization_product_routes r
    on r.id=t.route_id and r.organization_id=t.organization_id
  where c.id=new.condition_id and c.organization_id=new.organization_id;

  if v_status is distinct from 'draft' then
    raise exception 'published_version_component_policy_is_immutable';
  end if;

  select p.* into v_policy
  from public.component_payout_policy_versions pv
  join public.component_payout_policies p
    on p.id=pv.policy_id and p.organization_id=pv.organization_id
  where pv.id=new.policy_version_id
    and pv.organization_id=new.organization_id
    and p.is_active;

  if not found then
    raise exception 'component_policy_not_found';
  end if;

  if v_policy.org_bank_id is not null and v_policy.org_bank_id is distinct from v_bank_id then
    raise exception 'component_policy_scope_mismatch';
  end if;
  if v_policy.org_agreement_id is not null and v_policy.org_agreement_id is distinct from v_agreement_id then
    raise exception 'component_policy_scope_mismatch';
  end if;
  if v_policy.product_table_id is not null and v_policy.product_table_id is distinct from v_table_id then
    raise exception 'component_policy_scope_mismatch';
  end if;

  if current_user in ('authenticated','anon')
     and current_setting('corban.smart_import_rpc',true) is distinct from 'on' then
    raise exception 'condition_component_policy_write_requires_governed_rpc';
  end if;

  if tg_op='UPDATE' and (
    new.condition_id is distinct from old.condition_id
    or new.organization_id is distinct from old.organization_id
    or new.attached_at is distinct from old.attached_at
  ) then
    raise exception 'condition_component_policy_identity_is_immutable';
  end if;

  if current_user in ('authenticated','anon') then
    new.attached_by:=auth.uid();
  end if;
  return new;
end
$$;

revoke all on function public.guard_condition_component_policy() from public,anon,authenticated;
