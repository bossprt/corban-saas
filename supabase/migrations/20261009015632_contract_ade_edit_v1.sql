-- Change a contract's ADE (number of the contract at the bank) from the Contratos screen (owner request 08/10/2026).
--
-- The ADE is unique per company (proposals_v2_org_external_id_key) and the bank's reports find the contract by it
-- through proposal_external_identities. The change: whoever can edit contracts (same gate as update_contract; a paid
-- contract only by admin/manager and with a reason); an ADE already used by another contract of the company, or
-- registered for another contract of the same bank, is refused; the old identity stays (a report with the old number
-- still finds the contract) and the new number is added under the same bank key; before -> after goes to the contract
-- history.
-- Contract: tests/security/contract-ade-edit-contract.sql

create or replace function public.set_contract_ade(p_proposal uuid, p_ade text, p_reason text default null)
returns void language plpgsql security definer set search_path to '' as $$
declare p public.proposals_v2%rowtype; v_ade text := btrim(coalesce(p_ade, '')); v_key text; v_bank_key text;
begin
  select * into p from public.proposals_v2 where id = p_proposal for update;
  if p.id is null or auth.uid() is null or not public.is_active_organization_member(p.organization_id)
     or not private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by)
     or not (public.has_permission(p.organization_id, 'propostas.edit') or public.has_permission(p.organization_id, 'financeiro.edit')) then
    raise exception 'not_authorized';
  end if;
  if p.status in ('rejected', 'cancelled') then raise exception 'contract_closed'; end if;
  if p.status = 'paid' and not public.has_active_organization_role(p.organization_id, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  if p.status = 'paid' and length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'reason_required'; end if;
  if p_reason is not null and length(p_reason) > 2000 then raise exception 'reason_required'; end if;
  if v_ade !~ '^[0-9A-Za-z./-]{1,40}$' then raise exception 'invalid_ade'; end if;
  if v_ade is not distinct from p.external_proposal_id then return; end if;
  if exists (select 1 from public.proposals_v2 x where x.organization_id = p.organization_id and x.id <> p.id
             and (x.external_proposal_id = v_ade or private.norm_ade(x.external_proposal_id) = private.norm_ade(v_ade))) then
    raise exception 'ade_taken';
  end if;

  -- The bank key of the contract: its existing identities, else the bank of its table.
  select b.tech_key into v_bank_key
  from public.product_table_versions v join public.product_tables t on t.id = v.product_table_id
  join public.organization_product_routes r on r.id = t.route_id join public.organization_banks b on b.id = r.org_bank_id
  where v.id = p.product_table_version_id;
  for v_key in select distinct e.institution_key from public.proposal_external_identities e where e.proposal_id = p.id
               union select v_bank_key where v_bank_key is not null loop
    if exists (select 1 from public.proposal_external_identities e where e.organization_id = p.organization_id
               and lower(e.institution_key) = lower(v_key) and e.external_proposal_number = v_ade and e.proposal_id <> p.id) then
      raise exception 'ade_taken';
    end if;
    insert into public.proposal_external_identities (organization_id, proposal_id, institution_key, external_proposal_number, source, metadata)
    values (p.organization_id, p.id, v_key, v_ade, 'ade_edit', jsonb_build_object('previous', p.external_proposal_id))
    on conflict do nothing;
  end loop;

  perform set_config('corban.contract_edit_rpc', 'on', true);
  update public.proposals_v2 set external_proposal_id = v_ade, updated_at = now() where id = p.id;
  perform set_config('corban.contract_edit_rpc', 'off', true);
  perform set_config('corban.contract_rpc', 'on', true);
  insert into public.contract_events (organization_id, proposal_id, kind, detail, reason, actor_user_id)
  values (p.organization_id, p.id, 'edit', jsonb_build_object('external_proposal_id', jsonb_build_object('from', p.external_proposal_id, 'to', v_ade)),
          nullif(btrim(coalesce(p_reason, '')), ''), auth.uid());
  perform set_config('corban.contract_rpc', 'off', true);
end
$$;

revoke all on function public.set_contract_ade(uuid, text, text) from public, anon;
grant execute on function public.set_contract_ade(uuid, text, text) to authenticated;
