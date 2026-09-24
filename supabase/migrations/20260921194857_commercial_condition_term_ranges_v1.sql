-- CORBAN OS — Commercial condition term ranges V1

create extension if not exists btree_gist;

alter table public.commercial_conditions
  add column if not exists term_min integer,
  add column if not exists term_max integer;

-- Structural backfill only: copy the immutable legacy term into the new range columns.
-- The table is locked by the preceding ALTER; disable only the condition write guard for this equivalent backfill.
alter table public.commercial_conditions disable trigger commercial_conditions_00_guard;

update public.commercial_conditions
set term_min=coalesce(term_min,term),
    term_max=coalesce(term_max,term)
where term_min is null or term_max is null;

alter table public.commercial_conditions enable trigger commercial_conditions_00_guard;

alter table public.commercial_conditions
  alter column term_min set not null,
  alter column term_max set not null;

alter table public.commercial_conditions
  drop constraint if exists commercial_conditions_term_range_check;

alter table public.commercial_conditions
  add constraint commercial_conditions_term_range_check
  check (term_min between 1 and 600 and term_max between 1 and 600 and term_min<=term_max);

alter table public.commercial_conditions
  drop constraint if exists commercial_conditions_product_table_version_id_contract_typ_key;

drop index if exists public.commercial_conditions_product_table_version_id_contract_typ_key;

create unique index if not exists commercial_conditions_version_type_range_key
  on public.commercial_conditions(product_table_version_id,contract_type_id,term_min,term_max);

alter table public.commercial_conditions
  drop constraint if exists commercial_conditions_no_overlapping_term_ranges;

alter table public.commercial_conditions
  add constraint commercial_conditions_no_overlapping_term_ranges
  exclude using gist (
    product_table_version_id with =,
    contract_type_id with =,
    int4range(term_min,term_max,'[]') with &&
  );

create index if not exists commercial_conditions_range_lookup_idx
  on public.commercial_conditions(product_table_version_id,contract_type_id,term_min,term_max);

create or replace function public.save_commercial_condition_range(
  p_version uuid,
  p_contract_type uuid,
  p_term_min integer,
  p_term_max integer,
  p_coefficient numeric,
  p_rate numeric,
  p_received numeric,
  p_shares jsonb,
  p_condition uuid default null,
  p_policy_version uuid default null
)
returns uuid
language plpgsql
set search_path=''
as $$
declare
 v public.product_table_versions%rowtype;
 v_id uuid;
 s jsonb;
 g public.commission_groups%rowtype;
 v_seen uuid[]:='{}';
 v_pct numeric;
 v_gid uuid;
 v_pv public.payout_policy_versions%rowtype;
 v_net numeric;
 v_rows jsonb:='[]'::jsonb;
 v_final jsonb:='[]'::jsonb;
 v_eff numeric;
 r record;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into v from public.product_table_versions x where x.id=p_version;
 if not found then raise exception 'version_not_found'; end if;
 if not public.has_active_organization_role(v.organization_id,array['admin','manager']) then raise exception 'not_authorized'; end if;
 if v.status<>'draft' then raise exception 'version_not_draft'; end if;
 if not exists(select 1 from public.contract_types c where c.id=p_contract_type and c.is_active) then raise exception 'contract_type_not_found'; end if;
 if p_term_min is null or p_term_max is null or p_term_min<1 or p_term_max>600 or p_term_min>p_term_max then raise exception 'invalid_term_range'; end if;
 if (p_coefficient is null and p_rate is null) or coalesce(p_coefficient,0)<0 or coalesce(p_rate,0)<0 then raise exception 'coefficient_or_rate_required'; end if;
 if p_received is null or p_received<0 or p_received>100 then raise exception 'invalid_received_commission'; end if;
 if p_shares is null or jsonb_typeof(p_shares)<>'array' or jsonb_array_length(p_shares)>100 then raise exception 'invalid_shares'; end if;

 if p_policy_version is not null then
  select pv.* into v_pv from public.payout_policy_versions pv
  join public.payout_policies pp on pp.id=pv.policy_id and pp.organization_id=pv.organization_id
  where pv.id=p_policy_version and pv.organization_id=v.organization_id and pp.is_active;
  if not found then raise exception 'policy_not_found'; end if;
 end if;

 v_net:=case when p_policy_version is not null and v_pv.base_kind='net'
             then round(p_received*(100-v_pv.discount_pct)/100,6)
             else p_received end;

 for s in select * from jsonb_array_elements(p_shares) loop
  begin v_gid:=(s->>'group_id')::uuid; v_pct:=(s->>'pct')::numeric;
  exception when others then raise exception 'invalid_shares'; end;
  if v_gid is null or v_pct is null or v_pct<0 or v_pct>100 then raise exception 'invalid_shares'; end if;
  if v_gid=any(v_seen) then raise exception 'duplicate_group_share'; end if;
  v_seen:=v_seen||v_gid;
  v_rows:=v_rows||jsonb_build_object(
    'g',v_gid,'pct',v_pct,
    'src',case when p_policy_version is not null and exists(
      select 1 from public.payout_policy_items i where i.version_id=p_policy_version and i.group_id=v_gid
    ) then 'override' else 'manual' end
  );
 end loop;

 if p_policy_version is not null then
  for r in select i.group_id,i.pct from public.payout_policy_items i
           where i.version_id=p_policy_version and not (i.group_id=any(v_seen))
  loop
   v_seen:=v_seen||r.group_id;
   v_rows:=v_rows||jsonb_build_object('g',r.group_id,'pct',r.pct,'src','policy');
  end loop;
 end if;

 for s in select * from jsonb_array_elements(v_rows) loop
  select * into g from public.commission_groups x
   where x.id=(s->>'g')::uuid and x.organization_id=v.organization_id and x.is_active;
  if not found then raise exception '%',case when s->>'src'='policy' then 'policy_group_inactive' else 'commission_group_not_found' end; end if;
  v_pct:=(s->>'pct')::numeric;
  if g.calculation_basis='percent_of_production' then
   if v_pct>p_received then raise exception 'production_shares_exceed_received_commission'; end if;
   v_eff:=v_pct;
  else
   v_eff:=round(v_net*v_pct/100,6);
  end if;
  v_final:=v_final||(s||jsonb_build_object('eff',v_eff));
 end loop;

 perform set_config('corban.condition_rpc','on',true);

 if p_condition is null then
  begin
   insert into public.commercial_conditions(
     organization_id,product_table_version_id,contract_type_id,
     term,term_min,term_max,coefficient,rate,created_by
   ) values(
     v.organization_id,v.id,p_contract_type,
     p_term_min,p_term_min,p_term_max,p_coefficient,p_rate,auth.uid()
   ) returning id into v_id;
  exception
   when unique_violation or exclusion_violation then
    perform set_config('corban.condition_rpc','off',true);
    raise exception 'condition_range_conflict';
  end;
 else
  select c.id into v_id from public.commercial_conditions c
   where c.id=p_condition and c.product_table_version_id=v.id for update;
  if v_id is null then raise exception 'condition_not_found'; end if;
  begin
   update public.commercial_conditions
   set contract_type_id=p_contract_type,
       term=p_term_min,
       term_min=p_term_min,
       term_max=p_term_max,
       coefficient=p_coefficient,
       rate=p_rate,
       updated_at=now()
   where id=v_id;
  exception
   when unique_violation or exclusion_violation then
    perform set_config('corban.condition_rpc','off',true);
    raise exception 'condition_range_conflict';
  end;
 end if;

 insert into public.commercial_condition_commissions(
   condition_id,organization_id,received_commission_pct,net_base_pct,policy_version_id
 ) values(v_id,v.organization_id,p_received,v_net,p_policy_version)
 on conflict (condition_id) do update
 set received_commission_pct=excluded.received_commission_pct,
     net_base_pct=excluded.net_base_pct,
     policy_version_id=excluded.policy_version_id,
     updated_at=now();

 delete from public.commercial_condition_shares
 where condition_id=v_id and not (group_id=any(v_seen));

 for s in select * from jsonb_array_elements(v_final) loop
  insert into public.commercial_condition_shares(
    organization_id,condition_id,group_id,share_pct,effective_pct,source,policy_version_id
  ) values(
    v.organization_id,v_id,(s->>'g')::uuid,(s->>'pct')::numeric,(s->>'eff')::numeric,s->>'src',
    case when s->>'src' in ('policy','override') then p_policy_version else null end
  )
  on conflict (condition_id,group_id) do update
  set share_pct=excluded.share_pct,
      effective_pct=excluded.effective_pct,
      source=excluded.source,
      policy_version_id=excluded.policy_version_id;
 end loop;

 perform set_config('corban.condition_rpc','off',true);
 return v_id;
exception when others then
 perform set_config('corban.condition_rpc','off',true);
 raise;
end
$$;

create or replace function public.save_commercial_condition(
  p_version uuid,
  p_contract_type uuid,
  p_term integer,
  p_coefficient numeric,
  p_rate numeric,
  p_received numeric,
  p_shares jsonb,
  p_condition uuid default null,
  p_policy_version uuid default null
)
returns uuid
language sql
security invoker
set search_path=''
as $$
 select public.save_commercial_condition_range(
   p_version,p_contract_type,p_term,p_term,p_coefficient,p_rate,p_received,p_shares,p_condition,p_policy_version
 )
$$;

create or replace function public.create_simulation_for_condition(
  p_customer_id uuid,
  p_table_version_id uuid,
  p_contract_type_id uuid,
  p_requested_amount numeric,
  p_term integer
)
returns uuid
language plpgsql
set search_path=''
as $$
declare
  v_customer public.clients%rowtype;
  v_version public.product_table_versions%rowtype;
  c public.commercial_conditions%rowtype;
  v_amount numeric;
  v_installment numeric;
  v_id uuid;
  v_now timestamptz:=now();
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if p_requested_amount is null or p_requested_amount<=0 or p_requested_amount>999999999 then raise exception 'invalid_amount'; end if;
  if p_term is null or p_term<=0 or p_term>600 then raise exception 'invalid_term'; end if;
  v_amount:=round(p_requested_amount,2);

  select cl.* into v_customer
  from public.clients cl
  where cl.id=p_customer_id and cl.deleted_at is null;
  if v_customer.id is null then raise exception 'customer_not_found_or_forbidden'; end if;
  if not public.is_active_organization_member(v_customer.organization_id) then raise exception 'not_authorized'; end if;

  select x.* into v_version
  from public.product_table_versions x
  where x.id=p_table_version_id
    and x.organization_id=v_customer.organization_id
    and x.status='published'
    and coalesce(x.effective_from,x.published_at,x.created_at)<=v_now
    and (x.effective_until is null or v_now<x.effective_until);

  if v_version.id is null then raise exception 'published_table_version_not_available'; end if;

  select k.* into c
  from public.commercial_conditions k
  where k.organization_id=v_customer.organization_id
    and k.product_table_version_id=v_version.id
    and k.contract_type_id=p_contract_type_id
    and p_term between k.term_min and k.term_max
  order by k.term_min desc
  limit 1;

  if c.id is null then raise exception 'condition_not_found'; end if;

  v_installment:=case when c.coefficient is not null and c.coefficient>0
                      then round(v_amount*c.coefficient,2) else null end;

  perform set_config('corban.simulation_rpc','on',true);
  insert into public.simulations(
    organization_id,customer_id,product_table_version_id,status,
    requested_amount,installment_amount,term,rate,coefficient,
    input_snapshot,result_snapshot,created_by
  ) values(
    v_customer.organization_id,v_customer.id,v_version.id,'calculated',
    v_amount,v_installment,p_term,c.rate,c.coefficient,
    jsonb_build_object(
      'requested_amount',v_amount,
      'term',p_term,
      'contract_type_id',p_contract_type_id,
      'condition_id',c.id,
      'condition_term_min',c.term_min,
      'condition_term_max',c.term_max,
      'pricing_effective_at',v_now
    ),
    jsonb_build_object('calculation',case when v_installment is null then 'manual_pending' else 'requested_amount_x_coefficient' end),
    auth.uid()
  ) returning id into v_id;

  perform set_config('corban.simulation_rpc','off',true);
  return v_id;
exception when others then
  perform set_config('corban.simulation_rpc','off',true);
  raise;
end
$$;

revoke all on function public.save_commercial_condition_range(uuid,uuid,integer,integer,numeric,numeric,numeric,jsonb,uuid,uuid) from public,anon;
grant execute on function public.save_commercial_condition_range(uuid,uuid,integer,integer,numeric,numeric,numeric,jsonb,uuid,uuid) to authenticated;
