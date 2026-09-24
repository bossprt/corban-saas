-- Contract test for 20260924204503_commission_visibility_v1 (ADR-0031): a seller sees only their own share, and only on
-- their own proposals; the calculation header is finance-only; expected_commission_amount is gone.
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/commission-visibility-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0302'::uuid as tv,
       '00000000-0000-4000-8000-0000000c0801'::uuid as seller,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'supervisor@corban-teste.local') as sup_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as v1,
       (select id from auth.users where email = 'vendedor2@corban-teste.local') as v2,
       (select id from auth.users where email = 'financeiro@corban-teste.local') as fin;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;

create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

-- Setup as admin: hierarchy, rule, one proposal of the seller bound to vendedor, one proposal of nobody's seller.
select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
select public.set_member_hierarchy((select id from public.organization_memberships where user_id = (select v1 from ids)), null, (select sup_user from ids), null);
select public.save_commission_rule((select org from ids), 'global', null, 'cascade', 6, 40, 10, 15, 75, true, 'regra do teste');
insert into made select 'client', u.client_id from public.upsert_client((select org from ids), '39053344705', 'Cliente Visibilidade', '68999770010', null, 'manual') u;
insert into made select 'mine', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), (select seller from ids), 10000, 9500, 250, 120, 'ADE-VIS-1', 'submitted') d;
insert into made select 'other', d.proposal_id from public.create_direct_proposal((select org from ids), (select id from made where label = 'client'), (select tv from ids), null, 10000, 9500, 250, 120, 'ADE-VIS-2', 'submitted') d;
select public.calculate_proposal_commission((select id from made where label = 'mine'));
select public.calculate_proposal_commission((select id from made where label = 'other'));
insert into made select 'calc_mine', c.id from public.proposal_commission_calcs c where c.proposal_id = (select id from made where label = 'mine') and c.status = 'active';
insert into made select 'calc_other', c.id from public.proposal_commission_calcs c where c.proposal_id = (select id from made where label = 'other') and c.status = 'active';
reset role;

-- Reference: the seller's share as stored (read as the table owner).
create temp table ref as
select sum(amount * multiplier) as mine_total, count(*) as mine_lines
from public.proposal_commission_lines where calc_id = (select id from made where label = 'calc_mine') and line_kind = 'originator';
grant select on ref to authenticated;

-- The seller.
select pg_temp.act_as((select v1 from ids));
set local role authenticated;
insert into results select 'seller cannot read the calculation header of their own proposal',
  not exists (select 1 from public.proposal_commission_calcs where proposal_id = (select id from made where label = 'mine'));
insert into results select 'seller reads only the originator lines of their own proposal',
  (select count(*) from public.proposal_commission_lines where calc_id = (select id from made where label = 'calc_mine')) = (select mine_lines from ref)
  and (select mine_lines from ref) > 0
  and not exists (select 1 from public.proposal_commission_lines where calc_id = (select id from made where label = 'calc_mine') and line_kind <> 'originator');
insert into results select 'seller reads no line of a proposal that is not theirs',
  not exists (select 1 from public.proposal_commission_lines where calc_id = (select id from made where label = 'calc_other'));
insert into results select 'proposal_commission_mine gives the seller their own share, exact',
  (select (r->>'mine')::boolean and (select sum((l->>'amount')::numeric * (l->>'multiplier')::numeric) from jsonb_array_elements(r->'lines') l) = (select mine_total from ref)
          and not exists (select 1 from jsonb_array_elements(r->'lines') l where l->>'amount' !~ '^-?[0-9]+\.[0-9]{2}$')
   from (select public.proposal_commission_mine((select id from made where label = 'mine')) r) x);
do $$ begin
  begin
    perform public.proposal_commission_mine((select id from made where label = 'other'));
    insert into results values ('proposal_commission_mine refuses a proposal the seller cannot see', false);
  exception when others then
    insert into results values ('proposal_commission_mine refuses a proposal the seller cannot see', sqlerrm = 'not_authorized');
  end;
end $$;
reset role;

-- A supervisor without finance access sees that it is calculated, but no amount.
select pg_temp.act_as((select sup_user from ids));
set local role authenticated;
insert into results select 'supervisor: header only with financeiro.view; mine=false and no lines otherwise',
  case when public.has_permission((select org from ids), 'financeiro.view')
       then exists (select 1 from public.proposal_commission_calcs where id = (select id from made where label = 'calc_mine'))
       else not exists (select 1 from public.proposal_commission_calcs where id = (select id from made where label = 'calc_mine'))
            and not exists (select 1 from public.proposal_commission_lines where calc_id = (select id from made where label = 'calc_mine'))
            and (select r->>'mine' = 'false' and r->>'calculated' = 'true' and r->'lines' is null
                 from (select public.proposal_commission_mine((select id from made where label = 'mine')) r) x)
  end;
reset role;

-- Finance reads everything.
select pg_temp.act_as((select fin from ids));
set local role authenticated;
insert into results select 'finance reads the header and every line kind',
  exists (select 1 from public.proposal_commission_calcs where id = (select id from made where label = 'calc_mine'))
  and (select count(distinct line_kind) from public.proposal_commission_lines where calc_id = (select id from made where label = 'calc_mine')) = 6;
reset role;

insert into results select 'expected_commission_amount removed from proposals_v2 and simulations',
  not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name in ('proposals_v2','simulations') and column_name = 'expected_commission_amount');
insert into results select 'no function still refers to expected_commission_amount',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('public','private') and p.prokind = 'f' and p.prosrc ilike '%expected_commission_amount%');
insert into results select 'anon cannot run proposal_commission_mine; authenticated can',
  not has_function_privilege('anon', 'public.proposal_commission_mine(uuid)', 'execute')
  and has_function_privilege('authenticated', 'public.proposal_commission_mine(uuid)', 'execute');

select check_name, ok from results order by ok, check_name;
do $$ begin
  if exists (select 1 from results where not ok) or (select count(*) from results) < 10 then raise exception 'commission visibility contract failed'; end if;
end $$;
rollback;
