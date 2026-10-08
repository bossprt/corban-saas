-- Tenant isolation sweep (07/10/2026, before the first client company): a second company and its administrator are
-- created, and logged in as that administrator:
--   1. every public table with organization_id is read: no row of the first company may come back;
--   2. every public function the app can call is called with the ids of the first company (organization, contract,
--      client, seller, account...): it must be refused, or return nothing of the first company and change nothing.
-- Each call runs in its own subtransaction that is always undone. The report lists every call that was not refused,
-- with what it returned, so a person reviews it; the run fails if any table read leaks or a call returns the first
-- company's data or changes it. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/tenant-isolation-sweep.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org_a,
       '00000000-0000-4000-8000-0000000b0b01'::uuid as org_b,
       '00000000-0000-4000-8000-0000000b0b02'::uuid as admin_b;
grant select on ids to authenticated;

-- Company B and its administrator.
insert into public.organizations (id, name, document, plan_type, is_active)
select org_b, 'Empresa B Isolamento', 'isolamento-' || gen_random_uuid(), 'starter', true from ids;
insert into auth.users (id, email, aud, role) select admin_b, 'admin.b@isolamento.local', 'authenticated', 'authenticated' from ids;
select set_config('corban.membership_rpc', 'on', true);
insert into public.organization_memberships (organization_id, user_id, role, status) select org_b, admin_b, 'admin', 'active' from ids;
select set_config('corban.membership_rpc', 'off', true);

-- One id of each kind from company A, to hand to B's calls.
create temp table a_ids (kind text primary key, id uuid);
grant select on a_ids to authenticated;
insert into a_ids select 'org', org_a from ids;
do $$
declare r record; v uuid;
begin
  for r in select * from (values
    ('proposal', 'proposals_v2', 'id', 'order by created_at'),
    ('client', 'clients', 'id', 'order by created_at'),
    ('seller', 'commercial_sellers', 'id', 'order by created_at'),
    ('payout_account', 'payout_accounts', 'id', ''),
    ('payout', 'payouts', 'id', ''),
    ('payout_entry', 'payout_entries', 'id', ''),
    ('fin_entry', 'fin_entries', 'id', ''),
    ('fin_bank', 'fin_bank_accounts', 'id', ''),
    ('fin_chart', 'fin_chart_accounts', 'id', 'and not is_group'),
    ('report', 'receipt_reports', 'id', ''),
    ('receipt', 'commission_receipts', 'id', ''),
    ('receipt_line', 'receipt_lines', 'id', ''),
    ('lead', 'leads', 'id', ''),
    ('membership', 'organization_memberships', 'id', ''),
    ('user', 'organization_memberships', 'user_id', 'and role = ''admin'''),
    ('version', 'product_table_versions', 'id', ''),
    ('table', 'product_tables', 'id', ''),
    ('condition', 'commercial_conditions', 'id', ''),
    ('group', 'commission_groups', 'id', ''),
    ('stage', 'operational_stages', 'id', ''),
    ('case', 'operational_cases', 'id', ''),
    ('role', 'organization_roles', 'id', ''),
    ('branch', 'organization_branches', 'id', ''),
    ('bank', 'organization_banks', 'id', ''),
    ('agreement', 'organization_agreements', 'id', ''),
    ('provider', 'organization_providers', 'id', ''),
    ('route', 'organization_product_routes', 'id', ''),
    ('invitation', 'organization_invitations', 'id', ''),
    ('simulation', 'simulations', 'id', ''),
    ('submission', 'proposal_submissions', 'id', ''),
    ('campaign', 'lead_campaigns', 'id', ''),
    ('goal', 'sales_goals', 'id', ''),
    ('legacy', 'legacy_imports', 'id', '')
  ) x(kind, tbl, col, extra) loop
    begin
      execute format('select %I from public.%I where organization_id = %L %s limit 1', r.col, r.tbl, (select org_a from ids), r.extra) into v;
      if v is not null then insert into a_ids values (r.kind, v); end if;
    exception when undefined_table or undefined_column then null;  -- not in this schema
    end;
  end loop;
end $$;

-- A fingerprint of company A: count of rows and of updated_at per table, to see whether a call changed anything.
create temp table tables_with_org as
select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r','p')
  and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'organization_id' and not a.attisdropped);
grant select on tables_with_org to authenticated;
create function pg_temp.fingerprint_a() returns text language plpgsql as $$
declare t record; s text := ''; v text;
begin
  for t in select relname from tables_with_org order by 1 loop
    execute format('select count(*)::text || ''/'' || coalesce(md5(string_agg(x::text, '''' order by x::text)), '''') from public.%I x where organization_id = %L',
                   t.relname, (select org_a from ids)) into v;
    s := s || t.relname || '=' || v || ';';
  end loop;
  return md5(s);
end $$;
create temp table fp as select pg_temp.fingerprint_a() as before;

create temp table read_leaks (tbl text, rows_of_a bigint);
grant insert, select on read_leaks to authenticated;
create temp table calls (fn text, outcome text, detail text);
grant insert, select on calls to authenticated;

select set_config('request.jwt.claims', json_build_object('sub', (select admin_b from ids), 'role', 'authenticated')::text, true);
select set_config('corban.active_org', (select org_b::text from ids), true);
set local role authenticated;

-- 1. Reads.
do $$
declare t record; n bigint;
begin
  for t in select relname from tables_with_org order by 1 loop
    begin
      execute format('select count(*) from public.%I where organization_id = %L', t.relname, (select org_a from ids)) into n;
      if n > 0 then insert into read_leaks values (t.relname, n); end if;
    exception when insufficient_privilege then null;  -- no grant at all: nothing can leak
    end;
  end loop;
end $$;

-- 2. Calls.
do $$
declare
  f record; a record; args text[]; call text; res text; i int; nm text; ty text; v text; idk text;
  uuid_kinds text[][] := array[
    ['bank_account','fin_bank'], ['chart','fin_chart'], ['fin_entry','fin_entry'], ['entry','payout_entry'],
    ['payout','payout'], ['account','payout_account'], ['proposal','proposal'], ['contract','proposal'], ['client','client'],
    ['customer','client'], ['seller','seller'], ['report','report'], ['receipt','receipt'], ['line','receipt_line'],
    ['lead','lead'], ['membership','membership'], ['user','user'], ['leader','user'], ['version','version'], ['condition','condition'],
    ['table','table'], ['group','group'], ['stage','stage'], ['case','case'], ['role','role'], ['branch','branch'],
    ['bank','bank'], ['agreement','agreement'], ['provider','provider'], ['source','bank'], ['route','route'],
    ['invitation','invitation'], ['simulation','simulation'], ['submission','submission'], ['campaign','campaign'],
    ['goal','goal'], ['legacy','legacy'], ['org','org'], ['keep','version']];
begin
  for f in
    select p.oid, p.oid::regprocedure::text as sig, p.proname, p.pronargs, p.proargnames, p.proargtypes, p.proretset
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f' and has_function_privilege('authenticated', p.oid, 'execute')
      and pg_get_function_result(p.oid) not in ('trigger', 'event_trigger')
      and p.proname not like 'pg\_%' and p.proname not in ('fingerprint_a')
      -- read-only helpers about the caller's own access
      and p.proname not in ('is_active_organization_member', 'has_active_organization_role', 'has_permission', 'get_user_organization_id')
    order by 2
  loop
    args := '{}';
    for i in 0 .. f.pronargs - 1 loop
      nm := coalesce(f.proargnames[i + 1], '');
      ty := format_type(f.proargtypes[i], null);
      v := null;
      if ty = 'uuid' then
        idk := null;
        for j in 1 .. array_length(uuid_kinds, 1) loop
          if nm like '%' || uuid_kinds[j][1] || '%' then idk := uuid_kinds[j][2]; exit; end if;
        end loop;
        v := coalesce(quote_literal((select id from a_ids where kind = coalesce(idk, 'org'))), 'null') || '::uuid';
      elsif ty = 'uuid[]' then
        v := format('array[%L]::uuid[]', (select id from a_ids where kind = 'proposal'));
      elsif ty in ('text', 'character varying') then v := quote_literal('x');
      elsif ty = 'text[]' then v := 'array[''x'']::text[]';
      elsif ty in ('numeric', 'integer', 'bigint', 'smallint', 'double precision', 'real') then v := '1::' || ty;
      elsif ty = 'boolean' then v := 'false';
      elsif ty = 'date' then v := 'current_date';
      elsif ty like 'timestamp%' then v := 'now()';
      elsif ty in ('jsonb', 'json') then v := case when nm ~ '(rows|items|lines|values|entries|list)' then '''[]''::' || ty else '''{}''::' || ty end;
      else v := 'null::' || ty;
      end if;
      args := args || v;
    end loop;
    call := format('public.%I(%s)', f.proname, array_to_string(args, ', '));
    begin
      execute format('select left((select string_agg(coalesce(t::text, ''''), %L) from %s t), 300)', ' ; ', call) into res;
      raise exception 'probe_rollback:%', coalesce(res, '');
    exception when others then
      if sqlerrm like 'probe_rollback:%' then
        insert into calls values (f.sig, 'accepted', substr(sqlerrm, 16));
      else
        insert into calls values (f.sig, 'refused', left(sqlerrm, 120));
      end if;
    end;
  end loop;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- What company A looks like in text, to find its data in what B's calls returned.
create temp table a_marks as
select id::text as mark from a_ids where kind <> 'org'
union select org_a::text from ids;

select 'READ LEAK' as kind, tbl as name, rows_of_a::text as detail from read_leaks
union all
select 'ACCEPTED' || case when exists (select 1 from a_marks m where c.detail like '%' || m.mark || '%') then ' + RETURNED A DATA' else '' end,
       fn, detail from calls c where outcome = 'accepted'
order by 1, 2;
select outcome, count(*) from calls group by 1;

do $$ begin
  if exists (select 1 from read_leaks) then raise exception 'tenant isolation: company B read rows of company A'; end if;
  if exists (select 1 from calls c join a_marks m on c.outcome = 'accepted' and c.detail like '%' || m.mark || '%') then
    raise exception 'tenant isolation: a call of company B returned data of company A';
  end if;
  if (select before from fp) is distinct from pg_temp.fingerprint_a() then raise exception 'tenant isolation: company A changed'; end if;
end $$;
rollback;
