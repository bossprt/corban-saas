-- Contract test for 20261009025438_proposal_seller_links_v1: an association (bank, ADE or CPF, seller) gives its seller to the
-- contract that arrives later, over the seller the import brings (owner decision); by ADE, else by CPF for a contract
-- created after it; used once; an existing contract with the ADE gets the seller at once; an association can be cancelled
-- with a reason; another company is refused; nobody writes the table directly. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/proposal-seller-links-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as seller_user,
       (select id from public.contract_types where tech_key = 'novo' and organization_id is null) as novo;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on function pg_temp.err(text) to authenticated;
create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

select pg_temp.act_as((select admin_user from ids));
-- A table with a coefficient (factor) so the simulator offers it.
insert into public.organization_agreements (organization_id, name, is_active) select org, 'Convênio Assoc', true from ids returning id \gset agr_
insert into public.organization_banks (organization_id, name, is_active) select org, 'Banco Assoc', true from ids returning id \gset bank_
insert into made values ('agreement', :'agr_id');
insert into public.organization_product_routes (organization_id, org_bank_id, org_agreement_id, production_origin, status)
select org, :'bank_id', :'agr_id', 'own', 'active' from ids returning id \gset route_
insert into public.product_tables (organization_id, route_id, code, name, status, formalization)
select org, :'route_id', 'assoc-t', 'Tabela Assoc', 'active', 'digital' from ids returning id \gset tbl_
insert into public.product_table_versions (organization_id, product_table_id, version, status) select org, :'tbl_id', 1, 'draft' from ids returning id \gset ver_
insert into public.commercial_conditions (organization_id, product_table_version_id, contract_type_id, term, term_min, term_max, coefficient, tax_pct)
select org, :'ver_id', novo, 84, 84, 84, 0.025, 0 from ids;
select public.publish_product_table_version(:'ver_id', current_date - 1);
insert into made values ('version', :'ver_id'), ('bank', :'bank_id');

create temp table seen (label text, b jsonb);
grant insert, select on seen to authenticated;
insert into made values ('seller_a', '00000000-0000-4000-8000-0000000c0801'), ('seller_b', '00000000-0000-4000-8000-0000000c0802');
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '52998224725', 'Cliente Assoc', '68999770031', null, 'manual') u;

insert into results select 'another company is refused',
  pg_temp.err(format('select public.link_proposal_seller(%L, %L, %L, null, null, %L)', gen_random_uuid(), (select id from made where label = 'bank'), 'ASSOC-1', (select id from made where label = 'seller_b'))) like '%not_authorized%';
insert into results select 'nobody writes the associations directly',
  pg_temp.err(format('insert into public.proposal_seller_links (organization_id, org_bank_id, ade, seller_id) values (%L, %L, %L, %L)', (select org from ids), (select id from made where label = 'bank'), 'X1', (select id from made where label = 'seller_b'))) like '%permission denied%';
insert into seen select 'ade', public.link_proposal_seller((select org from ids), (select id from made where label = 'bank'), 'ASSOC-1', null, 'Cliente Assoc', (select id from made where label = 'seller_b'));
insert into results select 'the same ADE cannot wait twice',
  pg_temp.err(format('select public.link_proposal_seller(%L, %L, %L, null, null, %L)', (select org from ids), (select id from made where label = 'bank'), 'assoc-1', (select id from made where label = 'seller_a'))) like '%link_already_waiting%';
-- The contract arrives (an import) with ADE ASSOC-1 and seller A.
insert into made select 'p_ade', (r).proposal_id from (select public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select id from made where label = 'version'),
  (select id from made where label = 'seller_a'), 10000::numeric, 10000::numeric, null::numeric, 84, 'ASSOC-1', 'submitted', (select novo from ids), null::jsonb) r) x;
-- A CPF association, then a new contract of that client without ADE.
insert into seen select 'cpf', public.link_proposal_seller((select org from ids), (select id from made where label = 'bank'), null, '529.982.247-25', 'Cliente Assoc', (select id from made where label = 'seller_b'));
insert into made select 'p_cpf', (r).proposal_id from (select public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select id from made where label = 'version'),
  (select id from made where label = 'seller_a'), 11000::numeric, 11000::numeric, null::numeric, 84, null, 'digitization_queue', (select novo from ids), null::jsonb) r) x;
-- A third contract of the same client: the CPF association was already used.
insert into made select 'p_other', (r).proposal_id from (select public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select id from made where label = 'version'),
  (select id from made where label = 'seller_a'), 12000::numeric, 12000::numeric, null::numeric, 84, 'ASSOC-9', 'submitted', (select novo from ids), null::jsonb) r) x;
-- An association for a contract that already exists (ASSOC-9): applied at once.
insert into seen select 'existing', public.link_proposal_seller((select org from ids), (select id from made where label = 'bank'), 'ASSOC-9', null, null, (select id from made where label = 'seller_b'));
-- A waiting association is cancelled with a reason.
insert into seen select 'to_cancel', public.link_proposal_seller((select org from ids), (select id from made where label = 'bank'), 'ASSOC-5', null, null, (select id from made where label = 'seller_b'));
insert into results select 'cancel needs a reason',
  pg_temp.err(format('select public.cancel_proposal_seller_link(%L, %L)', (select (b->>'link_id')::uuid from seen where label = 'to_cancel'), ' ')) like '%cancel_reason_required%';
select public.cancel_proposal_seller_link((select (b->>'link_id')::uuid from seen where label = 'to_cancel'), 'digitada errada');
reset role;
set constraints all immediate;

insert into results select 'by ADE: the seller of the import gave way to the associated seller, with history',
  (select seller_id = (select id from made where label = 'seller_b') from public.proposals_v2 where id = (select id from made where label = 'p_ade'))
  and exists (select 1 from public.contract_events where proposal_id = (select id from made where label = 'p_ade') and kind = 'edit' and reason like 'Vendedor da proposta associada (nº ASSOC-1)%');
insert into results select 'by ADE: the association is used by that contract',
  (select status = 'used' and matched_by = 'ade' and proposal_id = (select id from made where label = 'p_ade') from public.proposal_seller_links where id = (select (b->>'link_id')::uuid from seen where label = 'ade'));
insert into results select 'by CPF: a new contract of the client gets the seller; the association is used once',
  (select seller_id = (select id from made where label = 'seller_b') from public.proposals_v2 where id = (select id from made where label = 'p_cpf'))
  and (select status = 'used' and matched_by = 'cpf' from public.proposal_seller_links where id = (select (b->>'link_id')::uuid from seen where label = 'cpf'));
insert into results select 'existing contract: the seller is applied at once',
  (select (b->>'applied')::boolean from seen where label = 'existing')
  and (select seller_id = (select id from made where label = 'seller_b') from public.proposals_v2 where id = (select id from made where label = 'p_other'));
insert into results select 'the commission follows the associated seller (when calculated)',
  coalesce((select seller_id = (select id from made where label = 'seller_b') from public.proposal_commission_calcs where proposal_id = (select id from made where label = 'p_ade') and status = 'active'), true);
insert into results select 'the cancelled association stays, with reason',
  (select status = 'cancelled' and cancel_reason = 'digitada errada' from public.proposal_seller_links where id = (select (b->>'link_id')::uuid from seen where label = 'to_cancel'));

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'proposal seller links contract failed'; end if;
end $$;
rollback;
