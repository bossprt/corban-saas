-- CORBAN OS — Commercial condition amount ranges V1
-- Adds contract-value bands to commercial conditions without expanding one row per value/term.
-- NULL amount_min/amount_max means "any contract value" for legacy/current catalogs.

alter table public.commercial_conditions
  add column if not exists amount_min numeric(15,2),
  add column if not exists amount_max numeric(15,2);

alter table public.commercial_conditions
  drop constraint if exists commercial_conditions_amount_range_check;

alter table public.commercial_conditions
  add constraint commercial_conditions_amount_range_check
  check (
    (amount_min is null and amount_max is null)
    or (
      amount_min is not null and amount_max is not null
      and amount_min >= 0
      and amount_max >= amount_min
      and amount_max <= 999999999.99
    )
  );

-- A commission-only condition is valid even when the source does not publish rate/coefficient.
-- Existing pricing conditions remain unchanged; simulations without a coefficient remain manual_pending.
alter table public.commercial_conditions
  drop constraint if exists commercial_conditions_check;

-- Term overlap is allowed only when the value bands are disjoint.
alter table public.commercial_conditions
  drop constraint if exists commercial_conditions_no_overlapping_term_ranges;

drop index if exists public.commercial_conditions_version_type_range_key;
drop index if exists public.commercial_conditions_range_lookup_idx;

alter table public.commercial_conditions
  add constraint commercial_conditions_no_overlapping_term_amount_ranges
  exclude using gist (
    product_table_version_id with =,
    contract_type_id with =,
    int4range(term_min,term_max,'[]') with &&,
    numrange(amount_min,amount_max,'[]') with &&
  );

create index if not exists commercial_conditions_term_amount_lookup_idx
  on public.commercial_conditions(
    product_table_version_id,contract_type_id,term_min,term_max,amount_min,amount_max
  );

create or replace function public.save_commercial_condition_range(
  p_version uuid,
  p_contract_type uuid,
  p_term_min integer,
  p_term_max integer,
  p_coefficient numeric,
  p_rate numeric,
  p_received numeric,
  p_shares jsonb,
  p_condition uuid,
  p_policy_version uuid,
  p_amount_min numeric,
  p_amount_max numeric
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
 if (p_amount_min is null) <> (p_amount_max is null)
    or (p_amount_min is not null and (p_amount_min<0 or p_amount_max<p_amount_min or p_amount_max>999999999.99))
 then raise exception 'invalid_amount_range'; end if;
 if coalesce(p_coefficient,0)<0 or coalesce(p_rate,0)<0 then raise exception 'invalid_rate_or_coefficient'; end if;
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
     term,term_min,term_max,amount_min,amount_max,coefficient,rate,created_by
   ) values(
     v.organization_id,v.id,p_contract_type,
     p_term_min,p_term_min,p_term_max,p_amount_min,p_amount_max,p_coefficient,p_rate,auth.uid()
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
       amount_min=p_amount_min,
       amount_max=p_amount_max,
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

-- Backwards-compatible wrapper: legacy callers still mean "any value".
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
begin
 if p_coefficient is null and p_rate is null then raise exception 'coefficient_or_rate_required'; end if;
 return public.save_commercial_condition_range(
   p_version,p_contract_type,p_term_min,p_term_max,p_coefficient,p_rate,p_received,p_shares,
   p_condition,p_policy_version,null,null
 );
end
$$;

create or replace function public.import_commercial_conditions(
  p_version uuid,
  p_rows jsonb,
  p_policy_version uuid default null
)
returns jsonb
language plpgsql
set search_path=''
as $$
declare
 v public.product_table_versions%rowtype;
 e jsonb;
 i integer:=0;
 v_line integer;
 v_ct uuid;
 v_term_min integer;
 v_term_max integer;
 v_amount_min numeric;
 v_amount_max numeric;
 v_existing uuid;
 v_id uuid;
 v_msg text;
 v_errors jsonb:='[]'::jsonb;
 v_lines jsonb:='[]'::jsonb;
 v_seen text[]:='{}';
 v_key text;
 v_created integer:=0;
 v_updated integer:=0;
 v_known text[]:=array[
  'condition_range_conflict','invalid_term_range','invalid_amount_range','invalid_shares','duplicate_group_share','commission_group_not_found',
  'production_shares_exceed_received_commission','policy_not_found','policy_group_inactive',
  'coefficient_or_rate_required','invalid_received_commission','contract_type_not_found','condition_not_found','version_not_draft'
 ];
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into v from public.product_table_versions x where x.id=p_version;
 if not found then raise exception 'version_not_found'; end if;
 if not public.has_active_organization_role(v.organization_id,array['admin','manager']) then raise exception 'not_authorized'; end if;
 if v.status<>'draft' then raise exception 'version_not_draft'; end if;
 if p_rows is null or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)=0 then raise exception 'invalid_rows'; end if;
 if jsonb_array_length(p_rows)>500 then raise exception 'too_many_rows'; end if;

 perform 1 from public.product_table_versions x where x.id=p_version for update;

 for e in select * from jsonb_array_elements(p_rows) loop
  i:=i+1; v_line:=i+1; v_id:=null; v_existing:=null; v_amount_min:=null; v_amount_max:=null;
  begin
   if jsonb_typeof(e)<>'object' then raise exception 'invalid_row'; end if;
   if e->>'line' ~ '^[0-9]{1,6}$' then v_line:=(e->>'line')::integer; end if;
   begin
    v_ct:=(e->>'contract_type_id')::uuid;
    v_term_min:=coalesce(nullif(e->>'term_min',''),nullif(e->>'term',''))::integer;
    v_term_max:=coalesce(nullif(e->>'term_max',''),nullif(e->>'term_min',''),nullif(e->>'term',''))::integer;
    v_amount_min:=nullif(e->>'amount_min','')::numeric;
    v_amount_max:=nullif(e->>'amount_max','')::numeric;
   exception when others then raise exception 'invalid_row'; end;

   if v_ct is null or v_term_min is null or v_term_max is null or v_term_min<1 or v_term_max>600 or v_term_min>v_term_max
   then raise exception 'invalid_term_range'; end if;
   if (v_amount_min is null) <> (v_amount_max is null)
      or (v_amount_min is not null and (v_amount_min<0 or v_amount_max<v_amount_min or v_amount_max>999999999.99))
   then raise exception 'invalid_amount_range'; end if;

   v_key:=v_ct::text||'|'||v_term_min||'|'||v_term_max||'|'||
          coalesce(v_amount_min::text,'*')||'|'||coalesce(v_amount_max::text,'*');
   if v_key=any(v_seen) then raise exception 'duplicate_row'; end if;
   v_seen:=v_seen||v_key;

   select c.id into v_existing
   from public.commercial_conditions c
   where c.product_table_version_id=v.id
     and c.contract_type_id=v_ct
     and c.term_min=v_term_min
     and c.term_max=v_term_max
     and c.amount_min is not distinct from v_amount_min
     and c.amount_max is not distinct from v_amount_max;

   v_id:=public.save_commercial_condition_range(
     p_version,v_ct,v_term_min,v_term_max,
     nullif(e->>'coefficient','')::numeric,
     nullif(e->>'rate','')::numeric,
     nullif(e->>'received','')::numeric,
     coalesce(e->'shares','[]'::jsonb),
     v_existing,p_policy_version,v_amount_min,v_amount_max
   );

   if v_existing is null then v_created:=v_created+1; else v_updated:=v_updated+1; end if;
   v_lines:=v_lines||jsonb_build_object('line',v_line,'status',case when v_existing is null then 'created' else 'updated' end,'condition_id',v_id);
  exception when others then
   v_msg:=sqlerrm;
   if v_msg in ('not_authorized','version_not_found') then raise exception '%',v_msg; end if;
   v_errors:=v_errors||jsonb_build_object(
     'line',v_line,
     'code',case when v_msg=any(v_known) or v_msg in ('invalid_row','duplicate_row') then v_msg
                 when sqlstate in ('22P02','22003','22023') then 'invalid_number'
                 else 'unexpected' end
   );
  end;
 end loop;

 if jsonb_array_length(v_errors)>0 then
  raise exception 'bulk_import_rejected' using detail=v_errors::text;
 end if;

 return jsonb_build_object('created',v_created,'updated',v_updated,'lines',v_lines);
end
$$;

-- Legacy simulation path only selects unbounded-value conditions, avoiding a wrong
-- match once a table has several amount bands.
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

  select cl.* into v_customer from public.clients cl where cl.id=p_customer_id and cl.deleted_at is null;
  if v_customer.id is null then raise exception 'customer_not_found_or_forbidden'; end if;
  if not public.is_active_organization_member(v_customer.organization_id) then raise exception 'not_authorized'; end if;

  select x.* into v_version from public.product_table_versions x
  where x.id=p_table_version_id
    and x.organization_id=v_customer.organization_id
    and x.status='published'
    and coalesce(x.effective_from,x.published_at,x.created_at)<=v_now
    and (x.effective_until is null or v_now<x.effective_until);
  if v_version.id is null then raise exception 'published_table_version_not_available'; end if;

  select k.* into c from public.commercial_conditions k
  where k.organization_id=v_customer.organization_id
    and k.product_table_version_id=v_version.id
    and k.contract_type_id=p_contract_type_id
    and p_term between k.term_min and k.term_max
    and k.amount_min is null and k.amount_max is null
  order by k.term_min desc limit 1;

  if c.id is null then
    if exists(
      select 1 from public.commercial_conditions k
      where k.organization_id=v_customer.organization_id
        and k.product_table_version_id=v_version.id
        and k.contract_type_id=p_contract_type_id
        and p_term between k.term_min and k.term_max
        and k.amount_min is not null
    ) then raise exception 'contract_value_required'; end if;
    raise exception 'condition_not_found';
  end if;

  v_installment:=case when c.coefficient is not null and c.coefficient>0 then round(v_amount*c.coefficient,2) else null end;

  perform set_config('corban.simulation_rpc','on',true);
  insert into public.simulations(
    organization_id,customer_id,product_table_version_id,status,
    requested_amount,installment_amount,term,rate,coefficient,input_snapshot,result_snapshot,created_by
  ) values(
    v_customer.organization_id,v_customer.id,v_version.id,'calculated',
    v_amount,v_installment,p_term,c.rate,c.coefficient,
    jsonb_build_object(
      'requested_amount',v_amount,'term',p_term,'contract_type_id',p_contract_type_id,
      'condition_id',c.id,'condition_term_min',c.term_min,'condition_term_max',c.term_max,
      'condition_amount_min',c.amount_min,'condition_amount_max',c.amount_max,'pricing_effective_at',v_now
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

-- Amount-aware path. p_contract_value is explicit because a refinance's current
-- contract value is not necessarily the same as the requested new amount.
create or replace function public.create_simulation_for_condition(
  p_customer_id uuid,
  p_table_version_id uuid,
  p_contract_type_id uuid,
  p_requested_amount numeric,
  p_term integer,
  p_contract_value numeric
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
  v_contract_value numeric;
  v_installment numeric;
  v_id uuid;
  v_now timestamptz:=now();
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if p_requested_amount is null or p_requested_amount<=0 or p_requested_amount>999999999 then raise exception 'invalid_amount'; end if;
  if p_contract_value is null or p_contract_value<0 or p_contract_value>999999999.99 then raise exception 'invalid_contract_value'; end if;
  if p_term is null or p_term<=0 or p_term>600 then raise exception 'invalid_term'; end if;
  v_amount:=round(p_requested_amount,2);
  v_contract_value:=round(p_contract_value,2);

  select cl.* into v_customer from public.clients cl where cl.id=p_customer_id and cl.deleted_at is null;
  if v_customer.id is null then raise exception 'customer_not_found_or_forbidden'; end if;
  if not public.is_active_organization_member(v_customer.organization_id) then raise exception 'not_authorized'; end if;

  select x.* into v_version from public.product_table_versions x
  where x.id=p_table_version_id
    and x.organization_id=v_customer.organization_id
    and x.status='published'
    and coalesce(x.effective_from,x.published_at,x.created_at)<=v_now
    and (x.effective_until is null or v_now<x.effective_until);
  if v_version.id is null then raise exception 'published_table_version_not_available'; end if;

  select k.* into c from public.commercial_conditions k
  where k.organization_id=v_customer.organization_id
    and k.product_table_version_id=v_version.id
    and k.contract_type_id=p_contract_type_id
    and p_term between k.term_min and k.term_max
    and (
      (k.amount_min is null and k.amount_max is null)
      or v_contract_value between k.amount_min and k.amount_max
    )
  order by (k.amount_min is not null) desc,k.term_min desc,k.amount_min desc nulls last
  limit 1;

  if c.id is null then raise exception 'condition_not_found'; end if;

  v_installment:=case when c.coefficient is not null and c.coefficient>0 then round(v_amount*c.coefficient,2) else null end;

  perform set_config('corban.simulation_rpc','on',true);
  insert into public.simulations(
    organization_id,customer_id,product_table_version_id,status,
    requested_amount,installment_amount,term,rate,coefficient,input_snapshot,result_snapshot,created_by
  ) values(
    v_customer.organization_id,v_customer.id,v_version.id,'calculated',
    v_amount,v_installment,p_term,c.rate,c.coefficient,
    jsonb_build_object(
      'requested_amount',v_amount,'contract_value',v_contract_value,'term',p_term,'contract_type_id',p_contract_type_id,
      'condition_id',c.id,'condition_term_min',c.term_min,'condition_term_max',c.term_max,
      'condition_amount_min',c.amount_min,'condition_amount_max',c.amount_max,'pricing_effective_at',v_now
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
