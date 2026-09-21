-- CORBAN OS — Commercial condition rate/coefficient identity V1
-- PREPARED ONLY. Required for commercial tables where the same term exists at multiple rates.

alter table public.commercial_conditions
  drop constraint if exists commercial_conditions_product_table_version_id_contract_typ_key;

create unique index if not exists commercial_conditions_version_contract_term_rate_coeff_key
on public.commercial_conditions(
  product_table_version_id,
  contract_type_id,
  term,
  coalesce(rate, -1::numeric),
  coalesce(coefficient, -1::numeric)
);

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
  v_term integer;
  v_rate numeric;
  v_coefficient numeric;
  v_existing uuid;
  v_id uuid;
  v_msg text;
  v_key text;
  v_errors jsonb:='[]'::jsonb;
  v_lines jsonb:='[]'::jsonb;
  v_seen text[]:='{}';
  v_created integer:=0;
  v_updated integer:=0;
  v_known text[]:=array[
    'condition_already_exists','invalid_shares','duplicate_group_share',
    'commission_group_not_found','production_shares_exceed_received_commission',
    'policy_not_found','policy_group_inactive','invalid_term',
    'coefficient_or_rate_required','invalid_received_commission',
    'contract_type_not_found','condition_not_found','version_not_draft'
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
    i:=i+1;
    v_line:=i+1;
    v_id:=null;
    v_existing:=null;
    v_rate:=null;
    v_coefficient:=null;

    begin
      if jsonb_typeof(e)<>'object' then raise exception 'invalid_row'; end if;
      if e->>'line' ~ '^[0-9]{1,6}$' then v_line:=(e->>'line')::integer; end if;
      begin
        v_ct:=(e->>'contract_type_id')::uuid;
        v_term:=(e->>'term')::integer;
        v_coefficient:=nullif(e->>'coefficient','')::numeric;
        v_rate:=nullif(e->>'rate','')::numeric;
      exception when others then
        raise exception 'invalid_row';
      end;
      if v_ct is null or v_term is null then raise exception 'invalid_row'; end if;
      if v_coefficient is null and v_rate is null then raise exception 'coefficient_or_rate_required'; end if;

      v_key:=v_ct::text||'|'||v_term::text||'|'||
             coalesce(v_coefficient::text,'')||'|'||coalesce(v_rate::text,'');
      if v_key=any(v_seen) then raise exception 'duplicate_row'; end if;
      v_seen:=v_seen||v_key;

      select c.id into v_existing
      from public.commercial_conditions c
      where c.product_table_version_id=v.id
        and c.contract_type_id=v_ct
        and c.term=v_term
        and c.coefficient is not distinct from v_coefficient
        and c.rate is not distinct from v_rate;

      v_id:=public.save_commercial_condition(
        p_version,v_ct,v_term,v_coefficient,v_rate,
        nullif(e->>'received','')::numeric,
        coalesce(e->'shares','[]'::jsonb),
        v_existing,p_policy_version
      );

      if v_existing is null then v_created:=v_created+1; else v_updated:=v_updated+1; end if;
      v_lines:=v_lines||jsonb_build_object(
        'line',v_line,
        'status',case when v_existing is null then 'created' else 'updated' end,
        'condition_id',v_id
      );
    exception when others then
      v_msg:=sqlerrm;
      if v_msg in ('not_authorized','version_not_found') then raise exception '%',v_msg; end if;
      v_errors:=v_errors||jsonb_build_object(
        'line',v_line,
        'code',case
          when v_msg=any(v_known) or v_msg in ('invalid_row','duplicate_row') then v_msg
          when sqlstate in ('22P02','22003','22023') then 'invalid_number'
          else 'unexpected'
        end
      );
    end;
  end loop;

  if jsonb_array_length(v_errors)>0 then
    raise exception 'bulk_import_rejected' using detail=v_errors::text;
  end if;

  return jsonb_build_object('created',v_created,'updated',v_updated,'lines',v_lines);
end
$$;
