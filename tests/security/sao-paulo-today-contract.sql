-- Contract test for 20261020031521_sao_paulo_today_v1: every function that reads "today" (current_date, now()::date,
-- localtimestamp, date_trunc) runs with the São Paulo time zone, so between 21:00 and midnight in Brasília "today" is
-- not already tomorrow. A "create or replace" that drops the SET clause makes this test fail. Read only.
--   psql -v ON_ERROR_STOP=1 -f tests/security/sao-paulo-today-contract.sql

begin;
create temp table results (check_name text, ok boolean);
create temp table missing as
select n.nspname || '.' || p.proname as fn
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname in ('public', 'private')
  and p.prosrc ~* 'current_date|now\(\)::date|localtimestamp|date_trunc\('
  and not exists (select 1 from unnest(p.proconfig) c where lower(c) = lower('TimeZone=America/Sao_Paulo'));

insert into results select 'every function reading today runs in São Paulo time' || coalesce(' (missing: ' || (select string_agg(fn, ', ') from missing) || ')', ''),
  not exists (select 1 from missing);
insert into results select 'the bank account opening date defaults to the São Paulo date',
  (select column_default ~* 'America/Sao_Paulo' from information_schema.columns
   where table_schema = 'public' and table_name = 'fin_bank_accounts' and column_name = 'opening_on');

-- Behavior: inside such a function, today is the São Paulo date even when the session runs in UTC.
set local timezone to 'UTC';
create function pg_temp.today_sp() returns date language sql set timezone to 'America/Sao_Paulo' as $$ select current_date $$;
insert into results select 'the SET clause gives the São Paulo date in a UTC session',
  pg_temp.today_sp() = (now() at time zone 'America/Sao_Paulo')::date;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'sao paulo today contract failed'; end if;
end $$;
rollback;
