-- Public API v1, second endpoint: POST /api/v1/contracts (first user: NASP, docs/integracoes in the NASP repo).
--
-- Another system sends the full state of one contract each time its stage changes. Corban creates the contract the
-- first time, then keeps it in step: ADE, data while the contract is open, stage. One-way: Corban never writes back.
--
-- Who acts: the API has no signed-in user. The key acts as the administrator who created it (ADR-0056), so every write
-- goes through the same RPCs as the screens (permissions, governed flags, history, commission triggers). If that person
-- is no longer an active administrator of the company, the key stops working.
--
-- Identity: the sender's stable id (external_id) per company and bank, in api_contract_links. The ADE arrives later
-- and may change. A contract that already exists in Corban with the same bank + ADE is linked, not duplicated.
-- Order: each call carries a growing sequence per contract; a call not newer than the last one applied changes nothing.

-- 1. New scope -----------------------------------------------------------------------------------------------------

alter table public.api_keys drop constraint if exists api_keys_scopes_check;
alter table public.api_keys add constraint api_keys_scopes_check
  check (array_length(scopes, 1) >= 1 and scopes <@ array['leads.write', 'contracts.write']);

create or replace function public.create_api_key(p_org uuid, p_name text, p_scopes text[])
returns table (id uuid, api_key text, prefix text)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_key text;
  v_id uuid;
begin
  if auth.uid() is null or private.caller_role_in(p_org) is distinct from 'admin' then raise exception 'not_authorized'; end if;
  if p_name is null or length(btrim(p_name)) not between 2 and 60 then raise exception 'invalid_api_key_name'; end if;
  if p_scopes is null or array_length(p_scopes, 1) is null or not p_scopes <@ array['leads.write', 'contracts.write'] then raise exception 'invalid_api_key_scopes'; end if;
  v_key := 'ck_live_' || translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
  insert into public.api_keys (organization_id, name, prefix, key_hash, scopes, created_by)
  values (p_org, btrim(p_name), left(v_key, 16), encode(extensions.digest(v_key, 'sha256'), 'hex'), p_scopes, auth.uid())
  returning api_keys.id into v_id;
  perform set_config('corban.membership_rpc', 'on', true);
  insert into public.organization_admin_events (organization_id, actor_user_id, event_type, details)
  values (p_org, auth.uid(), 'api_key_created', jsonb_build_object('api_key_id', v_id, 'name', btrim(p_name), 'scopes', p_scopes));
  perform set_config('corban.membership_rpc', 'off', true);
  return query select v_id, v_key, left(v_key, 16);
end
$$;

revoke all on function public.create_api_key(uuid, text, text[]) from public, anon;
grant execute on function public.create_api_key(uuid, text, text[]) to authenticated;

-- 2. Links and table aliases ---------------------------------------------------------------------------------------

-- One row per contract received through the API: the sender's id, the Corban contract and the last call applied.
create table public.api_contract_links (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  bank_id uuid not null references public.organization_banks(id) on delete restrict,
  external_id text not null check (length(external_id) between 1 and 120),
  proposal_id uuid not null unique references public.proposals_v2(id) on delete restrict,
  api_key_id uuid not null references public.api_keys(id) on delete restrict,
  last_sequence bigint not null check (last_sequence >= 0),
  last_sent_at timestamptz not null,
  last_external_stage text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, bank_id, external_id)
);

alter table public.api_contract_links enable row level security;
revoke all on table public.api_contract_links from anon, authenticated;
grant select on public.api_contract_links to authenticated;
create policy api_contract_links_select_admin on public.api_contract_links for select to authenticated
  using (private.caller_role_in(organization_id) = 'admin');

-- When the sender's table name does not end a Corban table name (e.g. one sender table used for new, refinancing
-- and debt purchase, while Corban has one table per type), the administrator says which Corban table it is.
create table public.api_contract_table_aliases (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  bank_id uuid not null references public.organization_banks(id) on delete restrict,
  external_table text not null check (length(btrim(external_table)) between 1 and 160),
  contract_type_key text not null check (contract_type_key ~ '^[a-z_]{2,40}$'),
  product_table_id uuid not null references public.product_tables(id) on delete restrict,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (organization_id, bank_id, external_table, contract_type_key)
);

alter table public.api_contract_table_aliases enable row level security;
revoke all on table public.api_contract_table_aliases from anon, authenticated;
grant select on public.api_contract_table_aliases to authenticated;
create policy api_contract_table_aliases_select_admin on public.api_contract_table_aliases for select to authenticated
  using (private.caller_role_in(organization_id) = 'admin');

-- 3. Helpers -------------------------------------------------------------------------------------------------------

create or replace function private.api_text_key(p text)
returns text language sql immutable set search_path to '' as $$
  select lower(btrim(regexp_replace(translate(coalesce(p, ''), 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇáàâãäéèêëíìîïóòôõöúùûüç', 'AAAAAEEEEIIIIOOOOOUUUUCaaaaaeeeeiiiiooooouuuuc'), '\s+', ' ', 'g')))
$$;

-- NASP stage code into the Corban stage (owner decision, 12/10/2026). Unknown code: null.
create or replace function private.api_nasp_stage(p text)
returns text language sql immutable set search_path to '' as $$
  select case p
    when 'digitado' then 'submitted' when 'em_validacao' then 'submitted' when 'em_averbacao' then 'submitted'
    when 'pendente' then 'pending_external'
    when 'averbado' then 'approved' when 'aguardando_assinatura' then 'approved' when 'aguardando_pagamento' then 'approved'
    when 'credito_liberado' then 'paid' when 'recusado' then 'rejected' when 'cancelado' then 'cancelled' end
$$;

-- Money from JSON: a number or a decimal string with a dot ("5000.00"), up to 2 decimals. Read as numeric, never float.
create or replace function private.api_money(p jsonb)
returns numeric language plpgsql immutable set search_path to '' as $$
declare v text;
begin
  if p is null or jsonb_typeof(p) = 'null' then return null; end if;
  if jsonb_typeof(p) not in ('number', 'string') then raise exception 'invalid_amount'; end if;
  v := btrim(p #>> '{}');
  if v = '' then return null; end if;
  if v !~ '^[0-9]{1,9}(\.[0-9]{1,2})?$' then raise exception 'invalid_amount'; end if;
  return v::numeric;
end
$$;

revoke all on function private.api_text_key(text) from public;
revoke all on function private.api_nasp_stage(text) from public;
revoke all on function private.api_money(jsonb) from public;

-- 4. Client record: fills only what is empty, like the spreadsheet import. Never blocks the contract. ---------------

create or replace function private.api_contract_enrich_client(p_org uuid, p_client uuid, p_agreement uuid, cl jsonb)
returns text[]
language plpgsql
security definer
set search_path to ''
as $$
declare
  cur public.clients%rowtype;
  w text[] := '{}';
  v text;
  g text; m text; rg_state text; bp_state text; wa text; bd date; rgd date;
  a jsonb := coalesce(cl->'endereco', '{}'::jsonb);
  b jsonb := coalesce(cl->'conta_bancaria', '{}'::jsonb);
  r jsonb := coalesce(cl->'matricula', '{}'::jsonb);
  v_zip text; v_code text; v_branch text; v_number text; v_type text; v_reg text;
  t text := '';
begin
  select * into cur from public.clients where id = p_client and organization_id = p_org;

  -- Personal data
  begin
    begin bd := nullif(btrim(coalesce(cl->>'data_nascimento', '')), '')::date; exception when others then bd := null; w := array_append(w, 'data_nascimento'::text); end;
    begin rgd := nullif(btrim(coalesce(cl->>'rg_data_expedicao', '')), '')::date; exception when others then rgd := null; w := array_append(w, 'rg_data_expedicao'::text); end;
    if bd is not null and (bd > current_date or bd < date '1900-01-01') then bd := null; w := array_append(w, 'data_nascimento'::text); end if;
    if rgd is not null and (rgd > current_date or rgd < date '1900-01-01') then rgd := null; w := array_append(w, 'rg_data_expedicao'::text); end if;
    g := case left(private.api_text_key(cl->>'sexo'), 1) when 'm' then 'M' when 'h' then 'M' when 'f' then 'F' end;
    if g is null and private.api_text_key(cl->>'sexo') like 'mulher%' then g := 'F'; end if;
    v := private.api_text_key(cl->>'estado_civil');
    m := case when v ~ '^solteir' then 'single' when v ~ '^casad' then 'married' when v ~ '^(uniao estavel|companheir|amasiad)' then 'stable_union'
              when v ~ '^divorciad' then 'divorced' when v ~ '^(separad|desquitad)' then 'separated' when v ~ '^viuv' then 'widowed' end;
    if v <> '' and m is null then w := array_append(w, 'estado_civil'::text); end if;
    rg_state := upper(btrim(coalesce(cl->>'rg_uf', ''))); if rg_state !~ '^[A-Z]{2}$' then rg_state := null; end if;
    wa := regexp_replace(coalesce(cl->>'whatsapp', ''), '\D', '', 'g');
    if wa ~ '^[0-9]{10,11}$' then wa := '55' || wa; end if;
    if wa !~ '^55[0-9]{10,11}$' then wa := null; end if;
    -- Naturalidade may come as "Cidade/UF" or "Cidade - UF".
    v := btrim(coalesce(cl->>'naturalidade', ''));
    bp_state := upper(substring(v from '[/-]\s*([A-Za-z]{2})\s*$'));
    if bp_state is not null then v := btrim(regexp_replace(v, '\s*[/-]\s*[A-Za-z]{2}\s*$', '')); end if;

    perform public.update_client_profile(p_client,
      coalesce(cur.birth_date, bd),
      coalesce(cur.father_name, case when length(btrim(coalesce(cl->>'nome_pai', ''))) between 3 and 160 then btrim(cl->>'nome_pai') end),
      coalesce(cur.mother_name, case when length(btrim(coalesce(cl->>'nome_mae', ''))) between 3 and 160 then btrim(cl->>'nome_mae') end),
      coalesce(cur.rg_number, case when btrim(coalesce(cl->>'rg', '')) ~ '^[0-9A-Za-z.\-/ ]{3,20}$' then btrim(cl->>'rg') end),
      coalesce(cur.rg_issuer, case when length(btrim(coalesce(cl->>'rg_orgao_emissor', ''))) between 2 and 20 then btrim(cl->>'rg_orgao_emissor') end),
      coalesce(cur.rg_state, rg_state),
      coalesce(cur.rg_issued_on, rgd),
      coalesce(cur.gender, g),
      coalesce(cur.marital_status, m),
      coalesce(cur.birthplace_city, case when length(v) between 2 and 120 then v end),
      coalesce(cur.birthplace_state, bp_state),
      coalesce(cur.whatsapp, wa));
  exception when others then w := array_append(w, 'dados_pessoais'::text);
  end;

  -- Address: only when the client has no primary one.
  v_zip := regexp_replace(coalesce(a->>'cep', ''), '\D', '', 'g');
  if v_zip ~ '^[0-9]{8}$' and not exists (select 1 from public.customer_addresses x where x.customer_id = p_client and x.is_primary) then
    begin
      insert into public.customer_addresses (organization_id, customer_id, is_primary, postal_code, street, number, complement, neighborhood, city, state)
      values (p_org, p_client, true, v_zip,
        nullif(left(btrim(coalesce(a->>'logradouro', '')), 160), ''), nullif(left(btrim(coalesce(a->>'numero', '')), 20), ''),
        nullif(left(btrim(coalesce(a->>'complemento', '')), 80), ''), nullif(left(btrim(coalesce(a->>'bairro', '')), 120), ''),
        nullif(left(btrim(coalesce(a->>'cidade', '')), 120), ''),
        case when upper(btrim(coalesce(a->>'uf', ''))) ~ '^[A-Z]{2}$' then upper(btrim(a->>'uf')) end);
    exception when others then w := array_append(w, 'endereco'::text);
    end;
  elsif v_zip <> '' and v_zip !~ '^[0-9]{8}$' then w := array_append(w, 'endereco'::text);
  end if;

  -- Bank account for the client's credit: added when the client does not have the same one.
  v_number := regexp_replace(coalesce(b->>'conta', ''), '\D', '', 'g');
  if v_number <> '' then
    v_code := regexp_replace(coalesce(b->>'banco_codigo', ''), '\D', '', 'g');
    v_branch := regexp_replace(coalesce(b->>'agencia', ''), '[^0-9Xx-]', '', 'g');
    v := private.api_text_key(b->>'tipo');
    v_type := case when v ~ '^(corrente|cc$)' then 'checking' when v ~ '^(poupanca|cp$)' then 'savings' when v ~ '^salario' then 'salary'
                   when v ~ '^pagamento' then 'payment' else 'checking' end;
    if v_code = '' or length(v_code) > 3 or v_branch = '' then w := array_append(w, 'conta_bancaria'::text);
    elsif not exists (select 1 from public.customer_bank_accounts x where x.customer_id = p_client and x.bank_code = lpad(v_code, 3, '0')
                      and x.branch = v_branch and x.account_number = v_number) then
      begin
        perform public.add_client_bank_account(p_client, lpad(v_code, 3, '0'),
          coalesce(nullif(left(btrim(coalesce(b->>'banco_nome', '')), 120), ''), lpad(v_code, 3, '0')), v_branch, v_number,
          nullif(upper(regexp_replace(coalesce(b->>'conta_digito', ''), '[^0-9Xx]', '', 'g')), ''), v_type,
          not exists (select 1 from public.customer_bank_accounts x where x.customer_id = p_client and x.is_primary));
      exception when others then w := array_append(w, 'conta_bancaria'::text);
      end;
    end if;
  end if;

  -- Registration (matrícula) in the agreement of the contract's table.
  v_reg := left(btrim(regexp_replace(coalesce(r->>'numero', ''), '\s+', ' ', 'g')), 40);
  if v_reg <> '' and p_agreement is not null
     and not exists (select 1 from public.client_registrations x where x.customer_id = p_client and x.registration_number = v_reg) then
    begin
      perform public.save_client_registration(p_client, null, p_agreement,
        case when length(btrim(coalesce(r->>'secretaria', ''))) between 2 and 160 then btrim(r->>'secretaria') end,
        v_reg, 'active', null, null, null, null, false, null);
    exception when others then w := array_append(w, 'matricula'::text);
    end;
  end if;
  return w;
end
$$;

revoke all on function private.api_contract_enrich_client(uuid, uuid, uuid, jsonb) from public, anon, authenticated;

-- 5. Apply one call. Runs as the key's administrator (claims set by the caller). Raises a stable code on refusal. ----

create or replace function private.api_contract_apply(p_org uuid, p_key_id uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  et jsonb := coalesce(p->'etapa', '{}'::jsonb);
  ct jsonb := coalesce(p->'contrato', '{}'::jsonb);
  cl jsonb := coalesce(p->'cliente', '{}'::jsonb);
  vd jsonb := coalesce(p->'vendedor', '{}'::jsonb);
  v_ext text := btrim(coalesce(p->>'external_id', ''));
  v_seq bigint; v_sent timestamptz;
  v_code text := btrim(coalesce(et->>'codigo_nasp', ''));
  v_state text; v_paid_on date; v_obs text := nullif(left(btrim(coalesce(et->>'observacao', '')), 500), '');
  v_bank uuid; v_bank_name text;
  v_type_key text; v_type uuid;
  v_table text := btrim(coalesce(ct->>'tabela', ''));
  v_term int; v_released numeric; v_installment numeric; v_outstanding numeric;
  v_ade text := nullif(btrim(coalesce(ct->>'ade', '')), '');
  v_cpf text := regexp_replace(coalesce(cl->>'cpf', ''), '\D', '', 'g');
  v_name text := btrim(regexp_replace(coalesce(cl->>'nome', ''), '\s+', ' ', 'g'));
  v_phone text; v_email text := nullif(lower(btrim(coalesce(cl->>'email', ''))), '');
  v_agent text := btrim(coalesce(vd->>'agente', ''));
  v_version uuid; v_agreement uuid; v_n int;
  v_seller uuid; v_client uuid; v_proposal uuid; v_dup boolean; v_created boolean := false;
  l public.api_contract_links%rowtype;
  pr public.proposals_v2%rowtype;
  v_case uuid; v_case_state text; v_stage uuid;
  v_data jsonb := '{}'::jsonb;
  v_details jsonb := '{}'::jsonb;
  v_warn text[] := '{}';
  v_part text;
begin
  -- Identity and order
  if length(v_ext) not between 1 and 120 then raise exception 'invalid_external_id'; end if;
  if jsonb_typeof(p->'sequencia') is distinct from 'number' or (p->>'sequencia') !~ '^[0-9]{1,15}$' then raise exception 'invalid_sequence'; end if;
  v_seq := (p->>'sequencia')::bigint;
  begin v_sent := (p->>'enviado_em')::timestamptz; exception when others then raise exception 'invalid_sent_at'; end;
  if v_sent is null then raise exception 'invalid_sent_at'; end if;

  -- Stage
  v_state := private.api_nasp_stage(v_code);
  if v_state is null then raise exception 'stage_unknown'; end if;
  begin v_paid_on := nullif(btrim(coalesce(et->>'pago_ao_cliente_em', '')), '')::date; exception when others then raise exception 'invalid_paid_on'; end;
  if v_state = 'paid' and v_paid_on is null then raise exception 'paid_on_required'; end if;
  if v_paid_on is not null and (v_paid_on > current_date or v_paid_on < date '2000-01-01') then raise exception 'invalid_paid_on'; end if;

  -- Bank, by name or technical key
  select count(*), (array_agg(b.id))[1], (array_agg(b.name))[1] into v_n, v_bank, v_bank_name from public.organization_banks b
  where b.organization_id = p_org and b.is_active
    and (private.api_text_key(b.name) = private.api_text_key(ct->>'banco') or lower(b.tech_key) = lower(btrim(coalesce(ct->>'banco', ''))));
  if v_n <> 1 then raise exception 'bank_not_found'; end if;

  -- Contract data
  v_type_key := case btrim(coalesce(ct->>'tipo_operacao', ''))
    when 'novo' then 'novo' when 'refinanciamento' then 'refinanciamento' when 'compra_divida' then 'compra_de_divida'
    when 'portabilidade' then 'portabilidade' end;
  if v_type_key is null then raise exception 'contract_type_unknown'; end if;
  select t.id into v_type from public.contract_types t
  where t.tech_key = v_type_key and t.is_active and (t.organization_id is null or t.organization_id = p_org)
  order by (t.organization_id is null) limit 1;
  if v_type is null then raise exception 'contract_type_unknown'; end if;
  if coalesce(ct->>'prazo_meses', '') !~ '^[0-9]{1,3}$' then raise exception 'invalid_term'; end if;
  v_term := (ct->>'prazo_meses')::int;
  if v_term not between 1 and 420 then raise exception 'invalid_term'; end if;
  v_released := private.api_money(ct->'valor_liberado');
  v_installment := private.api_money(ct->'valor_parcela');
  v_outstanding := private.api_money(ct->'saldo_devedor_origem');
  perform private.api_money(ct->'valor_liquido_cliente');
  if v_released is null or v_released <= 0 then raise exception 'invalid_amount'; end if;
  if v_ade is not null and v_ade !~ '^[0-9A-Za-z./-]{1,40}$' then raise exception 'invalid_ade'; end if;

  -- Table: an alias set by the administrator, else the Corban table whose name ends with " - <sender table>".
  if v_table = '' then raise exception 'table_not_found'; end if;
  select v.id, r.org_agreement_id into v_version, v_agreement
  from public.api_contract_table_aliases x
  join public.product_tables t on t.id = x.product_table_id and t.organization_id = p_org and t.status = 'active'
  join public.organization_product_routes r on r.id = t.route_id and r.organization_id = p_org and r.org_bank_id = v_bank
  join public.product_table_versions v on v.product_table_id = t.id and v.organization_id = p_org and v.status = 'published'
  where x.organization_id = p_org and x.bank_id = v_bank and x.contract_type_key = v_type_key
    and private.api_text_key(x.external_table) = private.api_text_key(v_table);
  if v_version is null then
    select count(*), (array_agg(q.version_id))[1], (array_agg(q.agreement_id))[1] into v_n, v_version, v_agreement
    from (
      select v.id version_id, r.org_agreement_id agreement_id
      from public.product_tables t
      join public.organization_product_routes r on r.id = t.route_id and r.organization_id = p_org and r.org_bank_id = v_bank
      join public.product_table_versions v on v.product_table_id = t.id and v.organization_id = p_org and v.status = 'published'
      where t.organization_id = p_org and t.status = 'active'
        and (private.api_text_key(t.name) = private.api_text_key(v_table)
             or right(private.api_text_key(t.name), length(private.api_text_key(v_table)) + 3) = ' - ' || private.api_text_key(v_table))
        and exists (select 1 from public.commercial_conditions cc where cc.product_table_version_id = v.id and cc.contract_type_id = v_type)
    ) q;
    if v_n = 0 then raise exception 'table_not_found'; end if;
    if v_n > 1 then raise exception 'table_ambiguous'; end if;
  end if;
  if exists (select 1 from public.commercial_conditions cc where cc.product_table_version_id = v_version and cc.contract_type_id = v_type)
     and not exists (select 1 from public.commercial_conditions cc where cc.product_table_version_id = v_version and cc.contract_type_id = v_type
                     and v_term between cc.term_min and cc.term_max) then
    raise exception 'term_out_of_table';
  end if;

  -- Seller: the agent, by exact name among active sellers. Not found: the contract comes without seller (commission waits).
  if v_agent <> '' then
    select count(*), (array_agg(s.id))[1] into v_n, v_seller from public.commercial_sellers s
    where s.organization_id = p_org and s.is_active and private.api_text_key(s.name) = private.api_text_key(v_agent);
    if v_n <> 1 then v_seller := null; v_warn := array_append(v_warn, case when v_n = 0 then 'seller_not_found' else 'seller_ambiguous' end::text); end if;
  end if;

  -- Client
  if not private.is_valid_cpf(v_cpf) then raise exception 'invalid_cpf'; end if;
  v_phone := private.normalize_phone(coalesce(nullif(btrim(coalesce(cl->>'celular', '')), ''), nullif(btrim(coalesce(cl->>'whatsapp', '')), ''), cl->>'telefone'));
  if v_email is not null and v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then v_email := null; v_warn := array_append(v_warn, 'invalid_email'::text); end if;

  perform pg_advisory_xact_lock(hashtext('api_contract:' || p_org::text || ':' || v_bank::text || ':' || v_ext));
  select * into l from public.api_contract_links x where x.organization_id = p_org and x.bank_id = v_bank and x.external_id = v_ext for update;

  -- Not newer than the last call applied: nothing changes (retry or out of order).
  if l.id is not null and v_seq <= l.last_sequence then
    select c.canonical_state into v_case_state from public.operational_cases c where c.proposal_id = l.proposal_id;
    return jsonb_build_object('id', l.proposal_id, 'created', false, 'duplicate', true, 'stale', v_seq < l.last_sequence,
                              'stage', v_case_state, 'warnings', to_jsonb(v_warn));
  end if;

  if l.id is null then
    select u.client_id into v_client from public.upsert_client(p_org, v_cpf, nullif(v_name, ''), v_phone, v_email, 'import') u;
    if v_client is null then raise exception 'client_not_found'; end if;
    if v_outstanding is not null then v_details := v_details || jsonb_build_object('outstanding_balance', v_outstanding::text); end if;
    if btrim(coalesce(ct->>'banco_origem', '')) <> '' then v_details := v_details || jsonb_build_object('origin_bank_name', left(btrim(ct->>'banco_origem'), 120)); end if;
    if btrim(coalesce(ct->>'contrato_origem', '')) <> '' then v_details := v_details || jsonb_build_object('origin_contract_number', left(btrim(ct->>'contrato_origem'), 60)); end if;
    select d.proposal_id, d.duplicate into v_proposal, v_dup
    from public.create_direct_proposal(p_org, v_client, v_version, v_seller, null, v_released, v_installment, v_term, v_ade,
                                       case when v_ade is null then 'digitization_queue' else 'submitted' end, v_type,
                                       case when v_details = '{}'::jsonb then null else v_details end) d;
    if exists (select 1 from public.api_contract_links x where x.proposal_id = v_proposal) then raise exception 'contract_linked_elsewhere'; end if;
    v_created := not v_dup;
    insert into public.api_contract_links (organization_id, bank_id, external_id, proposal_id, api_key_id, last_sequence, last_sent_at, last_external_stage)
    values (p_org, v_bank, v_ext, v_proposal, p_key_id, v_seq, v_sent, v_code);
  else
    v_proposal := l.proposal_id;
  end if;

  select * into pr from public.proposals_v2 where id = v_proposal;
  v_client := pr.customer_id;

  -- An existing contract follows the sender while open: ADE, values, term, table, type, seller if it had none.
  if not v_created then
    if v_ade is not null and v_ade is distinct from pr.external_proposal_id and pr.status not in ('rejected', 'cancelled') then
      begin
        perform public.set_contract_ade(pr.id, v_ade, 'Informado pela integração (' || v_bank_name || ')');
      exception when others then v_warn := array_append(v_warn, ('ade_not_updated:' || case when sqlerrm ~ '^[a-z_]{3,60}$' then sqlerrm else 'error' end)::text);
      end;
    end if;
    if pr.status not in ('paid', 'rejected', 'cancelled') then
      if v_version is distinct from pr.product_table_version_id then v_data := v_data || jsonb_build_object('table_version_id', v_version); end if;
      if v_type is distinct from pr.contract_type_id then v_data := v_data || jsonb_build_object('contract_type_id', v_type); end if;
      if v_term is distinct from pr.term then v_data := v_data || jsonb_build_object('term', v_term); end if;
      if v_released is distinct from pr.released_amount then v_data := v_data || jsonb_build_object('released_amount', v_released::text); end if;
      if v_installment is not null and v_installment is distinct from pr.installment_amount then v_data := v_data || jsonb_build_object('installment_amount', v_installment::text); end if;
      if v_outstanding is not null and v_outstanding is distinct from pr.outstanding_balance then v_data := v_data || jsonb_build_object('outstanding_balance', v_outstanding::text); end if;
      if pr.seller_id is null and v_seller is not null then v_data := v_data || jsonb_build_object('seller_id', v_seller); end if;
      if v_data <> '{}'::jsonb then
        begin
          perform public.update_contract(pr.id, v_data, 'Informado pela integração (' || v_bank_name || ')');
        exception when others then v_warn := array_append(v_warn, ('contract_not_updated:' || case when sqlerrm ~ '^[a-z_]{3,60}$' then sqlerrm else 'error' end)::text);
        end;
      end if;
    end if;
  end if;

  -- Client record: fills only what is empty.
  foreach v_part in array private.api_contract_enrich_client(p_org, v_client, v_agreement, cl) loop
    v_warn := array_append(v_warn, ('client_field_not_saved:' || v_part)::text);
  end loop;

  -- Stage. A closed contract (paid, rejected, cancelled) is never moved by the API.
  select c.id, c.canonical_state into v_case, v_case_state from public.operational_cases c where c.proposal_id = v_proposal;
  if v_case is null then raise exception 'case_not_found'; end if;
  if v_state is distinct from v_case_state then
    if v_case_state in ('paid', 'rejected', 'cancelled') then
      v_warn := array_append(v_warn, 'stage_locked'::text);
      if v_case_state = 'paid' and v_state = 'cancelled' then
        perform public.add_contract_note(v_proposal, v_bank_name || ' informou cancelamento depois do pagamento ao cliente. A integração não cancela contrato pago: confira e trate manualmente.');
      end if;
    else
      select s.id into v_stage from public.operational_stages s
      where s.organization_id = p_org and s.canonical_state = v_state and s.is_active order by s.sort_order limit 1;
      if v_stage is null then raise exception 'target_operational_stage_not_configured'; end if;
      v_case_state := public.move_case_to_stage(v_case, v_stage,
        case when v_state = 'pending_external' then coalesce(v_obs, v_bank_name || ': pendente') else v_bank_name || ': ' || v_code end,
        null, case when v_state = 'paid' then v_paid_on end);
    end if;
  end if;

  update public.api_contract_links
  set last_sequence = v_seq, last_sent_at = v_sent, last_external_stage = v_code, updated_at = now()
  where organization_id = p_org and bank_id = v_bank and external_id = v_ext;

  return jsonb_build_object('id', v_proposal, 'created', v_created, 'duplicate', not v_created, 'stale', false,
                            'stage', v_case_state, 'warnings', to_jsonb(v_warn));
end
$$;

revoke all on function private.api_contract_apply(uuid, uuid, jsonb) from public, anon, authenticated;

-- 6. Entry point -----------------------------------------------------------------------------------------------------

-- Authenticates the key, applies scope, modules and rate limit, then applies the call as the key's administrator.
-- The payload arrives as text so money keeps its exact decimal value. Returns JSON; error is a stable code.
create or replace function public.api_ingest_contract(p_key text, p_payload text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  k public.api_keys%rowtype;
  p jsonb;
  v_recent int;
  v_old_sub text := current_setting('request.jwt.claim.sub', true);
  v_old_claims text := current_setting('request.jwt.claims', true);
  v_result jsonb;
  v_error text;
begin
  select * into k from public.api_keys where key_hash = encode(extensions.digest(coalesce(p_key, ''), 'sha256'), 'hex');
  if not found or k.revoked_at is not null then return jsonb_build_object('error', 'invalid_api_key'); end if;

  select count(*) into v_recent from public.api_request_log l where l.api_key_id = k.id and l.occurred_at > now() - interval '1 minute';
  if v_recent >= k.rate_limit_per_minute then
    insert into public.api_request_log (api_key_id, organization_id, endpoint, outcome) values (k.id, k.organization_id, 'contracts.upsert', 'rate_limited');
    return jsonb_build_object('error', 'rate_limited');
  end if;
  update public.api_keys set last_used_at = now() where id = k.id;

  if not ('contracts.write' = any (k.scopes)) then
    insert into public.api_request_log (api_key_id, organization_id, endpoint, outcome) values (k.id, k.organization_id, 'contracts.upsert', 'forbidden');
    return jsonb_build_object('error', 'insufficient_scope');
  end if;
  if (select count(*) from public.organization_modules m where m.organization_id = k.organization_id and m.enabled and m.module_key in ('api', 'propostas', 'esteira')) < 3
     or not exists (select 1 from public.organizations o where o.id = k.organization_id and coalesce(o.is_active, true)) then
    insert into public.api_request_log (api_key_id, organization_id, endpoint, outcome) values (k.id, k.organization_id, 'contracts.upsert', 'module_disabled');
    return jsonb_build_object('error', 'module_disabled');
  end if;

  begin
    p := p_payload::jsonb;
  exception when others then p := null;
  end;
  if p is null or jsonb_typeof(p) <> 'object' then
    insert into public.api_request_log (api_key_id, organization_id, endpoint, outcome) values (k.id, k.organization_id, 'contracts.upsert', 'invalid_json');
    return jsonb_build_object('error', 'invalid_json');
  end if;

  -- The key acts as the administrator who created it, for this transaction only.
  perform set_config('request.jwt.claim.sub', coalesce(k.created_by::text, ''), true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', k.created_by, 'role', 'authenticated')::text, true);
  begin
    if k.created_by is null or not public.has_active_organization_role(k.organization_id, array['admin']) then
      raise exception 'api_key_owner_inactive';
    end if;
    v_result := private.api_contract_apply(k.organization_id, k.id, p);
  exception when others then
    -- Only our own codes go back; anything else (it could carry data) becomes internal_error.
    v_error := case when sqlerrm ~ '^[a-z_]{3,60}$' then sqlerrm else 'internal_error' end;
  end;
  perform set_config('request.jwt.claim.sub', coalesce(v_old_sub, ''), true);
  perform set_config('request.jwt.claims', coalesce(v_old_claims, ''), true);

  insert into public.api_request_log (api_key_id, organization_id, endpoint, outcome)
  values (k.id, k.organization_id, 'contracts.upsert', coalesce(v_error,
    case when (v_result->>'created')::boolean then 'created' when (v_result->>'stale')::boolean then 'stale' else 'updated' end));
  if v_error is not null then return jsonb_build_object('error', v_error); end if;
  return v_result;
end
$$;

revoke all on function public.api_ingest_contract(text, text) from public, anon, authenticated;
grant execute on function public.api_ingest_contract(text, text) to service_role;
