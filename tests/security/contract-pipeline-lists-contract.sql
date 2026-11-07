-- Contract test for 20261107001252_contract_pipeline_lists_v1: Esteira (pipeline_case_list) and Contratos (contract_list)
-- read, filter, page and sum in the database through the caller's RLS; money leaves as text; the search ignores accents;
-- commission values only reach finance; a seller without financeiro.view still lists contracts (no error); another
-- company's id returns nothing; clients.search_name is folded. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/contract-pipeline-lists-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as seller_user;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;
create temp table snap (label text, j jsonb);
grant insert, select on snap to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.id(p_label text) returns uuid language sql as $$ select id from made where label = p_label $$;
grant execute on function pg_temp.id(text) to authenticated;
create function pg_temp.case_of(p_label text) returns uuid language sql security definer as $$
  select c.id from public.operational_cases c where c.proposal_id = (select id from made where label = p_label) $$;
grant execute on function pg_temp.case_of(text) to authenticated;
create function pg_temp.stage(p_state text) returns uuid language sql security definer as $$
  select s.id from public.operational_stages s where s.organization_id = '00000000-0000-4000-8000-00000000c0b1' and s.canonical_state = p_state and s.is_active order by s.sort_order limit 1 $$;
grant execute on function pg_temp.stage(text) to authenticated;
-- What the company receives on the open test contracts, summed straight from the lines (the reference for the totals).
create function pg_temp.received_ref() returns numeric language sql security definer as $$
  select coalesce(sum(l.amount * l.multiplier), 0) from public.proposal_commission_lines l
  join public.proposal_commission_calcs k on k.id = l.calc_id
  where k.status = 'active' and l.line_kind = 'received' and k.proposal_id in (select id from made where label in ('a', 'c')) $$;
grant execute on function pg_temp.received_ref() to authenticated;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '11144477735', 'João Lista Teste', '68999770042', null, 'manual') u;
insert into made select 'a', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.id('client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'LSTX-1', 'submitted') d;
insert into made select 'b', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.id('client'), (select tv from ids), (select seller from ids), 20000, 19000, 500, 120, 'LSTX-2', 'submitted') d;
insert into made select 'c', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.id('client'), (select tv from ids), (select seller from ids), 30000, 28500, 750, 120, 'LSTX-3', 'submitted') d;
reset role;
set constraints all immediate; set constraints all deferred;  -- as at commit (contracts are born calculated)

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'cancel b', pg_temp.err(format('select public.move_case_to_stage(%L::uuid, %L::uuid, %L, null, null)', pg_temp.case_of('b'), pg_temp.stage('cancelled'), 'Cliente desistiu')) = 'ok';
insert into snap select 'admin_list', public.contract_list((select org from ids), '{"q":"lstx"}'::jsonb, 25, 1) as j;
insert into snap select 'admin_accent', public.contract_list((select org from ids), '{"q":"JOAO lista"}'::jsonb, 25, 1) as j;
insert into snap select 'admin_closed', public.contract_list((select org from ids), '{"q":"lstx","encerradas":"1"}'::jsonb, 1, 99) as j;
insert into snap select 'admin_cancelled', public.contract_list((select org from ids), '{"q":"lstx","situacao":"cancelled"}'::jsonb, 25, 1) as j;
insert into snap select 'admin_other_org', public.contract_list(gen_random_uuid(), '{}'::jsonb, 25, 1) as j;
insert into snap select 'admin_pipe', public.pipeline_case_list((select org from ids), '{"q":"lstx"}'::jsonb, 500) as j;
insert into snap select 'admin_pipe_cap', public.pipeline_case_list((select org from ids), '{"q":"lstx"}'::jsonb, 1) as j;
insert into snap select 'admin_pipe_cancel', public.pipeline_case_list((select org from ids), jsonb_build_object('q', 'jose', 'stage', pg_temp.stage('cancelled')), 500) as j;
insert into snap select 'admin_pipe_stage', public.pipeline_case_list((select org from ids), jsonb_build_object('q', 'joão', 'stage', pg_temp.stage('cancelled')), 500) as j;
insert into snap select 'admin_pipe_noseller', public.pipeline_case_list((select org from ids), '{"q":"lstx","vendedor":"none"}'::jsonb, 500) as j;
reset role;

insert into results select 'contracts: closed hidden by default, counted apart',
  (select (j->>'total')::int = 2 and (j->>'hidden_closed')::int = 1 from (select j from snap where label = 'admin_list') admin_list);
insert into results select 'contracts: newest first, one page of rows',
  (select jsonb_array_length(j->'rows') = 2 and j->'rows'->0->>'external_proposal_id' = 'LSTX-3' from (select j from snap where label = 'admin_list') admin_list);
insert into results select 'contracts: search without accents or case finds the client',
  (select (j->>'total')::int = 2 from (select j from snap where label = 'admin_accent') admin_accent);
insert into results select 'contracts: money leaves as text',
  (select jsonb_typeof(j->'sums'->'received') = 'string' and jsonb_typeof(j->'sums'->'requested') = 'string'
          and jsonb_typeof(j->'rows'->0->'requested_amount') = 'string' from (select j from snap where label = 'admin_list') admin_list);
insert into results select 'contracts: gross total summed in the database',
  (select (j->'sums'->>'requested')::numeric = 40000 from (select j from snap where label = 'admin_list') admin_list);
insert into results select 'contracts: company receives = sum of the lines',
  (select (j->'sums'->>'received')::numeric = pg_temp.received_ref() from (select j from snap where label = 'admin_list') admin_list);
insert into results select 'contracts: commission is calculated on the rows (finance)',
  (select bool_and((r->>'has_calc')::boolean) from (select j from snap where label = 'admin_list') admin_list, jsonb_array_elements(j->'rows') r);
insert into results select 'contracts: page past the end comes back as the last page',
  (select (j->>'page')::int = 3 and (j->>'total')::int = 3 and jsonb_array_length(j->'rows') = 1 from (select j from snap where label = 'admin_closed') admin_closed);
insert into results select 'contracts: Cancelada filter shows the cancelled one',
  (select (j->>'total')::int = 1 and j->'rows'->0->>'situation' = 'cancelled' from (select j from snap where label = 'admin_cancelled') admin_cancelled);
insert into results select 'contracts: another company returns nothing',
  (select (j->>'total')::int = 0 and not (j->>'any')::boolean from (select j from snap where label = 'admin_other_org') admin_other_org);
insert into results select 'esteira: open cases, closed counted per stage',
  (select (j->>'total')::int = 2 and (j->>'open')::int = 2 and (j->'counts'->>(pg_temp.stage('cancelled'))::text)::int = 1 from (select j from snap where label = 'admin_pipe') admin_pipe);
insert into results select 'esteira: cap keeps the total (never a silent cut)',
  (select (j->>'total')::int = 2 and jsonb_array_length(j->'rows') = 1 from (select j from snap where label = 'admin_pipe_cap') admin_pipe_cap);
insert into results select 'esteira: amounts as text, seller joined',
  (select jsonb_typeof(j->'rows'->0->'released_amount') = 'string' and j->'rows'->0->>'seller_name' is not null from (select j from snap where label = 'admin_pipe') admin_pipe);
insert into results select 'esteira: stage tab with accented search',
  (select (j->>'total')::int = 1 from (select j from snap where label = 'admin_pipe_stage') admin_pipe_stage) and (select (j->>'total')::int = 0 from (select j from snap where label = 'admin_pipe_cancel') admin_pipe_cancel);
insert into results select 'esteira: "sem vendedor" filter',
  (select (j->>'total')::int = 0 from (select j from snap where label = 'admin_pipe_noseller') admin_pipe_noseller);

-- A seller without financeiro.view: lists without error, never sees commission values.
select pg_temp.act_as((select seller_user from ids));
set local role authenticated;
insert into results select 'seller: contract_list runs without finance',
  pg_temp.err(format('select public.contract_list(%L::uuid, %L::jsonb, 25, 1)', (select org from ids), '{"q":"lstx"}')) = 'ok';
insert into results select 'seller is not finance', not public.has_permission((select org from ids), 'financeiro.view');
insert into snap select 'seller_list', public.contract_list((select org from ids), '{"q":"lstx","encerradas":"1"}'::jsonb, 25, 1) as j;
reset role;
insert into results select 'seller: no commission values',
  (select (j->'sums'->>'received')::numeric = 0 and (j->'sums'->>'payable')::numeric = 0
          and coalesce(bool_and(not (r->>'has_calc')::boolean and r->>'received' is null), true)
   from (select j from snap where label = 'seller_list') seller_list left join lateral jsonb_array_elements(j->'rows') r on true group by j);


insert into results select 'clients.search_name folds the name',
  (select search_name = 'joao lista teste' from public.clients where id = pg_temp.id('client'));
insert into results select 'anon runs none of them',
  not has_function_privilege('anon', 'public.contract_list(uuid,jsonb,integer,integer)', 'execute')
  and not has_function_privilege('anon', 'public.pipeline_case_list(uuid,jsonb,integer)', 'execute');
insert into results select 'both run as the caller (RLS applies)',
  (select bool_and(not prosecdef) from pg_proc where oid in ('public.contract_list(uuid,jsonb,integer,integer)'::regprocedure, 'public.pipeline_case_list(uuid,jsonb,integer)'::regprocedure));

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 21 then raise exception 'contract pipeline lists contract failed'; end if;
end $$;

rollback;
