do $$
declare
  def text;
  mismatches integer;
begin
  select pg_get_functiondef(p.oid) into def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='guard_condition_component_policy';

  if def is null then raise exception 'guard_condition_component_policy_missing'; end if;
  if position('component_policy_scope_mismatch' in def)=0 then raise exception 'scope_guard_missing'; end if;
  if position('org_bank_id' in def)=0 or position('org_agreement_id' in def)=0 or position('product_table_id' in def)=0 then
    raise exception 'scope_dimensions_missing';
  end if;

  select count(*) into mismatches
  from public.commercial_condition_component_policy l
  join public.commercial_conditions c on c.id=l.condition_id and c.organization_id=l.organization_id
  join public.product_table_versions v on v.id=c.product_table_version_id and v.organization_id=c.organization_id
  join public.product_tables t on t.id=v.product_table_id and t.organization_id=v.organization_id
  join public.organization_product_routes r on r.id=t.route_id and r.organization_id=t.organization_id
  join public.component_payout_policy_versions pv on pv.id=l.policy_version_id and pv.organization_id=l.organization_id
  join public.component_payout_policies p on p.id=pv.policy_id and p.organization_id=pv.organization_id
  where (p.org_bank_id is not null and p.org_bank_id is distinct from r.org_bank_id)
     or (p.org_agreement_id is not null and p.org_agreement_id is distinct from r.org_agreement_id)
     or (p.product_table_id is not null and p.product_table_id is distinct from t.id);

  if mismatches<>0 then raise exception 'existing_scope_mismatches:%',mismatches; end if;

  if has_function_privilege('anon','public.guard_condition_component_policy()','EXECUTE') then raise exception 'anon_execute_guard'; end if;
  if has_function_privilege('authenticated','public.guard_condition_component_policy()','EXECUTE') then raise exception 'authenticated_execute_guard'; end if;
end $$;
