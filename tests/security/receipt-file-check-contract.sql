-- Contract test for 20261020202219_receipt_file_check_v1: before importing a commission report, each contract number says
-- whether it is ready or why not (no seller, not found, already received). Finance only. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/receipt-file-check-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;
create temp table checked (ade text, result text, contract_status text);
grant insert, select on checked to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

insert into made select 'bank', r.org_bank_id
from public.product_table_versions v join public.product_tables t on t.id = v.product_table_id join public.organization_product_routes r on r.id = t.route_id
where v.id = (select tv from ids);

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Conferência', '68999770011', null, 'manual') u;
insert into made select 'with', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-CK-1', 'submitted') d;
insert into made select 'without', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'),
  (select tv from ids), null, 10000, 9500, 250, 120, 'ADE-CK-2', 'submitted') d;
set constraints all immediate; set constraints all deferred;  -- as at commit
insert into checked select * from public.receipt_file_check((select org from ids), 'bank', (select id from made where label = 'bank'), 'upfront',
  array['ADE-CK-1', 'ade ck 2', 'ADE-NAO-EXISTE', '']);
reset role;

insert into results select 'a contract with seller and commission is ready', exists (select 1 from checked where ade = 'ADE-CK-1' and result = 'ready');
insert into results select 'a contract without seller is flagged (number matched as the import does)', exists (select 1 from checked where ade = 'ade ck 2' and result = 'no_seller');
insert into results select 'an unknown number is not found', exists (select 1 from checked where ade = 'ADE-NAO-EXISTE' and result = 'not_found');
insert into results select 'an empty number is left out', (select count(*) = 3 from checked);

select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'a seller gets nothing', not exists (select 1 from public.receipt_file_check((select org from ids), 'bank', (select id from made where label = 'bank'), 'upfront', array['ADE-CK-1']));
reset role;
insert into results select 'anon cannot call it', not has_function_privilege('anon', 'public.receipt_file_check(uuid, text, uuid, text, text[])', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'receipt file check contract failed'; end if;
end $$;
rollback;
