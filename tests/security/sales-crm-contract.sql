-- Contract test for 20260928000000_sales_crm_v1: campaigns from spreadsheets, distribution (queue / manual / round robin),
-- stages that follow the client's proposal, and a seller who only ever sees and works their own leads.
-- Local test company and users admin / vendedor / vendedor2 @corban-teste.local. One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/sales-crm-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0301'::uuid as tv,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       (select id from auth.users where email = 'vendedor2@corban-teste.local') as v2;
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
create function pg_temp.sha() returns text language sql as $$ select encode(sha256(convert_to('campanha-refin', 'utf8')), 'hex') $$;
grant execute on function pg_temp.sha() to authenticated;
create function pg_temp.id(p_label text) returns uuid language sql as $$ select id from made where label = p_label $$;
grant execute on function pg_temp.id(text) to authenticated;

-- Administrator: an existing client, three campaigns (queue without members, round robin with both sellers, manual).
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '27182818205', 'Cliente Carteira', '68999550001', null, 'manual') u;
insert into made select 'queue', public.save_sales_campaign((select org from ids), null, 'Refin Setembro', 'Base INSS', 'queue', current_date, null, 'active', '{}');
insert into made select 'rr', public.save_sales_campaign((select org from ids), null, 'Portabilidade', null, 'round_robin', null, null, 'active',
  array[(select v1 from ids), (select v2 from ids)]);
insert into made select 'manual', public.save_sales_campaign((select org from ids), null, 'Margem nova', null, 'manual', null, null, 'active', '{}');
insert into results select 'campaign names are unique in the company',
  pg_temp.err(format('select public.save_sales_campaign(%L, null, %L, null, %L, null, null, %L, %L)', (select org from ids), ' refin setembro ', 'queue', 'active', '{}')) = 'campaign_name_taken';
insert into results select 'round robin needs members',
  pg_temp.err(format('select public.save_sales_campaign(%L, null, %L, null, %L, null, null, %L, %L)', (select org from ids), 'Sem gente', 'round_robin', 'active', '{}')) = 'round_robin_needs_members';

-- Queue campaign spreadsheet.
create temp table imp as select public.import_campaign_leads(pg_temp.id('queue'), 'refin.xlsx', pg_temp.sha(), jsonb_build_array(
  jsonb_build_object('name', 'Cliente Carteira Planilha', 'cpf', '271.828.182-05', 'phone', '68 99955-0001', 'info', jsonb_build_object('Margem', '350,20', 'Banco', 'BB')),
  jsonb_build_object('name', 'Pessoa Nova', 'cpf', '31415926590', 'phone', '(68) 99955-0002', 'phone2', '68999550009', 'email', 'nova@exemplo.com'),
  jsonb_build_object('name', 'Zero Perdido', 'cpf', '444555692'),
  jsonb_build_object('name', 'CPF Errado', 'cpf', '11111111111', 'phone', '68999550003'),
  jsonb_build_object('name', 'Sem Contato', 'cpf', '123'),
  jsonb_build_object('name', 'Repetida', 'cpf', '314.159.265-90'),
  jsonb_build_object('cpf', '16180339805', 'phone', '68999550004'))) as r;
insert into results select 'import counts: 4 created, 1 linked client, 1 duplicate, 2 invalid',
  (select (r->>'created')::int = 4 and (r->>'linked_clients')::int = 1 and (r->>'duplicates')::int = 1 and (r->>'invalid')::int = 2 from imp);
insert into results select 'known client linked by CPF, client record untouched',
  exists (select 1 from public.leads where campaign_id = pg_temp.id('queue') and customer_id = pg_temp.id('client') and cpf = '27182818205')
  and (select full_name = 'Cliente Carteira' from public.clients where id = pg_temp.id('client'));
insert into results select 'new person stays a lead, not a client',
  exists (select 1 from public.leads where campaign_id = pg_temp.id('queue') and cpf = '31415926590' and customer_id is null)
  and not exists (select 1 from public.clients where organization_id = (select org from ids) and cpf = '31415926590');
insert into results select 'CPF with lost leading zeros is restored', exists (select 1 from public.leads where campaign_id = pg_temp.id('queue') and cpf = '00444555692');
insert into results select 'invalid CPF is dropped, never guessed', exists (select 1 from public.leads where campaign_id = pg_temp.id('queue') and full_name = 'CPF Errado' and cpf is null);
insert into results select 'spreadsheet columns kept as text on the lead',
  (select metadata->'info'->>'Margem' = '350,20' from public.leads where campaign_id = pg_temp.id('queue') and customer_id = pg_temp.id('client'));
insert into results select 'second phone kept', exists (select 1 from public.leads where campaign_id = pg_temp.id('queue') and metadata->>'phone2' = '5568999550009');
-- Same people again (by CPF or phone) are skipped; only the one new phone comes in.
insert into results select 'people already in the campaign are skipped',
  (select (x->>'created')::int = 1 and (x->>'duplicates')::int = 4 from (select public.import_campaign_leads(pg_temp.id('queue'), 'refin.xlsx', pg_temp.sha(),
     jsonb_build_array(jsonb_build_object('name', 'Cliente Carteira Planilha', 'cpf', '27182818205'), jsonb_build_object('name', 'Pessoa Nova', 'cpf', '31415926590'),
       jsonb_build_object('name', 'Zero Perdido', 'cpf', '00444555692'), jsonb_build_object('name', 'CPF Errado', 'phone', '68999550003'),
       jsonb_build_object('name', 'Outro nome', 'phone', '68999550004')))) t(x));
insert into results select 'import is recorded', (select count(*) = 2 from public.sales_campaign_imports where campaign_id = pg_temp.id('queue'));

-- Round robin: the new leads alternate between the two sellers.
select public.import_campaign_leads(pg_temp.id('rr'), 'porta.csv', pg_temp.sha(), jsonb_build_array(
  jsonb_build_object('name', 'Porta Um', 'phone', '68999560001'), jsonb_build_object('name', 'Porta Dois', 'phone', '68999560002'),
  jsonb_build_object('name', 'Porta Tres', 'phone', '68999560003'), jsonb_build_object('name', 'Porta Quatro', 'phone', '68999560004')));
insert into results select 'round robin splits 2 and 2',
  (select count(*) filter (where owner_user_id = (select v1 from ids)) = 2 and count(*) filter (where owner_user_id = (select v2 from ids)) = 2
   from public.leads where campaign_id = pg_temp.id('rr'));
-- Manual: nobody gets them until a supervisor distributes.
select public.import_campaign_leads(pg_temp.id('manual'), 'margem.csv', pg_temp.sha(), jsonb_build_array(
  jsonb_build_object('name', 'Margem Um', 'phone', '68999570001'), jsonb_build_object('name', 'Margem Dois', 'phone', '68999570002'),
  jsonb_build_object('name', 'Margem Tres', 'phone', '68999570003')));
insert into results select 'manual campaign leads wait unassigned', (select count(*) = 3 from public.leads where campaign_id = pg_temp.id('manual') and owner_user_id is null);
insert into results select 'admin gives 2 oldest leads to seller 1',
  public.assign_leads((select org from ids), (select v1 from ids), null, pg_temp.id('manual'), 2) = 2;
insert into results select 'a lead cannot go to someone outside the company',
  pg_temp.err(format('select public.assign_leads(%L, %L, null, %L, 1)', (select org from ids), gen_random_uuid(), pg_temp.id('manual'))) = 'invalid_lead_owner';
reset role;

-- Seller 1.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'seller cannot create a campaign',
  pg_temp.err(format('select public.save_sales_campaign(%L, null, %L, null, %L, null, null, %L, %L)', (select org from ids), 'Minha', 'queue', 'active', '{}')) = 'not_authorized';
insert into results select 'seller cannot import', pg_temp.err(format('select public.import_campaign_leads(%L, %L, %L, %L::jsonb)', pg_temp.id('queue'), 'x.csv', pg_temp.sha(),
  jsonb_build_array(jsonb_build_object('name', 'Intruso', 'phone', '68999580001')))) = 'not_authorized';
insert into results select 'seller cannot distribute',
  pg_temp.err(format('select public.assign_leads(%L, %L, null, %L, 1)', (select org from ids), (select v1 from ids), pg_temp.id('manual'))) = 'not_authorized';
insert into results select 'seller does not see the queue leads, only how many wait',
  not exists (select 1 from public.leads where campaign_id = pg_temp.id('queue')) and public.lead_queue_count((select org from ids), pg_temp.id('queue')) = 5;
insert into results select 'seller sees own round robin and manual leads, not seller 2 ones',
  (select count(*) = 2 from public.leads where campaign_id = pg_temp.id('rr')) and (select count(*) = 2 from public.leads where campaign_id = pg_temp.id('manual'));
insert into made select 'taken', public.take_next_lead((select org from ids), pg_temp.id('queue'));
insert into results select 'take next gives the oldest queue lead and it becomes visible',
  (select customer_id = pg_temp.id('client') and owner_user_id = (select v1 from ids) from public.leads where id = pg_temp.id('taken'))
  and public.lead_queue_count((select org from ids), pg_temp.id('queue')) = 4;
insert into made select 'new', public.take_next_lead((select org from ids), pg_temp.id('queue'));
-- Stages by hand: only new / contacted / negotiating / lost.
insert into results select 'proposal is never set by hand', pg_temp.err(format('select public.set_lead_status(%L, %L)', pg_temp.id('new'), 'proposal')) = 'invalid_lead_status';
insert into results select 'won is never set by hand', pg_temp.err(format('select public.set_lead_status(%L, %L)', pg_temp.id('new'), 'won')) = 'invalid_lead_status';
insert into results select 'lost needs a reason', pg_temp.err(format('select public.set_lead_status(%L, %L)', pg_temp.id('new'), 'lost')) = 'lost_reason_required';
select public.set_lead_next_contact(pg_temp.id('new'), now() + interval '1 day');
insert into results select 'scheduling a return counts as first contact',
  (select status = 'contacted' and next_contact_at > now() from public.leads where id = pg_temp.id('new'));
select public.add_lead_note(pg_temp.id('new'), 'Cliente pediu retorno amanhã de manhã');
insert into results select 'note goes to the timeline',
  exists (select 1 from public.lead_events where lead_id = pg_temp.id('new') and event_type = 'note' and detail->>'text' like 'Cliente pediu%');
-- Start the sale: the lead's CPF makes the client; lead moves to negotiating.
insert into made select 'new_client', public.start_lead_sale(pg_temp.id('new'));
insert into results select 'start sale creates the client from the lead CPF and moves to negotiating',
  (select cpf = '31415926590' and owner_user_id = (select v1 from ids) from public.clients where id = pg_temp.id('new_client'))
  and (select status = 'negotiating' and customer_id = pg_temp.id('new_client') from public.leads where id = pg_temp.id('new'));
-- A proposal for the client moves the lead to proposal.
insert into made select 'p1', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.id('new_client'), (select tv from ids), null,
  10000, 9500, 250.00, 84, 'ADE-CRM-1', 'submitted') d;
insert into results select 'proposal of the client moves the lead to proposal',
  (select status = 'proposal' and proposal_id = pg_temp.id('p1') from public.leads where id = pg_temp.id('new'));
insert into results select 'a lead in proposal cannot go back by hand',
  pg_temp.err(format('select public.set_lead_status(%L, %L)', pg_temp.id('new'), 'negotiating')) = 'lead_has_open_proposal';
-- Seller 1 cannot touch seller 2's lead.
reset role;
insert into made select 'v2lead', id from public.leads where campaign_id = pg_temp.id('rr') and owner_user_id = (select v2 from ids) limit 1;
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'seller cannot note on a lead of seller 2', pg_temp.err(format('select public.add_lead_note(%L, %L)', pg_temp.id('v2lead'), 'x')) <> 'ok';
insert into results select 'seller cannot claim a lead of another campaign queue', pg_temp.err(format('select public.claim_lead(%L)', pg_temp.id('v2lead'))) <> 'ok';
reset role;

-- The proposal is paid: the lead is won.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.move_operational_case((select id from public.operational_cases where proposal_id = pg_temp.id('p1')), 'paid', 'Pago no portal do Banco Teste', null);
insert into results select 'paid proposal makes the lead won',
  (select status = 'won' and won_at is not null and next_contact_at is null from public.leads where id = pg_temp.id('new'));
insert into results select 'a won lead is closed', pg_temp.err(format('select public.set_lead_status(%L, %L, %L)', pg_temp.id('new'), 'lost', 'x')) = 'lead_already_won';
-- A cancelled proposal brings the lead back to negotiating.
select public.start_lead_sale(pg_temp.id('taken'));
insert into made select 'p2', d.proposal_id from public.create_direct_proposal((select org from ids), pg_temp.id('client'), (select tv from ids), null,
  5000, 4800, 150.00, 84, 'ADE-CRM-2', 'submitted') d;
insert into results select 'proposal of a known client moves its lead', (select status = 'proposal' from public.leads where id = pg_temp.id('taken'));
select public.move_operational_case((select id from public.operational_cases where proposal_id = pg_temp.id('p2')), 'cancelled', 'Cliente desistiu', null);
insert into results select 'cancelled proposal brings the lead back to negotiating',
  (select status = 'negotiating' and proposal_id is null from public.leads where id = pg_temp.id('taken'));
reset role;

insert into results select 'anon has no access to campaigns or the CRM functions',
  not has_table_privilege('anon', 'public.sales_campaigns', 'select') and not has_table_privilege('anon', 'public.leads', 'select')
  and not has_function_privilege('anon', 'public.import_campaign_leads(uuid,text,text,jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.take_next_lead(uuid,uuid)', 'execute');
insert into results select 'authenticated cannot write campaigns directly',
  not has_table_privilege('authenticated', 'public.sales_campaigns', 'insert') and not has_table_privilege('authenticated', 'public.leads', 'update');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 37 then raise exception 'sales crm contract failed'; end if;
end $$;

rollback;
