-- Contract test for 20261013045254_api_contracts_v1 and 20261013055148_nasp_commission_base_v1 (ADR-0056): POST /api/v1/contracts. A key with contracts.write acts as
-- the administrator who created it; the contract is found by the sender's external_id; an old or repeated call changes
-- nothing; the ADE arrives later; stages follow the sender until the contract is closed; money is exact.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/api-contracts-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1;
create temp table results (check_name text, ok boolean);
create temp table calls (label text, r jsonb);
grant select on ids to service_role;
grant insert, select on calls to service_role;

-- Fixture: the test table becomes "NASP T - Gov - Temporário (8 a 18 meses)" and also takes contract type "novo",
-- 8 to 120 months. Published data is immutable, so the guards are bypassed for this setup only.
set local session_replication_role = replica;
update public.product_tables set name = 'NASP T - Gov - Temporário (8 a 18 meses)'
where id = (select product_table_id from public.product_table_versions where id = (select tv from ids));
insert into public.commercial_conditions
select (jsonb_populate_record(null::public.commercial_conditions, to_jsonb(c) || jsonb_build_object(
  'id', gen_random_uuid(), 'contract_type_id', (select id from public.contract_types where tech_key = 'novo' and organization_id is null),
  'term_min', 8, 'term_max', 120))).*
from public.commercial_conditions c where c.product_table_version_id = (select tv from ids) limit 1;
set local session_replication_role = origin;

insert into public.api_keys (organization_id, name, prefix, key_hash, scopes, created_by) select org, 'NASP', 'ck_live_nasp_tes',
  encode(extensions.digest('ck_live_nasp_test_key_000000000000', 'sha256'), 'hex'), array['contracts.write'], admin_user from ids;
insert into public.api_keys (organization_id, name, prefix, key_hash, scopes, created_by) select org, 'Leads', 'ck_live_leads_te',
  encode(extensions.digest('ck_live_leads_only_key_00000000000', 'sha256'), 'hex'), array['leads.write'], admin_user from ids;
insert into public.api_keys (organization_id, name, prefix, key_hash, scopes, created_by) select org, 'Vendedor', 'ck_live_seller_t',
  encode(extensions.digest('ck_live_seller_owned_key_000000000', 'sha256'), 'hex'), array['contracts.write'], v1 from ids;

-- Base call; each step overrides what it needs.
create function pg_temp.body(p_seq int, p_stage text, p_extra jsonb default '{}'::jsonb) returns text language sql as $$
  select (jsonb_build_object(
    'external_id', 'c9e8662f-892e-4f99-a677-8e8d6205646e', 'sequencia', p_seq, 'enviado_em', '2026-10-12T14:03:22-03:00',
    'etapa', jsonb_build_object('codigo_nasp', p_stage, 'pago_ao_cliente_em', null, 'observacao', null),
    'contrato', jsonb_build_object('banco', 'Banco Teste', 'ade', null, 'numero_interno', '202600011', 'tipo_operacao', 'novo',
      'convenio', 'Governo', 'tabela', 'Temporário (8 a 18 meses)', 'prazo_meses', 12, 'valor_liberado', 5000.00,
      'valor_liquido_cliente', 5000.00, 'valor_parcela', 692.84),
    'vendedor', jsonb_build_object('parceiro', 'SMART PROMOTORA LTDA', 'agente', 'vendedor teste'),
    'cliente', jsonb_build_object('cpf', '111.444.777-35', 'nome', 'Cliente Api Nasp', 'celular', '(68) 99977-1234', 'email', 'nao-e-email',
      'data_nascimento', '1980-01-31', 'sexo', 'Feminino', 'estado_civil', 'Casada', 'naturalidade', 'Rio Branco/AC', 'nome_mae', 'Mae Do Cliente',
      'rg', '123456', 'rg_orgao_emissor', 'SSP', 'rg_uf', 'ac',
      'endereco', jsonb_build_object('cep', '69900-000', 'logradouro', 'Rua A', 'numero', '10', 'bairro', 'Centro', 'cidade', 'Rio Branco', 'uf', 'AC'),
      'matricula', jsonb_build_object('numero', '998877', 'secretaria', 'SEE'),
      'conta_bancaria', jsonb_build_object('banco_codigo', '1', 'banco_nome', 'Banco do Brasil', 'agencia', '1234', 'conta', '56789', 'conta_digito', 'x', 'tipo', 'Corrente')))
    || p_extra)::text
$$;
create function pg_temp.with_contract(p_seq int, p_stage text, p_contract jsonb, p_extra jsonb default '{}'::jsonb) returns text language sql as $$
  select jsonb_set(pg_temp.body(p_seq, p_stage, p_extra)::jsonb, '{contrato}', (pg_temp.body(p_seq, p_stage)::jsonb->'contrato') || p_contract)::text
$$;
grant execute on function pg_temp.body(int, text, jsonb) to service_role;
grant execute on function pg_temp.with_contract(int, text, jsonb, jsonb) to service_role;
create function pg_temp.call(p_label text, p_key text, p_body text) returns jsonb language sql as $$
  insert into calls values (p_label, public.api_ingest_contract(p_key, p_body)) returning r
$$;
grant execute on function pg_temp.call(text, text, text) to service_role;

set local role service_role;
select pg_temp.call('bad_key', 'ck_live_wrong_key_0000000000000000', pg_temp.body(1, 'digitado'));
select pg_temp.call('leads_key', 'ck_live_leads_only_key_00000000000', pg_temp.body(1, 'digitado'));
select pg_temp.call('seller_key', 'ck_live_seller_owned_key_000000000', pg_temp.body(1, 'digitado'));
select pg_temp.call('bad_json', 'ck_live_nasp_test_key_000000000000', '{not json');
select pg_temp.call('bad_stage', 'ck_live_nasp_test_key_000000000000', pg_temp.body(1, 'inventada'));
select pg_temp.call('bad_table', 'ck_live_nasp_test_key_000000000000', pg_temp.with_contract(1, 'digitado', '{"tabela": "Não existe"}'));
select pg_temp.call('bad_type', 'ck_live_nasp_test_key_000000000000', pg_temp.with_contract(1, 'digitado', '{"tipo_operacao": "refinanciamento"}'));
select pg_temp.call('bad_term', 'ck_live_nasp_test_key_000000000000', pg_temp.with_contract(1, 'digitado', '{"prazo_meses": 200}'));
select pg_temp.call('bad_money', 'ck_live_nasp_test_key_000000000000', pg_temp.with_contract(1, 'digitado', '{"valor_liberado": "5.000,00"}'));
select pg_temp.call('bad_money3', 'ck_live_nasp_test_key_000000000000', pg_temp.with_contract(1, 'digitado', '{"valor_liberado": 10.005}'));
select pg_temp.call('net_above_gross', 'ck_live_nasp_test_key_000000000000', pg_temp.with_contract(1, 'digitado', '{"valor_liquido_cliente": "6000.00"}'));
select pg_temp.call('bad_bank', 'ck_live_nasp_test_key_000000000000', pg_temp.with_contract(1, 'digitado', '{"banco": "Outro"}'));
select pg_temp.call('bad_cpf', 'ck_live_nasp_test_key_000000000000', pg_temp.body(1, 'digitado', '{"cliente": {"cpf": "11111111111", "nome": "X"}}'));
select pg_temp.call('paid_no_date', 'ck_live_nasp_test_key_000000000000', pg_temp.body(1, 'credito_liberado'));
select pg_temp.call('create', 'ck_live_nasp_test_key_000000000000', pg_temp.body(1, 'digitado'));
select pg_temp.call('repeat', 'ck_live_nasp_test_key_000000000000', pg_temp.body(1, 'digitado'));
select pg_temp.call('ade', 'ck_live_nasp_test_key_000000000000', pg_temp.with_contract(3, 'em_averbacao', '{"ade": "2749927"}'));
select pg_temp.call('old', 'ck_live_nasp_test_key_000000000000', pg_temp.body(2, 'recusado'));
select pg_temp.call('pending', 'ck_live_nasp_test_key_000000000000', pg_temp.with_contract(4, 'pendente', '{"ade": "2749927"}',
  '{"etapa": {"codigo_nasp": "pendente", "observacao": "Falta contracheque"}}'));
select pg_temp.call('approved', 'ck_live_nasp_test_key_000000000000', pg_temp.with_contract(5, 'aguardando_pagamento', '{"ade": "2749927", "valor_liberado": "5100.50"}'));
select pg_temp.call('paid', 'ck_live_nasp_test_key_000000000000', pg_temp.with_contract(6, 'credito_liberado', '{"ade": "2749927", "valor_liberado": "5100.50"}',
  jsonb_build_object('etapa', jsonb_build_object('codigo_nasp', 'credito_liberado', 'pago_ao_cliente_em', current_date - 1))));
select pg_temp.call('cancel_after_paid', 'ck_live_nasp_test_key_000000000000', pg_temp.with_contract(7, 'cancelado', '{"ade": "2749927"}'));
-- A second contract: the agent is unknown, so it comes without seller.
select pg_temp.call('no_seller', 'ck_live_nasp_test_key_000000000000', pg_temp.body(1, 'digitado',
  '{"external_id": "second-contract", "vendedor": {"agente": "Fulano Inexistente"}}'));
reset role;

create temp table r as select label, r from calls;
create temp table pid as select (r->>'id')::uuid id from r where label = 'create';

insert into results select 'a wrong key is refused', (select r->>'error' = 'invalid_api_key' from r where label = 'bad_key');
insert into results select 'a leads key cannot send contracts', (select r->>'error' = 'insufficient_scope' from r where label = 'leads_key');
insert into results select 'a key whose owner is not an administrator is refused', (select r->>'error' = 'api_key_owner_inactive' from r where label = 'seller_key');
insert into results select 'bad JSON is refused', (select r->>'error' = 'invalid_json' from r where label = 'bad_json');
insert into results select 'unknown stage', (select r->>'error' = 'stage_unknown' from r where label = 'bad_stage');
insert into results select 'unknown table', (select r->>'error' = 'table_not_found' from r where label = 'bad_table');
insert into results select 'type the table does not have', (select r->>'error' = 'table_not_found' from r where label = 'bad_type');
insert into results select 'term outside the table', (select r->>'error' = 'term_out_of_table' from r where label = 'bad_term');
insert into results select 'money in Brazilian format is refused (dot decimal only)', (select r->>'error' = 'invalid_amount' from r where label = 'bad_money');
insert into results select 'money with 3 decimals is refused', (select r->>'error' = 'invalid_amount' from r where label = 'bad_money3');
insert into results select 'net above gross is refused', (select r->>'error' = 'invalid_amount' from r where label = 'net_above_gross');
insert into results select 'unknown bank', (select r->>'error' = 'bank_not_found' from r where label = 'bad_bank');
insert into results select 'invalid CPF', (select r->>'error' = 'invalid_cpf' from r where label = 'bad_cpf');
insert into results select 'paid without the payment date', (select r->>'error' = 'paid_on_required' from r where label = 'paid_no_date');
insert into results select 'refused calls wrote nothing', (select count(*) = 2 from public.api_contract_links where organization_id = (select org from ids));

insert into results select 'first call creates the contract (201)', (select (r->>'created')::boolean and r->>'stage' = 'submitted' from r where label = 'create');
insert into results select 'the same call again changes nothing', (select (r->>'duplicate')::boolean and not (r->>'stale')::boolean and r->>'id' = (select id::text from pid) from r where label = 'repeat');
insert into results select 'the seller is the agent, found by name', (select seller_id = '00000000-0000-4000-8000-0000000c0801' from public.proposals_v2 where id = (select id from pid));
insert into results select 'the ADE arrives later on the same contract', (select external_proposal_id = '2749927' from public.proposals_v2 where id = (select id from pid));
insert into results select 'an older call is ignored', (select (r->>'stale')::boolean from r where label = 'old')
  and (select status <> 'rejected' from public.proposals_v2 where id = (select id from pid));
insert into results select 'pendency carries the sender note', (select r->>'stage' = 'pending_external' from r where label = 'pending')
  and exists (select 1 from public.operational_events e join public.operational_cases c on c.id = e.operational_case_id
              where c.proposal_id = (select id from pid) and e.to_state = 'pending_external' and e.metadata->>'note' = 'Falta contracheque');
insert into results select 'an open contract follows new values, exactly (gross = contract amount, net = released)', (select r->>'stage' = 'approved' from r where label = 'approved')
  and (select requested_amount = 5100.50 and released_amount = 5000.00 and installment_amount = 692.84 from public.proposals_v2 where id = (select id from pid));
insert into results select 'paid with the date', (select r->>'stage' = 'paid' from r where label = 'paid')
  and (select status = 'paid' and paid_to_client_on = current_date - 1 from public.proposals_v2 where id = (select id from pid));
insert into results select 'cancel after paid does not move the contract, it leaves a note',
  (select r->>'stage' = 'paid' and r->'warnings' ? 'stage_locked' from r where label = 'cancel_after_paid')
  and exists (select 1 from public.contract_events e where e.proposal_id = (select id from pid) and e.kind = 'note');
insert into results select 'the link keeps the last call applied', (select last_sequence = 7 and last_external_stage = 'cancelado' from public.api_contract_links where proposal_id = (select id from pid));
insert into results select 'unknown agent: contract without seller and a warning',
  (select (r->>'created')::boolean and r->'warnings' ? 'seller_not_found' from r where label = 'no_seller')
  and (select seller_id is null from public.proposals_v2 where id = (select (r->>'id')::uuid from r where label = 'no_seller'));
insert into results select 'bad e-mail is dropped with a warning', (select r->'warnings' ? 'invalid_email' from r where label = 'create');
insert into results select 'the client record got the empty fields',
  (select gender = 'F' and marital_status = 'married' and birthplace_city = 'Rio Branco' and birthplace_state = 'AC' and rg_state = 'AC' and mother_name = 'Mae Do Cliente'
   from public.clients where id = (select customer_id from public.proposals_v2 where id = (select id from pid)))
  and exists (select 1 from public.customer_addresses a where a.customer_id = (select customer_id from public.proposals_v2 where id = (select id from pid)) and a.postal_code = '69900000' and a.is_primary)
  and exists (select 1 from public.customer_bank_accounts a where a.customer_id = (select customer_id from public.proposals_v2 where id = (select id from pid)) and a.bank_code = '001' and a.account_digit = 'X');
insert into results select 'the writes are recorded as the key administrator',
  (select created_by = (select admin_user from ids) from public.proposals_v2 where id = (select id from pid));
insert into results select 'every call is in the request log, without payload',
  (select count(*) from public.api_request_log where endpoint = 'contracts.upsert' and api_key_id in (select id from public.api_keys where prefix in ('ck_live_nasp_tes', 'ck_live_leads_te', 'ck_live_seller_t'))) = (select count(*) from calls) - 1;

-- A contract already in Corban with the same bank + ADE is linked, not duplicated.
select set_config('request.jwt.claims', json_build_object('sub', (select admin_user from ids), 'role', 'authenticated')::text, true);
create temp table screen as select d.proposal_id id from public.create_direct_proposal((select org from ids),
  (select customer_id from public.proposals_v2 where id = (select id from pid)), (select tv from ids), null, null, 3000, 300, 12, 'ADE-TELA-1', 'submitted',
  (select id from public.contract_types where tech_key = 'novo' and organization_id is null)) d;
select set_config('request.jwt.claims', '', true);
set local role service_role;
select pg_temp.call('link_existing', 'ck_live_nasp_test_key_000000000000', pg_temp.with_contract(1, 'em_validacao', '{"ade": "ADE-TELA-1"}', '{"external_id": "third"}'));
reset role;
insert into results select 'an existing contract with the same ADE is linked, not duplicated',
  (select not (r->>'created')::boolean and r->>'id' = (select id::text from screen) from calls where label = 'link_existing');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'api contracts contract failed'; end if;
end $$;
rollback;
