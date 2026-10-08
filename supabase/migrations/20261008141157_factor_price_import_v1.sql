-- Bank factors by the bank's own table code, for every partner promoter (owner request 08/10/2026).
--
-- Owner rule: the factor belongs to the bank, the agreement and the bank's table (e.g. Daycoval Gov. Acre 745031);
-- every partner promoter that sells that bank table (Bevicred, Efetivamais, any other later) uses the same factor.
-- The bank works on business days only: a daily factor exists only for business days, so on weekends and holidays
-- nothing is offered (no change needed: a daily factor resolves only for its exact date).
-- 1. product_tables.bank_table_code: the bank's code of the table; filled for Daycoval tables from the code or the name
--    (day-bev-745031 / "745031 - RFN - GOV ACRE ...").
-- 2. commercial_factor_profiles.bank_table_code: a profile scoped to the bank's table code instead of one system table.
-- 3. resolve_commercial_factor matches it (as specific as one table).
-- 4. import_factor_price(...): the bank's "Fator Price" sheets (one per table, one line per business date), checked on
--    the screen first; one daily profile per code (created when missing) and one published batch per date. Importing
--    the same file again changes nothing; a changed factor for a date becomes a new revision (history kept).
-- Contract: tests/security/factor-price-import-contract.sql

alter table public.product_tables add column if not exists bank_table_code text
  check (bank_table_code is null or bank_table_code ~ '^[0-9A-Za-z._-]{1,30}$');
create index if not exists product_tables_bank_table_code_idx
  on public.product_tables(organization_id, bank_table_code) where bank_table_code is not null;

update public.product_tables t
set bank_table_code = coalesce(substring(t.code from '^day-bev-([0-9]{6})$'), substring(t.name from '^([0-9]{6})( |-|$)'))
from public.organization_product_routes r
join public.organization_banks b on b.id = r.org_bank_id
where r.id = t.route_id and b.name ilike '%daycoval%' and t.bank_table_code is null
  and coalesce(substring(t.code from '^day-bev-([0-9]{6})$'), substring(t.name from '^([0-9]{6})( |-|$)')) is not null;

alter table public.commercial_factor_profiles add column if not exists bank_table_code text
  check (bank_table_code is null or bank_table_code ~ '^[0-9A-Za-z._-]{1,30}$');
alter table public.commercial_factor_profiles add constraint commercial_factor_profiles_one_table_scope
  check (bank_table_code is null or product_table_id is null);
drop index if exists public.commercial_factor_profiles_scope_key;
create unique index commercial_factor_profiles_scope_key
on public.commercial_factor_profiles(organization_id,org_bank_id,org_agreement_id,product_table_id,bank_table_code,contract_type_id,factor_mode) nulls not distinct;

create or replace function public.resolve_commercial_factor(
  p_org_bank uuid,
  p_org_agreement uuid,
  p_product_table uuid,
  p_contract_type uuid,
  p_term integer,
  p_on date default current_date
)
returns table(profile_id uuid,batch_id uuid,factor_mode text,effective_date date,factor_value numeric,term_min integer,term_max integer)
language sql stable set search_path='' as $$
with tbl as (
  select t.bank_table_code from public.product_tables t where t.id=p_product_table
), profiles as (
  select p.*,
         (case when p.product_table_id is not null or p.bank_table_code is not null then 8 else 0 end
          + case when p.contract_type_id is not null then 4 else 0 end
          + case when p.org_agreement_id is not null then 2 else 0 end) specificity
  from public.commercial_factor_profiles p
  where p.org_bank_id=p_org_bank
    and p.is_active
    and public.is_active_organization_member(p.organization_id)
    and (p.org_agreement_id is null or p.org_agreement_id=p_org_agreement)
    and (p.product_table_id is null or p.product_table_id=p_product_table)
    and (p.bank_table_code is null or p.bank_table_code=(select bank_table_code from tbl))
    and (p.contract_type_id is null or p.contract_type_id=p_contract_type)
), candidates as (
  select p.id profile_id,b.id batch_id,p.factor_mode,b.effective_date,b.revision,p.specificity,
         e.factor_value,e.term_min,e.term_max
  from profiles p
  join lateral (
    select x.*
    from public.commercial_factor_batches x
    where x.profile_id=p.id and x.status='published'
      and ((p.factor_mode='daily' and x.effective_date=p_on)
        or (p.factor_mode='fixed' and x.effective_date<=p_on))
    order by
      case when p.factor_mode='daily' then 1 else 0 end desc,
      x.effective_date desc,x.revision desc
    limit 1
  ) b on true
  join public.commercial_factor_entries e on e.batch_id=b.id
  where p_term between e.term_min and e.term_max
)
select c.profile_id,c.batch_id,c.factor_mode,c.effective_date,c.factor_value,c.term_min,c.term_max
from candidates c
order by c.specificity desc,
         case when c.factor_mode='daily' then 1 else 0 end desc,
         c.effective_date desc,c.revision desc
limit 1
$$;

-- p_sheets: [{"code":"745031","label":"RFNGOVACRE1DIGPORTAB","dates":[{"date":"2026-10-08","entries":[{"term":120,"factor":"0.02816"}]}]}]
create or replace function public.import_factor_price(p_org uuid, p_bank uuid, p_agreement uuid, p_sheets jsonb, p_source_note text default null)
returns jsonb language plpgsql set search_path to '' as $$
declare s jsonb; d jsonb; e jsonb; v_code text; v_label text; v_date date; v_profile uuid; v_batch uuid; v_rev integer;
        v_bank_name text; v_agreement_name text; v_last uuid; v_same boolean; v_new jsonb;
        v_created integer := 0; v_published integer := 0; v_unchanged integer := 0; v_missing text[] := '{}'; v_codes text[] := '{}';
begin
  if auth.uid() is null or p_org is null or not public.has_active_organization_role(p_org, array['admin','manager']) then raise exception 'not_authorized'; end if;
  select name into v_bank_name from public.organization_banks where id = p_bank and organization_id = p_org;
  select name into v_agreement_name from public.organization_agreements where id = p_agreement and organization_id = p_org;
  if v_bank_name is null or v_agreement_name is null then raise exception 'factor_bank_or_agreement_not_found'; end if;
  if jsonb_typeof(p_sheets) <> 'array' or jsonb_array_length(p_sheets) = 0 or jsonb_array_length(p_sheets) > 200 then raise exception 'factor_price_empty'; end if;

  for s in select * from jsonb_array_elements(p_sheets) loop
    v_code := s->>'code'; v_label := left(coalesce(s->>'label', ''), 60);
    if v_code is null or v_code !~ '^[0-9A-Za-z._-]{1,30}$' then raise exception 'factor_price_invalid_code'; end if;
    if v_code = any(v_codes) then raise exception 'factor_price_duplicate_code'; end if;
    v_codes := v_codes || v_code;
    -- Only codes that some table of this bank and agreement carries (any promoter).
    if not exists (select 1 from public.product_tables t join public.organization_product_routes r on r.id = t.route_id
                   where t.organization_id = p_org and t.bank_table_code = v_code and r.org_bank_id = p_bank and r.org_agreement_id = p_agreement) then
      v_missing := v_missing || v_code; continue;
    end if;

    select id into v_profile from public.commercial_factor_profiles
    where organization_id = p_org and org_bank_id = p_bank and org_agreement_id = p_agreement and bank_table_code = v_code
      and product_table_id is null and contract_type_id is null and factor_mode = 'daily';
    if v_profile is null then
      insert into public.commercial_factor_profiles (organization_id, name, org_bank_id, org_agreement_id, bank_table_code, factor_mode, is_active)
      values (p_org, left(v_bank_name || ' ' || v_agreement_name || ' ' || v_code || case when v_label <> '' then ' ' || v_label else '' end, 120),
              p_bank, p_agreement, v_code, 'daily', true)
      returning id into v_profile;
      v_created := v_created + 1;
    end if;

    for d in select * from jsonb_array_elements(coalesce(s->'dates', '[]'::jsonb)) loop
      v_date := (d->>'date')::date;
      if v_date is null or jsonb_array_length(coalesce(d->'entries', '[]'::jsonb)) = 0 then raise exception 'factor_price_invalid_date'; end if;
      select jsonb_agg(jsonb_build_object('t', (x->>'term')::integer, 'f', (x->>'factor')::numeric(18,12)) order by (x->>'term')::integer)
        into v_new from jsonb_array_elements(d->'entries') x;
      -- The same factors already published for this date: nothing to do.
      select b.id into v_last from public.commercial_factor_batches b
      where b.profile_id = v_profile and b.effective_date = v_date and b.status = 'published' order by b.revision desc limit 1;
      if v_last is not null then
        select coalesce(jsonb_agg(jsonb_build_object('t', en.term_min, 'f', en.factor_value) order by en.term_min), '[]'::jsonb) = v_new
               and bool_and(en.term_min = en.term_max)
          into v_same from public.commercial_factor_entries en where en.batch_id = v_last;
        if v_same then v_unchanged := v_unchanged + 1; continue; end if;
      end if;
      select coalesce(max(revision), 0) + 1 into v_rev from public.commercial_factor_batches where profile_id = v_profile and effective_date = v_date;
      insert into public.commercial_factor_batches (organization_id, profile_id, effective_date, revision, status, source_kind, source_note)
      values (p_org, v_profile, v_date, v_rev, 'draft', 'file', left(coalesce(p_source_note, 'Fator Price'), 200))
      returning id into v_batch;
      for e in select * from jsonb_array_elements(d->'entries') loop
        if (e->>'term')::integer not between 1 and 600 or (e->>'factor')::numeric <= 0 or (e->>'factor')::numeric >= 1 then raise exception 'factor_price_invalid_factor'; end if;
        insert into public.commercial_factor_entries (organization_id, batch_id, term_min, term_max, factor_value)
        values (p_org, v_batch, (e->>'term')::integer, (e->>'term')::integer, (e->>'factor')::numeric);
      end loop;
      perform public.publish_commercial_factor_batch(v_batch);
      v_published := v_published + 1;
    end loop;
  end loop;
  return jsonb_build_object('profiles_created', v_created, 'batches_published', v_published, 'batches_unchanged', v_unchanged, 'codes_without_table', to_jsonb(v_missing));
end
$$;

revoke all on function public.import_factor_price(uuid, uuid, uuid, jsonb, text) from public, anon;
grant execute on function public.import_factor_price(uuid, uuid, uuid, jsonb, text) to authenticated;
