-- "Associar proposta" (owner request 08/10/2026): when a proposal is typed at a bank, the company already says who the
-- seller is (bank, proposal number/ADE, client's CPF and name, seller). When the contract reaches the Corban (any import
-- layout, the screen, the portal), the seller of the association is set on it automatically. Owner decision: the
-- association wins over the seller the bank's spreadsheet brings.
--
-- Matching, always inside the same bank (the bank of the contract's table):
--   * by ADE (normalized, as the bank reports are matched) first;
--   * by CPF only for a contract created after the association (an older contract of the same client is never touched).
-- An association is used once. A contract that already exists with the ADE gets the seller at once (same path as editing
-- the contract: history, recalculation; refused if the seller was already paid). An association is never deleted: it can
-- be cancelled with a reason. CPF is personal data: only who can edit contracts reads the associations.
-- Contract: tests/security/proposal-seller-links-contract.sql

create table public.proposal_seller_links (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  org_bank_id uuid not null,
  ade text check (ade is null or ade ~ '^[0-9A-Za-z./-]{1,40}$'),
  cpf text check (cpf is null or cpf ~ '^[0-9]{11}$'),
  client_name text check (client_name is null or length(btrim(client_name)) between 2 and 160),
  seller_id uuid not null,
  status text not null default 'waiting' check (status in ('waiting', 'used', 'cancelled')),
  proposal_id uuid,
  matched_by text check (matched_by in ('ade', 'cpf')),
  used_at timestamptz,
  cancel_reason text,
  cancelled_at timestamptz,
  cancelled_by uuid references auth.users(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check (ade is not null or cpf is not null),
  check ((status = 'used') = (proposal_id is not null)),
  unique (organization_id, id),
  foreign key (organization_id, org_bank_id) references public.organization_banks(organization_id, id) on delete restrict,
  foreign key (organization_id, seller_id) references public.commercial_sellers(organization_id, id) on delete restrict,
  foreign key (organization_id, proposal_id) references public.proposals_v2(organization_id, id) on delete restrict
);
create index proposal_seller_links_waiting_ade_idx on public.proposal_seller_links (organization_id, org_bank_id, private.norm_ade(ade)) where status = 'waiting' and ade is not null;
create index proposal_seller_links_waiting_cpf_idx on public.proposal_seller_links (organization_id, org_bank_id, cpf) where status = 'waiting' and cpf is not null;
create unique index proposal_seller_links_one_waiting_ade on public.proposal_seller_links (organization_id, org_bank_id, private.norm_ade(ade)) where status = 'waiting' and ade is not null;

alter table public.proposal_seller_links enable row level security;
revoke all on public.proposal_seller_links from public, anon, authenticated;
grant select on public.proposal_seller_links to authenticated;
create policy proposal_seller_links_select on public.proposal_seller_links for select to authenticated
  using (public.has_permission(organization_id, 'propostas.edit') or public.has_permission(organization_id, 'financeiro.edit'));

-- The bank of a table version (the contract's bank).
create or replace function private.bank_of_version(p_version uuid)
returns uuid language sql stable security definer set search_path to '' as $$
  select r.org_bank_id from public.product_table_versions v join public.product_tables t on t.id = v.product_table_id
  join public.organization_product_routes r on r.id = t.route_id where v.id = p_version
$$;
revoke all on function private.bank_of_version(uuid) from public, anon, authenticated;

-- A new contract takes the seller of a waiting association of its bank (by ADE, else by the client's CPF).
create or replace function private.apply_seller_link_on_insert()
returns trigger language plpgsql security definer set search_path to '' as $$
declare v_bank uuid; v_cpf text; l public.proposal_seller_links%rowtype; v_by text;
begin
  v_bank := private.bank_of_version(new.product_table_version_id);
  if v_bank is null then return null; end if;
  if new.external_proposal_id is not null then
    select * into l from public.proposal_seller_links x where x.organization_id = new.organization_id and x.org_bank_id = v_bank
      and x.status = 'waiting' and x.ade is not null and private.norm_ade(x.ade) = private.norm_ade(new.external_proposal_id)
    order by x.created_at desc limit 1 for update;
    if l.id is not null then v_by := 'ade'; end if;
  end if;
  if l.id is null then
    select c.cpf into v_cpf from public.clients c where c.id = new.customer_id;
    if v_cpf is not null then
      select * into l from public.proposal_seller_links x where x.organization_id = new.organization_id and x.org_bank_id = v_bank
        and x.status = 'waiting' and x.cpf = v_cpf and x.created_at <= new.created_at
      order by x.created_at desc limit 1 for update;
      if l.id is not null then v_by := 'cpf'; end if;
    end if;
  end if;
  if l.id is null then return null; end if;

  if new.seller_id is distinct from l.seller_id then
    perform set_config('corban.contract_edit_rpc', 'on', true);
    update public.proposals_v2 set seller_id = l.seller_id, updated_at = now() where id = new.id;
    perform set_config('corban.contract_edit_rpc', 'off', true);
    perform set_config('corban.contract_rpc', 'on', true);
    insert into public.contract_events (organization_id, proposal_id, kind, detail, reason, actor_user_id)
    values (new.organization_id, new.id, 'edit', jsonb_build_object('seller_id', jsonb_build_object('from', new.seller_id, 'to', l.seller_id,
              'from_label', (select name from public.commercial_sellers where id = new.seller_id), 'to_label', (select name from public.commercial_sellers where id = l.seller_id))),
            'Vendedor da proposta associada (' || case when v_by = 'ade' then 'nº ' || l.ade else 'CPF' end || ')', auth.uid());
    perform set_config('corban.contract_rpc', 'off', true);
  end if;
  update public.proposal_seller_links set status = 'used', proposal_id = new.id, matched_by = v_by, used_at = now() where id = l.id;
  return null;
end
$$;
revoke all on function private.apply_seller_link_on_insert() from public, anon, authenticated;
-- After insert and before the deferred commission calculation (it runs at commit and reads the seller then).
create trigger proposals_v2_70_seller_link after insert on public.proposals_v2
for each row execute function private.apply_seller_link_on_insert();

-- Create an association; a contract that already has this ADE in this bank gets the seller now.
create or replace function public.link_proposal_seller(p_org uuid, p_bank uuid, p_ade text, p_cpf text, p_name text, p_seller uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_ade text := nullif(btrim(coalesce(p_ade, '')), ''); v_cpf text := nullif(regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g'), '');
        v_id uuid; v_proposal uuid; v_applied boolean := false; v_reason text;
begin
  if auth.uid() is null or p_org is null or not (public.has_permission(p_org, 'propostas.edit') or public.has_permission(p_org, 'financeiro.edit')) then raise exception 'not_authorized'; end if;
  if not exists (select 1 from public.organization_banks b where b.id = p_bank and b.organization_id = p_org) then raise exception 'bank_not_found'; end if;
  if not exists (select 1 from public.commercial_sellers s where s.id = p_seller and s.organization_id = p_org and s.is_active) then raise exception 'seller_not_found'; end if;
  if v_ade is null and v_cpf is null then raise exception 'ade_or_cpf_required'; end if;
  if v_ade is not null and v_ade !~ '^[0-9A-Za-z./-]{1,40}$' then raise exception 'invalid_ade'; end if;
  if v_cpf is not null and v_cpf !~ '^[0-9]{11}$' then raise exception 'invalid_cpf'; end if;
  if v_ade is not null and exists (select 1 from public.proposal_seller_links x where x.organization_id = p_org and x.org_bank_id = p_bank
       and x.status = 'waiting' and x.ade is not null and private.norm_ade(x.ade) = private.norm_ade(v_ade)) then raise exception 'link_already_waiting'; end if;

  insert into public.proposal_seller_links (organization_id, org_bank_id, ade, cpf, client_name, seller_id, created_by)
  values (p_org, p_bank, v_ade, v_cpf, nullif(btrim(coalesce(p_name, '')), ''), p_seller, auth.uid()) returning id into v_id;

  if v_ade is not null then
    select p.id into v_proposal from public.proposals_v2 p
    where p.organization_id = p_org and p.external_proposal_id is not null and private.norm_ade(p.external_proposal_id) = private.norm_ade(v_ade)
      and private.bank_of_version(p.product_table_version_id) = p_bank and p.status not in ('rejected', 'cancelled')
    limit 1;
    if v_proposal is not null then
      begin
        perform public.update_contract(v_proposal, jsonb_build_object('seller_id', p_seller), 'Vendedor da proposta associada (nº ' || v_ade || ')');
        update public.proposal_seller_links set status = 'used', proposal_id = v_proposal, matched_by = 'ade', used_at = now() where id = v_id;
        v_applied := true;
      exception when others then
        v_reason := case when sqlerrm like '%contract_payout_received%' then 'payout_received' when sqlerrm like '%not_authorized%' then 'not_authorized' else 'not_applied' end;
      end;
    end if;
  end if;
  return jsonb_build_object('link_id', v_id, 'applied', v_applied, 'proposal_id', case when v_applied then v_proposal end, 'reason', v_reason);
end
$$;

create or replace function public.cancel_proposal_seller_link(p_link uuid, p_reason text)
returns void language plpgsql security definer set search_path to '' as $$
declare l public.proposal_seller_links%rowtype;
begin
  select * into l from public.proposal_seller_links where id = p_link for update;
  if l.id is null or auth.uid() is null or not (public.has_permission(l.organization_id, 'propostas.edit') or public.has_permission(l.organization_id, 'financeiro.edit')) then raise exception 'not_authorized'; end if;
  if l.status <> 'waiting' then raise exception 'link_not_waiting'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 or length(p_reason) > 300 then raise exception 'cancel_reason_required'; end if;
  update public.proposal_seller_links set status = 'cancelled', cancel_reason = btrim(p_reason), cancelled_at = now(), cancelled_by = auth.uid() where id = l.id;
end
$$;

revoke all on function public.link_proposal_seller(uuid, uuid, text, text, text, uuid) from public, anon;
revoke all on function public.cancel_proposal_seller_link(uuid, text) from public, anon;
grant execute on function public.link_proposal_seller(uuid, uuid, text, text, text, uuid) to authenticated;
grant execute on function public.cancel_proposal_seller_link(uuid, text) to authenticated;
