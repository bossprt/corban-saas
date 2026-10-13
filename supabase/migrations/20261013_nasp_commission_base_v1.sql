-- NASP commission base (owner decision 13/10/2026): Novo and Refinanciamento on the net amount (LÍQUIDO), Compra de
-- dívida on the gross amount (BRUTO).
--
-- 1. Catalog: the NASP tables whose Compra de dívida line is still on LÍQUIDO (Governo do Acre "COMPRA NORMAL" and the
--    Prefeitura "Normal - Efetivo / Pensionista") get a new vigência from 01/01/2026 with that line on BRUTO; everything
--    else is copied as is. The previous vigência stays as superseded history; contracts already registered keep their
--    own calculation. Through the catalog RPCs, as the company's first administrator; runs only where the tables exist.
-- 2. Contracts API: the gross amount (valor_liberado) is stored as the contract amount (requested_amount) and the net
--    amount to the client (valor_liquido_cliente, the gross when not sent) as the released amount (released_amount).
--    Before, only the gross was stored (as released), so a LÍQUIDO line was calculated on the gross. A net above the
--    gross is refused (invalid_amount). The rest of private.api_contract_apply is unchanged.

do $$
declare
  v_org uuid;
  v_admin uuid;
  v_compra uuid;
  v_draft uuid;
  v_components jsonb;
  v_done integer := 0;
  r record;
  c record;
begin
  select t.organization_id into v_org from public.product_tables t where t.code = 'nasp-ac-temporario-4-7' limit 1;
  if v_org is null then raise notice 'nasp base: company not here, nothing to do'; return; end if;

  select m.user_id into v_admin from public.organization_memberships m
  where m.organization_id = v_org and m.role = 'admin' and m.status = 'active' order by m.created_at limit 1;
  select ct.id into v_compra from public.contract_types ct
  where ct.tech_key = 'compra_de_divida' and ct.is_active and (ct.organization_id is null or ct.organization_id = v_org)
  order by (ct.organization_id = v_org) desc nulls last limit 1;
  if v_admin is null or v_compra is null then raise exception 'nasp_base_missing_catalog'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  for r in
    select t.code, v.id as version_id
    from public.product_tables t
    join public.product_table_versions v on v.product_table_id = t.id and v.status = 'published'
    where t.organization_id = v_org and t.code like 'nasp-%'
      and exists (select 1 from public.commercial_conditions x join public.commercial_condition_components k on k.condition_id = x.id
                  where x.product_table_version_id = v.id and x.contract_type_id = v_compra and k.calculation_base <> 'BRUTO')
    order by t.code
  loop
    v_draft := public.clone_table_version(r.version_id);
    for c in select x.id from public.commercial_conditions x where x.product_table_version_id = v_draft and x.contract_type_id = v_compra loop
      select jsonb_agg(jsonb_build_object('component_type_id', k.component_type_id, 'value_kind', k.value_kind, 'received_value', k.received_value,
                                          'calculation_base', 'BRUTO', 'source', k.source))
      into v_components from public.commercial_condition_components k where k.condition_id = c.id;
      if v_components is null then raise exception 'nasp_base_no_components: %', r.code; end if;
      perform public.replace_commercial_condition_components(c.id, v_components);
    end loop;
    perform public.publish_product_table_version(v_draft, date '2026-01-01');
    if not exists (select 1 from public.product_table_versions v where v.id = v_draft and v.status = 'published') then
      raise exception 'nasp_base_not_published: %', r.code;
    end if;
    v_done := v_done + 1;
  end loop;

  perform set_config('request.jwt.claims', '', true);
  raise notice 'nasp base: % tables now have Compra de dívida on BRUTO', v_done;
end
$$;

-- 2. Contracts API ------------------------------------------------------------------------------------------------

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
  v_term int; v_gross numeric; v_net numeric; v_installment numeric; v_outstanding numeric;
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
  -- valor_liberado is the contract's gross amount (Corban requested_amount, "valor do contrato"); valor_liquido_cliente is
  -- what the client receives (Corban released_amount, "valor liberado"; the gross when not sent). Lines on BRUTO use the
  -- first, lines on LÍQUIDO the second.
  v_gross := private.api_money(ct->'valor_liberado');
  v_net := coalesce(private.api_money(ct->'valor_liquido_cliente'), v_gross);
  v_installment := private.api_money(ct->'valor_parcela');
  v_outstanding := private.api_money(ct->'saldo_devedor_origem');
  if v_gross is null or v_gross <= 0 or v_net <= 0 or v_net > v_gross then raise exception 'invalid_amount'; end if;
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
    from public.create_direct_proposal(p_org, v_client, v_version, v_seller, v_gross, v_net, v_installment, v_term, v_ade,
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
      if v_gross is distinct from pr.requested_amount then v_data := v_data || jsonb_build_object('requested_amount', v_gross::text); end if;
      if v_net is distinct from pr.released_amount then v_data := v_data || jsonb_build_object('released_amount', v_net::text); end if;
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
