-- Contract test for 20260927400000_legacy_base_v1 (F5.5, ADR-0044): legacy clients and contracts come in by batch with
-- a preview of every row's issue, never duplicate nor change an existing client, respect the cutoff date, stay out of
-- the pipeline, are seen only by whoever sees the client, and a whole batch can be undone.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/legacy-base-contract.sql

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
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.issue(p_row int) returns text language sql as $$
  select coalesce(issue, 'ok') from public.legacy_import_rows where batch_id = (select id from made where label = 'batch') and row_number = p_row
$$;
grant execute on function pg_temp.issue(int) to authenticated;
-- The file of the example: sha of a fixed text.
create function pg_temp.sha() returns text language sql as $$ select encode(sha256(convert_to('base-2tech-exemplo', 'utf8')), 'hex') $$;
grant execute on function pg_temp.sha() to authenticated;
create function pg_temp.rows() returns jsonb language sql as $$
  select jsonb_build_array(
    jsonb_build_object('row', 1, 'cpf', '390.533.447-05', 'full_name', 'Cliente Antigo Novo', 'phone', '(68) 99911-2233', 'bank_name', 'Banco Antigo', 'agreement_name', 'Gov AC',
                       'contract_type', 'Novo', 'ade', 'L-1', 'contract_on', '2025-05-10', 'paid_on', '2025-05-12', 'requested_amount', '10000.00', 'released_amount', '9500.00',
                       'installment_amount', '250.00', 'term', '96', 'seller_name', 'Vendedor Teste', 'status_text', 'PAGO'),
    jsonb_build_object('row', 2, 'cpf', '11144477735', 'full_name', 'Nome Antigo Diferente', 'bank_name', 'Banco Antigo', 'ade', 'L-2', 'contract_on', '2024-01-15', 'requested_amount', '5000'),
    jsonb_build_object('row', 3, 'cpf', '11111111111', 'full_name', 'CPF Inválido', 'ade', 'L-3', 'contract_on', '2025-01-01'),
    jsonb_build_object('row', 4, 'cpf', '12345678909', 'full_name', 'Depois do Corte', 'ade', 'L-4', 'contract_on', '2026-09-10'),
    jsonb_build_object('row', 5, 'cpf', '39053344705', 'full_name', 'Cliente Antigo Novo', 'bank_name', 'Banco Antigo', 'ade', 'l 1', 'contract_on', '2025-06-01'),
    jsonb_build_object('row', 6, 'cpf', '12345678909', 'full_name', 'Só Cadastro Antigo'),
    jsonb_build_object('row', 7, 'cpf', '12345678909', 'full_name', 'Só Cadastro Antigo', 'ade', 'L-7', 'requested_amount', 'abc'),
    jsonb_build_object('row', 8, 'cpf', '12345678909', 'full_name', 'Só Cadastro Antigo', 'ade', 'ADE-LIVE-1', 'contract_on', '2025-02-02'))
$$;
grant execute on function pg_temp.rows() to authenticated;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
-- An existing client (CPF 111.444.777-35) and a contract already in the pipeline (ADE-LIVE-1).
insert into made select 'existing', u.client_id from public.upsert_client((select org from ids), '11144477735', 'Cliente Atual', '68999770020', null, 'manual') u;
insert into made select 'live', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'existing'),
  (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-LIVE-1', 'submitted') d;
insert into results select 'no cutoff date, no import',
  pg_temp.err(format('select public.stage_legacy_rows(%L, null, %L, %L, %L, %L::jsonb)', (select org from ids), '2tech', 'base.xlsx', pg_temp.sha(), pg_temp.rows())) = 'legacy_cutoff_required';
select public.set_legacy_settings((select org from ids), date '2026-09-01', false);
reset role;

select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'a seller cannot import', pg_temp.err(format('select public.stage_legacy_rows(%L, null, %L, %L, %L, %L::jsonb)', (select org from ids), '2tech', 'base.xlsx', pg_temp.sha(), pg_temp.rows())) = 'not_authorized';
insert into results select 'a seller cannot set the cutoff', pg_temp.err(format('select public.set_legacy_settings(%L, %L)', (select org from ids), '2026-01-01')) = 'not_authorized';
reset role;

-- Preview: every row with its issue; nothing written to clients or contracts yet.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'batch', public.stage_legacy_rows((select org from ids), null, '2tech', 'base.xlsx', pg_temp.sha(), pg_temp.rows());
insert into results select 'valid rows have no issue', pg_temp.issue(1) = 'ok' and pg_temp.issue(2) = 'ok' and pg_temp.issue(6) = 'ok';
insert into results select 'invalid CPF refused', pg_temp.issue(3) = 'invalid_cpf';
insert into results select 'contract after the cutoff refused', pg_temp.issue(4) = 'after_cutoff';
insert into results select 'same contract twice in the file refused (ADE written differently)', pg_temp.issue(5) = 'duplicate_contract';
insert into results select 'a non-numeric amount refused', pg_temp.issue(7) = 'invalid_value';
insert into results select 'a contract already in the pipeline refused', pg_temp.issue(8) = 'already_in_corban';
insert into results select 'batch counts 8 rows, 5 with issue',
  (select rows_total = 8 and rows_with_issue = 5 and status = 'draft' from public.legacy_import_batches where id = (select id from made where label = 'batch'));
insert into results select 'nothing written before confirmation',
  not exists (select 1 from public.clients where cpf in ('39053344705', '12345678909')) and not exists (select 1 from public.legacy_contracts);

-- Confirmation.
select public.confirm_legacy_batch((select id from made where label = 'batch'));
insert into results select 'two clients created, one linked, two contracts',
  (select clients_created = 2 and clients_matched = 1 and contracts_created = 2 and status = 'confirmed' from public.legacy_import_batches where id = (select id from made where label = 'batch'));
insert into results select 'the existing client was not changed',
  (select full_name = 'Cliente Atual' and legacy_batch_id is null from public.clients where id = (select id from made where label = 'existing'));
insert into results select 'new clients are marked legacy with the batch',
  (select count(*) = 2 from public.clients where cpf in ('39053344705', '12345678909') and original_source = 'legacy:2tech' and legacy_batch_id = (select id from made where label = 'batch'));
insert into results select 'the historical contract keeps its data',
  exists (select 1 from public.legacy_contracts where ade = 'L-1' and requested_amount = 10000.00 and term = 96 and paid_on = date '2025-05-12' and status_text = 'PAGO');
insert into results select 'nothing enters the pipeline', (select count(*) from public.proposals_v2 where organization_id = (select org from ids) and external_proposal_id in ('L-1', 'L-2')) = 0;
insert into results select 'the same file is not imported twice',
  pg_temp.err(format('select public.stage_legacy_rows(%L, null, %L, %L, %L, %L::jsonb)', (select org from ids), '2tech', 'base.xlsx', pg_temp.sha(), pg_temp.rows())) = 'legacy_file_already_imported';
insert into results select 'legacy contracts cannot be written directly',
  pg_temp.err(format('insert into public.legacy_contracts (organization_id, batch_id, client_id, source_system) values (%L, %L, %L, %L)',
    (select org from ids), (select id from made where label = 'batch'), (select id from made where label = 'existing'), 'x')) <> 'ok';
reset role;

-- Visibility: the seller's old client (seller name matches their registration) is theirs; the other is not.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'the seller sees their old client and its contract',
  exists (select 1 from public.clients where cpf = '39053344705') and exists (select 1 from public.legacy_contracts where ade = 'L-1');
insert into results select 'the seller does not see an old client of someone else', not exists (select 1 from public.clients where cpf = '12345678909');
insert into results select 'a seller cannot undo a batch',
  pg_temp.err(format('select public.undo_legacy_batch(%L, %L)', (select id from made where label = 'batch'), 'teste')) = 'not_authorized';
reset role;

-- Undo: the contracts go, the clients created and untouched go, the existing client stays.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'undo needs a reason', pg_temp.err(format('select public.undo_legacy_batch(%L, %L)', (select id from made where label = 'batch'), '')) = 'reason_required';
select public.undo_legacy_batch((select id from made where label = 'batch'), 'arquivo errado');
insert into results select 'undo removes the batch contracts', not exists (select 1 from public.legacy_contracts where batch_id = (select id from made where label = 'batch'));
insert into results select 'undo removes the clients it created', not exists (select 1 from public.clients where cpf in ('39053344705', '12345678909') and deleted_at is null);
insert into results select 'undo keeps the existing client', exists (select 1 from public.clients where id = (select id from made where label = 'existing') and deleted_at is null);
insert into results select 'batch marked undone with the reason',
  (select status = 'undone' and undo_reason = 'arquivo errado' from public.legacy_import_batches where id = (select id from made where label = 'batch'));
insert into results select 'after an undo the file can come again',
  pg_temp.err(format('select public.stage_legacy_rows(%L, null, %L, %L, %L, %L::jsonb)', (select org from ids), '2tech', 'base.xlsx', pg_temp.sha(), pg_temp.rows())) = 'ok';
reset role;
insert into results select 'anon has no access to the legacy tables',
  not has_table_privilege('anon', 'public.legacy_contracts', 'select') and not has_table_privilege('anon', 'public.legacy_import_rows', 'select')
  and not has_function_privilege('anon', 'public.stage_legacy_rows(uuid,uuid,text,text,text,jsonb)', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 27 then raise exception 'legacy base contract failed'; end if;
end $$;

rollback;
