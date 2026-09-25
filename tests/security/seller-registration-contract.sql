-- Contract test for 20260925221519_seller_registration_v1 (local test company and users, see data-scope-contract.sql).
-- One transaction, rolled back.  psql -v ON_ERROR_STOP=1 -f tests/security/seller-registration-contract.sql

begin;

create temp table ids as
select '00000000-0000-4000-8000-00000000c0b1'::uuid as org,
       '00000000-0000-4000-8000-0000000c0601'::uuid as grp,
       (select id from auth.users where email = 'admin@corban-teste.local') as admin_user,
       (select id from auth.users where email = 'vendedor@corban-teste.local') as seller_user;
grant select on ids to authenticated;
create temp table results (check_name text, ok boolean);
grant insert, select on results to authenticated;
create temp table made (label text, id uuid);
grant insert, select on made to authenticated;

create function pg_temp.act_as(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
create function pg_temp.refused(p_sql text, p_error text) returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return sqlerrm = p_error;
end $$;
-- A complete registration; the caller overrides pieces with jsonb ||.
create function pg_temp.data(p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object(
    'name', 'Vendedor Contrato', 'tax_id', '111.444.777-35', 'category', 'pf', 'group_id', (select grp from ids),
    'profile', jsonb_build_object('mobile', '(68) 99977-1100', 'whatsapp', '(68) 99977-1100', 'email', 'Vendedor.Contrato@Example.com',
      'rg', '123456', 'rg_issuer', 'ssp', 'mother_name', 'Mãe Contrato', 'zip', '69900-000', 'street', 'Rua Um', 'city', 'Rio Branco', 'state', 'ac'),
    'accounts', jsonb_build_array(
      jsonb_build_object('transfer_method', 'pix', 'pix_key_type', 'phone', 'pix_key', '(68) 99977-1100', 'primary', false),
      jsonb_build_object('transfer_method', 'ted', 'account_type', 'checking', 'bank_code', '001', 'bank_name', 'Banco do Brasil', 'branch', '1234',
        'account_number', '567890', 'account_digit', 'x', 'holder_name', 'Empresa do Vendedor', 'holder_document', '11.222.333/0001-81', 'primary', true)),
    'contacts', jsonb_build_array(jsonb_build_object('name', 'Sócio Contrato', 'cpf', '529.982.247-25', 'role', 'Sócio', 'mobile', '68 98888-0000', 'email', 'socio@example.com'))
  ) || p_extra;
$$;
create function pg_temp.save(p_seller uuid, p_data jsonb) returns text language sql as $$
  select format('select public.save_seller(%L, %L, %L)', (select org from ids), p_seller, p_data);
$$;

select pg_temp.act_as((select admin_user from ids));
set local role authenticated;
insert into made select 'seller', public.save_seller((select org from ids), null, pg_temp.data());
insert into results select 'the code is automatic and sequential', (select code from public.commercial_sellers where id = (select id from made where label = 'seller'))
  = (select max(code) from public.commercial_sellers where organization_id = (select org from ids))
  and (select code from public.commercial_sellers where id = (select id from made where label = 'seller')) > 1;
insert into results select 'identity and profile are saved normalized', exists (select 1 from public.commercial_sellers s join public.seller_profiles p on p.seller_id = s.id
  where s.id = (select id from made where label = 'seller') and s.tax_id = '11144477735' and p.email = 'vendedor.contrato@example.com'
    and p.phone = '5568999771100' and p.identity_issuer = 'SSP' and p.zip = '69900000' and p.state = 'AC');
insert into results select 'the account marked primary is the only primary', (select count(*) from public.seller_bank_accounts where seller_id = (select id from made where label = 'seller') and is_primary) = 1
  and exists (select 1 from public.seller_bank_accounts where seller_id = (select id from made where label = 'seller') and is_primary and transfer_method = 'ted' and account_digit = 'X' and holder_document = '11222333000181');
insert into results select 'a PIX phone key is stored with the country code', exists (select 1 from public.seller_bank_accounts where seller_id = (select id from made where label = 'seller') and pix_key = '+5568999771100');
insert into results select 'every new account is logged', (select count(*) from public.seller_bank_account_events where seller_id = (select id from made where label = 'seller') and action = 'added') = 2;
insert into results select 'contacts are saved', exists (select 1 from public.seller_contacts where seller_id = (select id from made where label = 'seller') and cpf = '52998224725' and mobile = '5568988880000');

insert into results select 'mobile is required', pg_temp.refused(pg_temp.save(null, pg_temp.data(jsonb_build_object('tax_id', '52998224725', 'profile', jsonb_build_object('email', 'a@b.co')))), 'seller_mobile_required');
insert into results select 'e-mail is required', pg_temp.refused(pg_temp.save(null, pg_temp.data(jsonb_build_object('tax_id', '52998224725', 'profile', jsonb_build_object('mobile', '68999771101', 'email', 'sem-arroba')))), 'seller_email_required');
insert into results select 'an invalid CPF/CNPJ is refused', pg_temp.refused(pg_temp.save(null, pg_temp.data(jsonb_build_object('tax_id', '11222333000182'))), 'seller_tax_id_invalid');
insert into results select 'the same CPF/CNPJ cannot be two sellers', pg_temp.refused(pg_temp.save(null, pg_temp.data()), 'seller_tax_id_exists');
insert into results select 'an invalid PIX key is refused', pg_temp.refused(pg_temp.save(null, pg_temp.data(jsonb_build_object('tax_id', '52998224725',
  'accounts', jsonb_build_array(jsonb_build_object('transfer_method', 'pix', 'pix_key_type', 'random', 'pix_key', 'nao-e-chave'))))), 'seller_pix_key_invalid');
insert into results select 'TED without the account is refused', pg_temp.refused(pg_temp.save(null, pg_temp.data(jsonb_build_object('tax_id', '52998224725',
  'accounts', jsonb_build_array(jsonb_build_object('transfer_method', 'ted', 'bank_code', '001'))))), 'seller_account_invalid');
insert into results select 'a payee needs name and document together', pg_temp.refused(pg_temp.save(null, pg_temp.data(jsonb_build_object('tax_id', '52998224725',
  'accounts', jsonb_build_array(jsonb_build_object('transfer_method', 'pix', 'pix_key_type', 'email', 'pix_key', 'x@y.co', 'holder_name', 'Só Nome'))))), 'seller_account_invalid');
insert into results select 'an invalid contact is refused', pg_temp.refused(pg_temp.save(null, pg_temp.data(jsonb_build_object('tax_id', '52998224725',
  'contacts', jsonb_build_array(jsonb_build_object('name', 'Contato', 'cpf', '11111111111'))))), 'seller_contact_invalid');

-- Edit: change the PIX account and make it primary, remove the TED account.
create temp table acc as select id, transfer_method from public.seller_bank_accounts where seller_id = (select id from made where label = 'seller');
grant select on acc to authenticated;
select public.save_seller((select org from ids), (select id from made where label = 'seller'), pg_temp.data(jsonb_build_object(
  'accounts', jsonb_build_array(
    jsonb_build_object('id', (select id from acc where transfer_method = 'pix'), 'transfer_method', 'pix', 'pix_key_type', 'email', 'pix_key', 'Pix@Example.com', 'primary', true),
    jsonb_build_object('id', (select id from acc where transfer_method = 'ted'), 'remove', true)),
  'contacts', '[]'::jsonb)));
insert into results select 'the edited account is primary and logged', exists (select 1 from public.seller_bank_accounts where id = (select id from acc where transfer_method = 'pix') and is_primary and pix_key = 'pix@example.com')
  and exists (select 1 from public.seller_bank_account_events where account_id = (select id from acc where transfer_method = 'pix') and action = 'changed' and before->>'pix_key' = '+5568999771100');
insert into results select 'a removed account is kept and logged', exists (select 1 from public.seller_bank_accounts where id = (select id from acc where transfer_method = 'ted') and removed_at is not null and not is_primary)
  and exists (select 1 from public.seller_bank_account_events where account_id = (select id from acc where transfer_method = 'ted') and action = 'removed');
insert into results select 'the contact list is replaced', not exists (select 1 from public.seller_contacts where seller_id = (select id from made where label = 'seller'));
insert into results select 'bank data cannot be written directly', pg_temp.refused(format('update public.seller_bank_accounts set pix_key = %L', 'x'), 'permission denied for table seller_bank_accounts');
reset role;

insert into results select 'the code never changes', pg_temp.refused(format('update public.commercial_sellers set code = 999 where id = %L', (select id from made where label = 'seller')), 'seller_code_immutable');
insert into results select 'not even the owner writes bank data without the function', pg_temp.refused(format('update public.seller_bank_accounts set pix_key = %L where seller_id = %L', 'x', (select id from made where label = 'seller')), 'seller_write_requires_governed_rpc');

-- A seller neither registers sellers nor reads bank data.
select pg_temp.act_as((select seller_user from ids));
set local role authenticated;
insert into results select 'a seller cannot register sellers', pg_temp.refused(pg_temp.save(null, pg_temp.data(jsonb_build_object('tax_id', '52998224725'))), 'not_authorized');
insert into results select 'a seller does not read bank data', not exists (select 1 from public.seller_bank_accounts) and not exists (select 1 from public.seller_bank_account_events);
reset role;

select check_name, ok from results order by ok, check_name;
do $$ begin
  if (select count(*) from results) <> 22 or exists (select 1 from results where not ok) then raise exception 'seller registration contract failed'; end if;
end $$;

rollback;
