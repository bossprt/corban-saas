-- Contract test for 20261008_crm_campaign_delete_close_v1: a seller cannot delete or close a campaign; delete needs the
-- campaign's name typed; a campaign with a lead that became a proposal cannot be deleted; a test campaign is deleted
-- with its leads, history and imports while clients stay; closing sends open leads to Lost with the reason and a
-- history event and keeps leads in proposal; both are in the team history; another company is refused.
-- One transaction, rolled back.
--   psql -v ON_ERROR_STOP=1 -f tests/security/crm-campaign-delete-close-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as seller_user;
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
set local role authenticated;
insert into made select 'test', public.save_sales_campaign((select org from ids), null, 'Campanha Teste Excluir', null, 'manual', null, null, 'active', '{}');
insert into made select 'real', public.save_sales_campaign((select org from ids), null, 'Campanha Real Encerrar', null, 'manual', null, null, 'active', '{}');
select public.import_campaign_leads((select id from made where label = 'test'), 'teste.xlsx', repeat('c', 64), jsonb_build_array(
  jsonb_build_object('name', 'Lead Teste Um', 'cpf', '52998224725', 'phone', '68999550101'),
  jsonb_build_object('name', 'Lead Teste Dois', 'phone', '68999550102')));
select public.import_campaign_leads((select id from made where label = 'real'), 'real.xlsx', repeat('d', 64), jsonb_build_array(
  jsonb_build_object('name', 'Lead Real Um', 'phone', '68999550201'),
  jsonb_build_object('name', 'Lead Real Dois', 'phone', '68999550202'),
  jsonb_build_object('name', 'Lead Real Tres', 'phone', '68999550203')));
reset role;

-- One lead of the real campaign is in negotiation and one already became a proposal (set by hand here).
update public.leads set status = 'negotiating' where campaign_id = (select id from made where label = 'real') and full_name = 'Lead Real Dois';
update public.leads set status = 'proposal' where campaign_id = (select id from made where label = 'real') and full_name = 'Lead Real Tres';
create temp table before as select (select count(*) from public.clients where organization_id = (select org from ids)) as clients;

select pg_temp.act_as((select seller_user from ids));
set local role authenticated;
insert into results select 'a seller cannot delete a campaign',
  pg_temp.err(format('select public.delete_sales_campaign(%L, %L, %L)', (select org from ids), (select id from made where label = 'test'), 'Campanha Teste Excluir')) like '%not_authorized%';
insert into results select 'a seller cannot close a campaign',
  pg_temp.err(format('select public.close_sales_campaign(%L, %L)', (select org from ids), (select id from made where label = 'real'))) like '%not_authorized%';
reset role;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into results select 'another company is refused',
  pg_temp.err(format('select public.delete_sales_campaign(%L, %L, %L)', gen_random_uuid(), (select id from made where label = 'test'), 'Campanha Teste Excluir')) like '%not_authorized%';
insert into results select 'delete needs the campaign name typed',
  pg_temp.err(format('select public.delete_sales_campaign(%L, %L, %L)', (select org from ids), (select id from made where label = 'test'), 'outra')) like '%campaign_name_mismatch%';
insert into results select 'a campaign with a proposal cannot be deleted',
  pg_temp.err(format('select public.delete_sales_campaign(%L, %L, %L)', (select org from ids), (select id from made where label = 'real'), 'Campanha Real Encerrar')) like '%campaign_has_sales%';
insert into results select 'the test campaign is deleted (name case and spaces do not matter)',
  public.delete_sales_campaign((select org from ids), (select id from made where label = 'test'), '  campanha teste EXCLUIR ') = 2;
insert into results select 'closing sends the open leads to Lost', public.close_sales_campaign((select org from ids), (select id from made where label = 'real')) = 2;
reset role;

insert into results select 'nothing of the deleted campaign is left',
  not exists (select 1 from public.sales_campaigns where id = (select id from made where label = 'test'))
  and not exists (select 1 from public.leads where campaign_id = (select id from made where label = 'test'))
  and not exists (select 1 from public.sales_campaign_imports where campaign_id = (select id from made where label = 'test'));
insert into results select 'clients stay', (select count(*) from public.clients where organization_id = (select org from ids)) = (select clients from before);
insert into results select 'closed campaign: open leads Lost with the reason and an event; the proposal stays',
  (select status from public.sales_campaigns where id = (select id from made where label = 'real')) = 'closed'
  and (select count(*) from public.leads where campaign_id = (select id from made where label = 'real') and status = 'lost' and lost_reason = 'Campanha encerrada') = 2
  and (select status from public.leads where campaign_id = (select id from made where label = 'real') and full_name = 'Lead Real Tres') = 'proposal'
  and (select count(*) from public.lead_events e join public.leads l on l.id = e.lead_id where l.campaign_id = (select id from made where label = 'real') and e.to_status = 'lost') = 2;
insert into results select 'both are in the team history',
  exists (select 1 from public.organization_admin_events where event_type = 'sales_campaign_deleted' and details->>'campaign' = 'Campanha Teste Excluir' and (details->>'leads')::int = 2)
  and exists (select 1 from public.organization_admin_events where event_type = 'sales_campaign_closed' and (details->>'leads_closed')::int = 2);

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok or ok is null) then raise exception 'crm campaign delete close contract failed'; end if;
end $$;
rollback;
