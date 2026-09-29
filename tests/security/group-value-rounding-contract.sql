-- Contract test for 20260928120000_group_value_rounding_v1: converted group values with a rounding leftover
-- (3.00000001) become exact (3); real values, other sources and published versions stay untouched.
-- One transaction, rolled back. The migration file must be reachable at /tmp/group_value_rounding.sql:
--   docker cp supabase/migrations/20260928120000_group_value_rounding_v1.sql <db>:/tmp/group_value_rounding.sql
--   psql -v ON_ERROR_STOP=1 -f tests/security/group-value-rounding-contract.sql

begin;

create temp table results (check_name text, ok boolean);
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;

-- Four draft values and one published value, picked from the seed.
create temp table picked as
select gv.condition_id, gv.group_id, gv.component_type_id, v.status, row_number() over (partition by v.status order by gv.condition_id, gv.group_id, gv.component_type_id) as n
from public.commercial_condition_group_values gv
join public.commercial_conditions c on c.id = gv.condition_id
join public.product_table_versions v on v.id = c.product_table_version_id;

select set_config('corban.group_values_conversion', 'on', true);
update public.commercial_condition_group_values g set source = 'converted', value = x.v
from (values (1, 3.00000001), (2, 2.99999999), (3, 2.5), (4, 3.0001)) as x(n, v), picked p
where p.status = 'draft' and p.n = x.n
  and g.condition_id = p.condition_id and g.group_id = p.group_id and g.component_type_id = p.component_type_id;
-- A leftover in another source stays: only the conversion produced them.
update public.commercial_condition_group_values g set source = 'import', value = 1.00000001
from picked p where p.status = 'draft' and p.n = 5
  and g.condition_id = p.condition_id and g.group_id = p.group_id and g.component_type_id = p.component_type_id;
select set_config('corban.group_values_conversion', 'off', true);

create temp table before as select * from public.commercial_condition_group_values;

\i /tmp/group_value_rounding.sql

create function pg_temp.val(p_status text, p_n int) returns numeric language sql as $$
  select g.value from public.commercial_condition_group_values g join picked p
    on g.condition_id = p.condition_id and g.group_id = p.group_id and g.component_type_id = p.component_type_id
  where p.status = p_status and p.n = p_n
$$;

insert into results select '3.00000001 becomes 3', pg_temp.val('draft', 1) = 3 and pg_temp.val('draft', 1)::text = '3';
insert into results select '2.99999999 becomes 3', pg_temp.val('draft', 2) = 3;
insert into results select '2.5 stays 2.5', pg_temp.val('draft', 3) = 2.5;
insert into results select '3.0001 stays (a real 4-decimal value)', pg_temp.val('draft', 4) = 3.0001;
insert into results select 'import source not touched', pg_temp.val('draft', 5) = 1.00000001;
insert into results select 'only the 2 leftovers changed',
  (select count(*) from public.commercial_condition_group_values g join before b using (condition_id, group_id, component_type_id)
   where g.value is distinct from b.value or g.source is distinct from b.source or g.value_kind is distinct from b.value_kind) = 2;
insert into results select 'row count unchanged',
  (select count(*) from public.commercial_condition_group_values) = (select count(*) from before);

-- Fail closed: through the same flag, a value of a published version still cannot change.
select set_config('corban.group_values_rpc', 'on', true);
insert into results select 'published version still immutable',
  pg_temp.err(format($f$update public.commercial_condition_group_values set value = value where condition_id = %L and group_id = %L and component_type_id = %L$f$,
    p.condition_id, p.group_id, p.component_type_id)) like '%published_version_values_are_immutable%'
from picked p where p.status = 'published' and p.n = 1;
select set_config('corban.group_values_rpc', 'off', true);

-- Running it again changes nothing.
create temp table after1 as select * from public.commercial_condition_group_values;
\i /tmp/group_value_rounding.sql
insert into results select 'second run changes nothing',
  not exists (select 1 from public.commercial_condition_group_values g join after1 a using (condition_id, group_id, component_type_id)
              where g.value is distinct from a.value);

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 9 then raise exception 'group value rounding contract failed'; end if;
end $$;

rollback;
