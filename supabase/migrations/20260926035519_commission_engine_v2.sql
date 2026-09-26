-- Commission engine v2, part C1 of the payout bridge (owner decisions 26/09/2026, ADR-0037).
--
-- 1. Tax per table line. Every line of a commission table carries "Imposto (%)": the company pays that % on what it
--    receives for the line (the invoice value); 0 = the company pays no tax on it. The owner keeps a fixed average of the
--    Simples Nacional rate and changes it by exporting the table, editing and importing it again (a new vigência).
--    Existing lines start at 0: nothing about tax was registered before. Written only on drafts, like the rest of a line.
-- 2. IR withheld by the bank. A bank that pays commissions with income tax withheld at source (Daycoval 0,5%) carries
--    that % in its registration; written only through set_bank_ir_withheld.
-- 3. Whether the company pays tax on a bank's production is not stored anywhere: bank_tax_situation reads it from the
--    current published version of the bank's tables (all lines with tax, none, or mixed).
-- 4. calculate_contract_commission: the engine that follows the seller group rules (part A) and the table values per
--    group (part B). Per commission type of the line:
--      received   = company value (% of the gross or net amount, or fixed R$), to the cent
--      originator = the group rule's % of the column it reads (own group, company or another group), to the cent
--      supervisor / manager = rule % of the spread (received − originator), of the payout, or of the production (the
--                   gross amount, counted once, on the à vista type); only when the seller has them in the hierarchy
--      tax        = line tax % of received;  ir_withheld = bank % of received
--      company    = received − tax − ir_withheld − originator − supervisor − manager (the margin; can be negative)
--    The seller never pays tax. Payouts above what the company receives are refused, and so is a % without its base
--    (gross or net amount): the smart import now reads a "Base de Cálculo" column or asks for one. Deferred amounts
--    are split into the installments like before. The calculation is frozen once the contract is paid or its payout
--    was posted.
--    The ChatGPT-era calculate_proposal_commission (cascade / group_table over commission_rule_versions) stays until
--    the legacy cleanup (C4); nothing in the app calls it any more.

alter table public.commercial_conditions add column tax_pct numeric(9,6) not null default 0 check (tax_pct between 0 and 100);

alter table public.organization_banks add column ir_withheld_pct numeric(9,6) not null default 0 check (ir_withheld_pct between 0 and 100);

create or replace function private.guard_bank_ir_withheld()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if current_user in ('authenticated', 'anon') and current_setting('corban.bank_tax_rpc', true) is distinct from 'on'
     and ((tg_op = 'INSERT' and new.ir_withheld_pct <> 0) or (tg_op = 'UPDATE' and new.ir_withheld_pct is distinct from old.ir_withheld_pct)) then
    raise exception 'bank_tax_requires_governed_rpc';
  end if;
  return new;
end
$$;
revoke all on function private.guard_bank_ir_withheld() from public, anon, authenticated;
create trigger organization_banks_01_ir_withheld_guard before insert or update on public.organization_banks
  for each row execute function private.guard_bank_ir_withheld();

create or replace function public.set_bank_ir_withheld(p_bank uuid, p_pct text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  b public.organization_banks%rowtype;
  v numeric;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into b from public.organization_banks where id = p_bank;
  if b.id is null or not public.has_active_organization_role(b.organization_id, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  if coalesce(p_pct, '') = '' then v := 0;
  elsif p_pct !~ '^[0-9]{1,3}(\.[0-9]{1,6})?$' then raise exception 'invalid_ir_withheld';
  else v := p_pct::numeric; end if;
  if v > 100 then raise exception 'invalid_ir_withheld'; end if;
  perform set_config('corban.bank_tax_rpc', 'on', true);
  update public.organization_banks set ir_withheld_pct = trim_scale(v) where id = b.id;
  perform set_config('corban.bank_tax_rpc', 'off', true);
end
$$;
revoke all on function public.set_bank_ir_withheld(uuid, text) from public, anon;
grant execute on function public.set_bank_ir_withheld(uuid, text) to authenticated;

-- Lines of the current published version of each active table, per bank: with tax and without.
create or replace function public.bank_tax_situation(p_org uuid)
returns table (bank_id uuid, taxed_lines bigint, untaxed_lines bigint)
language sql
stable
set search_path to ''
as $$
  select r.org_bank_id, count(*) filter (where c.tax_pct > 0), count(*) filter (where c.tax_pct = 0)
  from public.product_tables t
  join public.organization_product_routes r on r.id = t.route_id and r.organization_id = t.organization_id
  join lateral (select v.id from public.product_table_versions v
                where v.product_table_id = t.id and v.status = 'published' order by v.version desc limit 1) cur on true
  join public.commercial_conditions c on c.product_table_version_id = cur.id
  where t.organization_id = p_org and t.status = 'active'
  group by r.org_bank_id
$$;
revoke all on function public.bank_tax_situation(uuid) from public, anon;
grant execute on function public.bank_tax_situation(uuid) to authenticated;

-- Tax of one draft line (empty = 0).
create or replace function public.set_condition_tax(p_condition uuid, p_tax_pct text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  c public.commercial_conditions%rowtype;
  v numeric;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into c from public.commercial_conditions where id = p_condition;
  if c.id is null or not public.has_active_organization_role(c.organization_id, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  if not exists (select 1 from public.product_table_versions v where v.id = c.product_table_version_id and v.status = 'draft') then raise exception 'version_not_draft'; end if;
  if coalesce(p_tax_pct, '') = '' then v := 0;
  elsif p_tax_pct !~ '^[0-9]{1,3}(\.[0-9]{1,6})?$' then raise exception 'invalid_tax_pct';
  else v := p_tax_pct::numeric; end if;
  if v > 100 then raise exception 'invalid_tax_pct'; end if;
  perform set_config('corban.condition_rpc', 'on', true);
  update public.commercial_conditions set tax_pct = trim_scale(v), updated_at = now() where id = c.id;
  perform set_config('corban.condition_rpc', 'off', true);
end
$$;
revoke all on function public.set_condition_tax(uuid, text) from public, anon;
grant execute on function public.set_condition_tax(uuid, text) to authenticated;

-- The line form saves company values, group values and tax together, in one transaction.
drop function public.save_condition_values(uuid, jsonb, jsonb);
create or replace function public.save_condition_values(p_condition uuid, p_components jsonb, p_group_values jsonb, p_tax_pct text)
returns void
language plpgsql
set search_path to ''
as $$
begin
  perform public.replace_commercial_condition_components(p_condition, p_components);
  perform public.replace_condition_group_values(p_condition, p_group_values);
  perform public.set_condition_tax(p_condition, p_tax_pct);
end
$$;
revoke all on function public.save_condition_values(uuid, jsonb, jsonb, text) from public, anon;
grant execute on function public.save_condition_values(uuid, jsonb, jsonb, text) to authenticated;

-- A new vigência copies the tax of each line too.
create or replace function public.clone_table_version(p_version uuid)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  src public.product_table_versions%rowtype;
  v_draft uuid;
  v_next integer;
  c record;
  v_new_condition uuid;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into src from public.product_table_versions where id = p_version;
  if src.id is null or not public.has_active_organization_role(src.organization_id, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  select id into v_draft from public.product_table_versions where product_table_id = src.product_table_id and status = 'draft' order by version desc limit 1;
  if v_draft is not null then return v_draft; end if;

  select coalesce(max(version), 0) + 1 into v_next from public.product_table_versions where product_table_id = src.product_table_id;
  insert into public.product_table_versions (organization_id, product_table_id, version, status, term_min, term_max, rate, coefficient, metadata)
  values (src.organization_id, src.product_table_id, v_next, 'draft', src.term_min, src.term_max, src.rate, src.coefficient,
          coalesce(src.metadata, '{}'::jsonb) || jsonb_build_object('cloned_from', src.id))
  returning id into v_draft;

  perform set_config('corban.condition_rpc', 'on', true);
  perform set_config('corban.component_condition_rpc', 'on', true);
  perform set_config('corban.group_values_rpc', 'on', true);
  for c in select * from public.commercial_conditions where product_table_version_id = src.id order by term_min, id loop
    insert into public.commercial_conditions (organization_id, product_table_version_id, contract_type_id, term, term_min, term_max, amount_min, amount_max, coefficient, rate, tax_pct, created_by)
    values (c.organization_id, v_draft, c.contract_type_id, c.term, c.term_min, c.term_max, c.amount_min, c.amount_max, c.coefficient, c.rate, c.tax_pct, auth.uid())
    returning id into v_new_condition;
    insert into public.commercial_condition_components (organization_id, condition_id, component_type_id, value_kind, received_value, calculation_base, source, created_by)
    select organization_id, v_new_condition, component_type_id, value_kind, received_value, calculation_base, source, auth.uid()
    from public.commercial_condition_components where condition_id = c.id;
    insert into public.commercial_condition_group_values (organization_id, condition_id, group_id, component_type_id, value_kind, value, source, created_by)
    select organization_id, v_new_condition, group_id, component_type_id, value_kind, value, source, auth.uid()
    from public.commercial_condition_group_values where condition_id = c.id;
    insert into public.commercial_condition_commissions (organization_id, condition_id, received_commission_pct, net_base_pct, policy_version_id)
    select organization_id, v_new_condition, received_commission_pct, net_base_pct, policy_version_id
    from public.commercial_condition_commissions where condition_id = c.id;
    insert into public.commercial_condition_shares (organization_id, condition_id, group_id, share_pct, effective_pct, source, policy_version_id)
    select organization_id, v_new_condition, group_id, share_pct, effective_pct, source, policy_version_id
    from public.commercial_condition_shares where condition_id = c.id;
  end loop;
  perform set_config('corban.group_values_rpc', 'off', true);
  perform set_config('corban.component_condition_rpc', 'off', true);
  perform set_config('corban.condition_rpc', 'off', true);
  return v_draft;
end
$$;

-- The calculation header records the group, its rule version and the bank IR used; lines gain the IR withheld and the
-- company margin may be negative (tax on top of a generous payout).
alter table public.proposal_commission_calcs drop constraint proposal_commission_calcs_mode_check;
alter table public.proposal_commission_calcs add constraint proposal_commission_calcs_mode_check check (mode in ('cascade', 'group_table', 'group_values'));
alter table public.proposal_commission_calcs
  add column group_id uuid,
  add column group_rule_id uuid references public.commission_group_rules(id) on delete restrict,
  add column ir_withheld_pct numeric(9,6) check (ir_withheld_pct between 0 and 100),
  add foreign key (organization_id, group_id) references public.commission_groups(organization_id, id) on delete restrict;
create index proposal_commission_calcs_group_idx on public.proposal_commission_calcs (organization_id, group_id);
create index proposal_commission_calcs_group_rule_idx on public.proposal_commission_calcs (group_rule_id);
alter table public.proposal_commission_lines drop constraint proposal_commission_lines_line_kind_check;
alter table public.proposal_commission_lines add constraint proposal_commission_lines_line_kind_check
  check (line_kind in ('received', 'tax', 'ir_withheld', 'manager', 'supervisor', 'originator', 'company'));
alter table public.proposal_commission_lines drop constraint proposal_commission_lines_amount_check;
alter table public.proposal_commission_lines add constraint proposal_commission_lines_amount_check check (amount >= 0 or line_kind = 'company');

create or replace function public.calculate_contract_commission(p_proposal_id uuid, p_condition_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  p public.proposals_v2%rowtype;
  v_org uuid;
  v_cond public.commercial_conditions%rowtype;
  v_count integer;
  v_bank uuid;
  v_ir numeric;
  v_seller public.commercial_sellers%rowtype;
  v_rule public.commission_group_rules%rowtype;
  it public.commission_group_rule_items%rowtype;
  v_orig uuid; v_sup uuid; v_mgr uuid;
  v_gross numeric; v_net numeric;
  v_pay_deferred boolean;
  v_calc uuid;
  c record;
  v_base numeric; v_received numeric; v_ref numeric;
  v_o numeric; v_s numeric; v_m numeric; v_t numeric; v_i numeric;
begin
  select * into p from public.proposals_v2 where id = p_proposal_id for update;
  v_org := p.organization_id;
  if v_org is null or auth.uid() is null or not public.is_active_organization_member(v_org) then raise exception 'not_authorized'; end if;
  if not private.can_see_proposal_row(v_org, p.seller_id, p.created_by) then raise exception 'not_authorized'; end if;
  if not (public.has_permission(v_org, 'propostas.edit') or public.has_permission(v_org, 'financeiro.edit')) then raise exception 'not_authorized'; end if;
  if p.status in ('paid', 'rejected', 'cancelled') and exists (select 1 from public.proposal_commission_calcs x where x.proposal_id = p.id and x.status = 'active') then
    raise exception 'commission_frozen';
  end if;
  if exists (select 1 from public.payout_entries e where e.proposal_id = p.id and e.kind = 'commission') then raise exception 'commission_already_posted'; end if;

  -- Line of the table: explicit, or the only one of the contract's table version matching the term and amount.
  if p_condition_id is not null then
    select * into v_cond from public.commercial_conditions k where k.organization_id = v_org and k.id = p_condition_id and k.product_table_version_id = p.product_table_version_id;
    if v_cond.id is null then raise exception 'condition_not_found'; end if;
  else
    select count(*) into v_count from public.commercial_conditions k
    where k.organization_id = v_org and k.product_table_version_id = p.product_table_version_id
      and (p.term is null or (p.term between coalesce(k.term_min, k.term) and coalesce(k.term_max, k.term)))
      and (k.amount_min is null or coalesce(p.requested_amount, p.released_amount) >= k.amount_min)
      and (k.amount_max is null or coalesce(p.requested_amount, p.released_amount) <= k.amount_max);
    if v_count = 0 then raise exception 'condition_not_found'; end if;
    if v_count > 1 then raise exception 'condition_ambiguous'; end if;
    select * into v_cond from public.commercial_conditions k
    where k.organization_id = v_org and k.product_table_version_id = p.product_table_version_id
      and (p.term is null or (p.term between coalesce(k.term_min, k.term) and coalesce(k.term_max, k.term)))
      and (k.amount_min is null or coalesce(p.requested_amount, p.released_amount) >= k.amount_min)
      and (k.amount_max is null or coalesce(p.requested_amount, p.released_amount) <= k.amount_max);
  end if;

  select coalesce(b.ir_withheld_pct, 0) into v_ir
  from public.product_table_versions v
  join public.product_tables t on t.id = v.product_table_id
  join public.organization_product_routes r on r.id = t.route_id
  join public.organization_banks b on b.id = r.org_bank_id
  where v.id = p.product_table_version_id;
  v_ir := coalesce(v_ir, 0);

  -- Seller: the contract's, or the seller linked to whoever registered it. Their group decides the payout.
  if p.seller_id is not null then
    select * into v_seller from public.commercial_sellers s where s.organization_id = v_org and s.id = p.seller_id;
  else
    select * into v_seller from public.commercial_sellers s where s.organization_id = v_org and s.user_id = p.created_by and s.is_active order by s.created_at limit 1;
  end if;
  if v_seller.id is null then raise exception 'proposal_without_seller'; end if;
  if v_seller.commission_group_id is null then raise exception 'seller_without_group'; end if;
  select * into v_rule from public.commission_group_rules r where r.organization_id = v_org and r.group_id = v_seller.commission_group_id order by r.version desc limit 1;
  if v_rule.id is null then raise exception 'group_rule_missing'; end if;

  -- Supervisor = team leader of the seller's login; manager = the supervisor's leader. A seller without login has no
  -- hierarchy: those shares stay with the company.
  v_orig := v_seller.user_id;
  if v_orig is not null then
    select m.team_leader_user_id into v_sup from public.organization_memberships m where m.organization_id = v_org and m.user_id = v_orig and m.status = 'active';
    if v_sup is not null then
      select m.team_leader_user_id into v_mgr from public.organization_memberships m where m.organization_id = v_org and m.user_id = v_sup and m.status = 'active';
    end if;
  end if;

  v_gross := coalesce(p.requested_amount, p.released_amount, 0);
  v_net := coalesce(p.released_amount, p.requested_amount, 0);
  v_pay_deferred := not v_rule.own_production and exists (
    select 1 from public.commission_group_rule_items i join public.commission_component_types t on t.id = i.component_type_id
    where i.rule_id = v_rule.id and t.tech_key = 'deferred' and i.distributed_pct > 0);

  perform set_config('corban.commission_rpc', 'on', true);
  update public.proposal_commission_calcs set status = 'superseded' where proposal_id = p.id and status = 'active';
  insert into public.proposal_commission_calcs (organization_id, proposal_id, condition_id, mode, tax_rate_pct, tax_exempt, manager_pct, supervisor_pct,
    pay_deferred, gross_amount, net_amount, installments, originator_user_id, supervisor_user_id, manager_user_id, seller_id, rule_ids, calculated_by,
    group_id, group_rule_id, ir_withheld_pct)
  values (v_org, p.id, v_cond.id, 'group_values', v_cond.tax_pct, v_cond.tax_pct = 0, v_rule.manager_pct, v_rule.supervisor_pct,
    v_pay_deferred, v_gross, v_net, p.term, v_orig, v_sup, v_mgr, v_seller.id, array[v_rule.id], auth.uid(),
    v_seller.commission_group_id, v_rule.id, v_ir)
  returning id into v_calc;

  for c in
    select t.id as type_id, t.tech_key, k.value_kind, k.received_value, k.calculation_base
    from public.commercial_condition_components k join public.commission_component_types t on t.id = k.component_type_id
    where k.condition_id = v_cond.id order by t.sort_order
  loop
    -- A % without its base (gross or net) is never guessed.
    if c.value_kind = 'percentage' and nullif(btrim(coalesce(c.calculation_base, '')), '') is null then raise exception 'calculation_base_missing'; end if;
    v_base := case when upper(c.calculation_base) like 'L%' then v_net else v_gross end;
    v_received := case when c.value_kind = 'fixed_brl' then round(c.received_value, 2) else round(v_base * c.received_value / 100, 2) end;

    v_o := 0;
    if not v_rule.own_production then
      select * into it from public.commission_group_rule_items i where i.rule_id = v_rule.id and i.component_type_id = c.type_id;
      if it.rule_id is not null and it.distributed_pct > 0 then
        if it.reference_kind = 'company' then
          v_ref := v_received;
        else
          select case when g.value_kind = 'fixed_brl' then round(g.value, 2) else round(v_base * g.value / 100, 2) end into v_ref
          from public.commercial_condition_group_values g
          where g.condition_id = v_cond.id and g.component_type_id = c.type_id
            and g.group_id = case when it.reference_kind = 'own' then v_seller.commission_group_id else it.reference_group_id end;
        end if;
        v_o := round(coalesce(v_ref, 0) * it.distributed_pct / 100, 2);
      end if;
    end if;

    v_s := 0; v_m := 0;
    if v_sup is not null then
      v_s := round(case v_rule.supervisor_basis when 'spread' then greatest(v_received - v_o, 0) when 'payout' then v_o
                    else case when c.tech_key = 'upfront' then v_gross else 0 end end * v_rule.supervisor_pct / 100, 2);
    end if;
    if v_mgr is not null then
      v_m := round(case v_rule.manager_basis when 'spread' then greatest(v_received - v_o, 0) when 'payout' then v_o
                    else case when c.tech_key = 'upfront' then v_gross else 0 end end * v_rule.manager_pct / 100, 2);
    end if;
    if v_o + v_s + v_m > v_received then raise exception 'payout_exceeds_received'; end if;
    if v_received = 0 then continue; end if;

    v_t := round(v_received * v_cond.tax_pct / 100, 2);
    v_i := round(v_received * v_ir / 100, 2);

    if c.tech_key = 'deferred' and coalesce(p.term, 0) > 0 then
      insert into public.proposal_commission_lines (organization_id, calc_id, component_key, part, multiplier, line_kind, amount)
      select v_org, v_calc, c.tech_key, x.part, x.mult, x.kind, x.amt
      from (
        with s as (
          select kk.kind, d.standard, d.last
          from (values ('received', v_received), ('tax', v_t), ('ir_withheld', v_i), ('manager', v_m), ('supervisor', v_s), ('originator', v_o)) kk(kind, total)
          cross join lateral private.deferred_schedule(kk.total, p.term) d
        )
        select 'deferred_standard' as part, p.term - 1 as mult, s.kind, s.standard as amt from s
        union all select 'deferred_last', 1, s.kind, s.last from s
        union all select 'deferred_standard', p.term - 1, 'company', sum(case when s.kind = 'received' then s.standard else -s.standard end) from s
        union all select 'deferred_last', 1, 'company', sum(case when s.kind = 'received' then s.last else -s.last end) from s
      ) x;
    else
      insert into public.proposal_commission_lines (organization_id, calc_id, component_key, part, multiplier, line_kind, amount)
      select v_org, v_calc, c.tech_key, 'upfront', 1, x.kind, x.amt
      from (values ('received', v_received), ('tax', v_t), ('ir_withheld', v_i), ('manager', v_m), ('supervisor', v_s), ('originator', v_o),
                   ('company', v_received - v_t - v_i - v_m - v_s - v_o)) x(kind, amt);
    end if;
  end loop;
  perform set_config('corban.commission_rpc', 'off', true);
  return v_calc;
end
$$;
revoke all on function public.calculate_contract_commission(uuid, uuid) from public, anon;
grant execute on function public.calculate_contract_commission(uuid, uuid) to authenticated;

-- A bank receipt no longer credits the seller for a contract calculated by the new engine: the owner pays the seller
-- once the contract is paid and its physical file arrived (part C3), not when the bank pays the company. The receipt is
-- still recorded and reconciled; contracts calculated by the old engine keep the old behaviour until the cleanup.
create or replace function private.post_receipt(p_receipt uuid)
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  x public.commission_receipts%rowtype;
  c public.proposal_commission_calcs%rowtype;
  d record;
  v_base numeric;
  v_ratio numeric;
  r record;
  v_debit numeric;
begin
  select * into x from public.commission_receipts where id = p_receipt;
  if x.id is null or exists (select 1 from public.payout_entries where receipt_id = x.id) then return; end if;
  perform set_config('corban.payout_rpc', 'on', true);

  if x.entry_kind = 'receipt' then
    select * into c from public.proposal_commission_calcs where id = x.calc_id;
    if c.id is null or (x.component_key = 'deferred' and not c.pay_deferred) then return; end if;
    if c.mode = 'group_values' then return; end if;
    select * into d from private.distribute_commission_amount(x.amount, c.mode, c.tax_rate_pct, c.tax_exempt, c.profit_pct, c.manager_pct, c.supervisor_pct, c.originator_pct,
      c.group_share_pct, c.manager_user_id is not null, c.supervisor_user_id is not null, c.seller_id is not null or c.originator_user_id is not null);
    -- The originator is the proposal's seller when there is one (a seller without login included).
    insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, proposal_id, receipt_id, beneficiary_role, description, status, created_by)
    select x.organization_id, v.account, 'commission', v.amount, current_date, x.proposal_id, x.id, v.role,
           case when x.component_key = 'deferred' then 'Comissão diferido parcela ' || x.installment_number else 'Comissão à vista' end, 'approved', auth.uid()
    from (values ('originator', private.payout_account_for(x.organization_id, c.seller_id, c.originator_user_id), d.originator),
                 ('supervisor', private.payout_account_for(x.organization_id, null, c.supervisor_user_id), d.supervisor),
                 ('manager', private.payout_account_for(x.organization_id, null, c.manager_user_id), d.manager)) v(role, account, amount)
    where v.account is not null and v.amount > 0;
  else
    -- Base: what the contract received, less the chargebacks already posted.
    select coalesce(sum(amount), 0) into v_base from public.commission_receipts where proposal_id = x.proposal_id and entry_kind = 'receipt';
    v_base := v_base - coalesce((select sum(k.amount) from public.commission_receipts k
                                 where k.proposal_id = x.proposal_id and k.entry_kind = 'chargeback' and k.id <> x.id
                                   and exists (select 1 from public.payout_entries e where e.receipt_id = k.id)), 0);
    if v_base <= 0 then return; end if;
    v_ratio := least(1, x.amount / v_base);
    for r in
      select e.account_id, e.beneficiary_role, sum(e.amount) as net
      from public.payout_entries e
      where e.proposal_id = x.proposal_id and e.kind in ('commission','chargeback') and e.status = 'approved'
      group by e.account_id, e.beneficiary_role
      having sum(e.amount) > 0
    loop
      v_debit := least(r.net, round(r.net * v_ratio, 2));
      if v_debit > 0 then
        insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, proposal_id, receipt_id, beneficiary_role, description, status, created_by)
        values (x.organization_id, r.account_id, 'chargeback', -v_debit, current_date, x.proposal_id, x.id, r.beneficiary_role, 'Estorno do banco', 'approved', auth.uid());
      end if;
    end loop;
  end if;
end
$function$;

-- The smart import reads the "Imposto" column of each line (absent column = the line keeps its tax).
CREATE OR REPLACE FUNCTION public.import_smart_commercial_rows(p_organization uuid, p_production_origin text, p_provider uuid, p_policy_version uuid, p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  rowj jsonb;
  comp jsonb;
  v_bank public.organization_banks%rowtype;
  v_agreement public.organization_agreements%rowtype;
  v_route public.organization_product_routes%rowtype;
  v_table public.product_tables%rowtype;
  v_version public.product_table_versions%rowtype;
  v_condition public.commercial_conditions%rowtype;
  v_contract public.contract_types%rowtype;
  v_factor_profile public.commercial_factor_profiles%rowtype;
  v_factor_batch public.commercial_factor_batches%rowtype;
  v_bank_name text;
  v_agreement_name text;
  v_table_name text;
  v_external_code text;
  v_contract_name text;
  v_contract_id uuid;
  v_term_min integer;
  v_term_max integer;
  v_coefficient numeric;
  v_rate numeric;
  v_effective_from timestamptz;
  v_effective_until timestamptz;
  v_factor_mode text;
  v_factor_value numeric;
  v_factor_date date;
  v_component_type uuid;
  v_value_kind text;
  v_received numeric;
  v_tax numeric;
  v_created_banks integer:=0;
  v_created_agreements integer:=0;
  v_created_tables integer:=0;
  v_created_versions integer:=0;
  v_upserted_conditions integer:=0;
  v_component_count integer:=0;
  v_factor_count integer:=0;
  v_token text:='smart-import:'||replace(gen_random_uuid()::text,'-','');
  v_batch_ids uuid[]:='{}';
begin
  if auth.uid() is null or p_organization is null or not public.has_active_organization_role(p_organization,array['admin','manager']) then
    raise exception 'not_authorized';
  end if;
  if p_production_origin not in ('own','third_party') then raise exception 'invalid_production_origin'; end if;
  if p_production_origin='own' and p_provider is not null then raise exception 'invalid_production_origin'; end if;
  if p_production_origin='third_party' then
    if p_provider is null or not exists(select 1 from public.organization_providers x where x.organization_id=p_organization and x.id=p_provider and x.is_active)
    then raise exception 'invalid_provider'; end if;
  end if;
  if p_policy_version is not null then raise exception 'component_policy_removed'; end if;
  if p_rows is null or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)<1 or jsonb_array_length(p_rows)>1000 then
    raise exception 'invalid_smart_import_rows';
  end if;

  for rowj in select * from jsonb_array_elements(p_rows) loop
    v_bank_name:=nullif(btrim(rowj->>'bank_name'),'');
    v_agreement_name:=nullif(btrim(rowj->>'agreement_name'),'');
    v_table_name:=nullif(btrim(rowj->>'table_name'),'');
    v_external_code:=nullif(btrim(rowj->>'external_table_code'),'');
    v_contract_name:=nullif(btrim(rowj->>'contract_type_name'),'');
    begin
      v_contract_id:=nullif(rowj->>'contract_type_id','')::uuid;
      v_term_min:=coalesce(nullif(rowj->>'term_min',''),nullif(rowj->>'term',''))::integer;
      v_term_max:=coalesce(nullif(rowj->>'term_max',''),nullif(rowj->>'term_min',''),nullif(rowj->>'term',''))::integer;
      v_coefficient:=case when nullif(rowj->>'coefficient','') is null then null else (rowj->>'coefficient')::numeric end;
      v_rate:=case when nullif(rowj->>'rate','') is null then null else (rowj->>'rate')::numeric end;
      v_effective_from:=case when nullif(rowj->>'effective_from','') is null then null else (rowj->>'effective_from')::timestamptz end;
      v_effective_until:=case when nullif(rowj->>'effective_until','') is null then null else (rowj->>'effective_until')::timestamptz end;
      v_factor_mode:=nullif(rowj->>'factor_mode','');
      v_factor_value:=case when nullif(rowj->>'factor_value','') is null then null else (rowj->>'factor_value')::numeric end;
      v_factor_date:=case when nullif(rowj->>'factor_date','') is null then coalesce(v_effective_from::date,current_date) else (rowj->>'factor_date')::date end;
      v_tax:=case when nullif(rowj->>'tax_pct','') is null then null else (rowj->>'tax_pct')::numeric end;
    exception when others then raise exception 'invalid_smart_import_row'; end;

    if v_bank_name is null or length(v_bank_name)>120
       or v_agreement_name is null or length(v_agreement_name)>120
       or v_table_name is null or length(v_table_name)>120
       or v_term_min not between 1 and 600
       or v_term_max not between 1 and 600
       or v_term_min>v_term_max
       or (v_coefficient is null and v_rate is null)
       or (v_coefficient is not null and v_coefficient<0)
       or (v_rate is not null and v_rate<0)
       or (v_effective_from is not null and v_effective_until is not null and v_effective_until<v_effective_from)
       or (v_tax is not null and (v_tax<0 or v_tax>100))
    then raise exception 'invalid_smart_import_row'; end if;

    -- Contract type can be supplied by id or exact name; tenant-enabled/visible constraints still apply.
    if v_contract_id is not null then
      select * into v_contract from public.contract_types x
      where x.id=v_contract_id and x.is_active and (x.organization_id is null or x.organization_id=p_organization);
    else
      select * into v_contract from public.contract_types x
      where lower(btrim(x.name))=lower(v_contract_name) and x.is_active and (x.organization_id is null or x.organization_id=p_organization)
      order by (x.organization_id=p_organization) desc nulls last limit 1;
    end if;
    if v_contract.id is null then raise exception 'contract_type_not_found'; end if;
    if exists(select 1 from public.organization_contract_type_settings s where s.organization_id=p_organization and s.contract_type_id=v_contract.id and (not s.is_enabled or not s.use_in_commission))
    then raise exception 'contract_type_disabled'; end if;

    -- Exact tenant catalog match first; create only when absent.
    select * into v_bank from public.organization_banks x where x.organization_id=p_organization and lower(btrim(x.name))=lower(v_bank_name) limit 1;
    if v_bank.id is null then
      insert into public.organization_banks(organization_id,name) values(p_organization,v_bank_name) returning * into v_bank;
      v_created_banks:=v_created_banks+1;
    elsif not v_bank.is_active then raise exception 'bank_inactive'; end if;

    select * into v_agreement from public.organization_agreements x where x.organization_id=p_organization and lower(btrim(x.name))=lower(v_agreement_name) limit 1;
    if v_agreement.id is null then
      insert into public.organization_agreements(organization_id,name) values(p_organization,v_agreement_name) returning * into v_agreement;
      v_created_agreements:=v_created_agreements+1;
    elsif not v_agreement.is_active then raise exception 'agreement_inactive'; end if;

    select * into v_route from public.organization_product_routes x
    where x.organization_id=p_organization and x.org_bank_id=v_bank.id and x.org_agreement_id=v_agreement.id
      and ((p_provider is null and x.org_provider_id is null) or x.org_provider_id=p_provider)
      and x.production_origin=p_production_origin
    limit 1;
    if v_route.id is null then
      insert into public.organization_product_routes(organization_id,org_bank_id,org_provider_id,org_agreement_id,production_origin,status)
      values(p_organization,v_bank.id,p_provider,v_agreement.id,p_production_origin,'active') returning * into v_route;
    end if;

    select * into v_table from public.product_tables x
    where x.organization_id=p_organization and x.route_id=v_route.id and lower(btrim(x.name))=lower(v_table_name)
    order by x.created_at desc limit 1;
    if v_table.id is null then
      insert into public.product_tables(organization_id,route_id,code,name,status)
      values(p_organization,v_route.id,'t-'||substr(replace(gen_random_uuid()::text,'-',''),1,12),v_table_name,'active')
      returning * into v_table;
      v_created_tables:=v_created_tables+1;
    elsif v_table.status<>'active' then raise exception 'product_table_inactive'; end if;

    select * into v_version from public.product_table_versions x
    where x.organization_id=p_organization and x.product_table_id=v_table.id and x.status='draft'
    order by x.version desc limit 1;
    if v_version.id is null then
      insert into public.product_table_versions(organization_id,product_table_id,version,status,effective_from,effective_until,metadata)
      select p_organization,v_table.id,coalesce(max(x.version),0)+1,'draft',v_effective_from,v_effective_until,
        jsonb_strip_nulls(jsonb_build_object('external_table_code',v_external_code,'smart_import',true))
      from public.product_table_versions x where x.product_table_id=v_table.id
      returning * into v_version;
      v_created_versions:=v_created_versions+1;
    else
      update public.product_table_versions
      set effective_from=coalesce(v_effective_from,effective_from),
          effective_until=coalesce(v_effective_until,effective_until),
          metadata=metadata||jsonb_strip_nulls(jsonb_build_object('external_table_code',v_external_code,'smart_import',true))
      where id=v_version.id returning * into v_version;
    end if;

    select * into v_condition from public.commercial_conditions x
    where x.organization_id=p_organization and x.product_table_version_id=v_version.id and x.contract_type_id=v_contract.id
      and x.term_min=v_term_min and x.term_max=v_term_max
    limit 1;

    perform set_config('corban.condition_rpc','on',true);
    if v_condition.id is null then
      insert into public.commercial_conditions(organization_id,product_table_version_id,contract_type_id,term,term_min,term_max,coefficient,rate,tax_pct,created_by)
      values(p_organization,v_version.id,v_contract.id,v_term_min,v_term_min,v_term_max,v_coefficient,v_rate,trim_scale(coalesce(v_tax,0)),auth.uid())
      returning * into v_condition;
    else
      update public.commercial_conditions
      set term=v_term_min,term_min=v_term_min,term_max=v_term_max,coefficient=v_coefficient,rate=v_rate,
          tax_pct=case when rowj ? 'tax_pct' then trim_scale(coalesce(v_tax,0)) else tax_pct end,updated_at=now()
      where id=v_condition.id returning * into v_condition;
    end if;
    perform set_config('corban.condition_rpc','off',true);
    v_upserted_conditions:=v_upserted_conditions+1;

    -- Replace all received components for the condition only after the row has been fully validated.
    perform public.replace_commercial_condition_components(
      v_condition.id,
      coalesce(rowj->'components','[]'::jsonb)
    );
    v_component_count:=v_component_count+jsonb_array_length(coalesce(rowj->'components','[]'::jsonb));
    -- Part B (ADR-0036): the value of each seller group for each commission type, when the file brings group columns.
    if rowj ? 'group_values' then
      perform public.replace_condition_group_values(v_condition.id, rowj->'group_values');
    end if;


    -- Factor is its own versioned domain. When present, import a revision for the same commercial scope.
    if v_factor_value is not null then
      if v_factor_value<=0 or v_factor_mode not in ('daily','fixed') then raise exception 'invalid_factor'; end if;
      select * into v_factor_profile from public.commercial_factor_profiles x
      where x.organization_id=p_organization and x.org_bank_id=v_bank.id and x.org_agreement_id=v_agreement.id
        and x.product_table_id=v_table.id and x.contract_type_id=v_contract.id and x.factor_mode=v_factor_mode
      limit 1;
      if v_factor_profile.id is null then
        insert into public.commercial_factor_profiles(
          organization_id,name,org_bank_id,org_agreement_id,product_table_id,contract_type_id,factor_mode,created_by
        ) values(
          p_organization,left(v_bank.name||' · '||v_agreement.name||' · '||v_table.name||' · '||v_contract.name,120),
          v_bank.id,v_agreement.id,v_table.id,v_contract.id,v_factor_mode,auth.uid()
        ) returning * into v_factor_profile;
      end if;

      select * into v_factor_batch from public.commercial_factor_batches x
      where x.organization_id=p_organization and x.profile_id=v_factor_profile.id and x.effective_date=v_factor_date
        and x.status='draft' and x.source_note=v_token
      limit 1;
      if v_factor_batch.id is null then
        insert into public.commercial_factor_batches(organization_id,profile_id,effective_date,revision,status,source_kind,source_note,created_by)
        select p_organization,v_factor_profile.id,v_factor_date,coalesce(max(x.revision),0)+1,'draft','file',v_token,auth.uid()
        from public.commercial_factor_batches x where x.profile_id=v_factor_profile.id and x.effective_date=v_factor_date
        returning * into v_factor_batch;
        v_batch_ids:=v_batch_ids||v_factor_batch.id;
      end if;

      insert into public.commercial_factor_entries(organization_id,batch_id,term_min,term_max,factor_value,metadata)
      values(p_organization,v_factor_batch.id,v_term_min,v_term_max,v_factor_value,jsonb_build_object('smart_import',true))
      on conflict(batch_id,term_min,term_max) do update set factor_value=excluded.factor_value,metadata=excluded.metadata;
      v_factor_count:=v_factor_count+1;
    end if;
  end loop;

  if array_length(v_batch_ids,1) is not null then
    foreach v_contract_id in array v_batch_ids loop
      perform public.publish_commercial_factor_batch(v_contract_id);
    end loop;
  end if;

  return jsonb_build_object(
    'created_banks',v_created_banks,
    'created_agreements',v_created_agreements,
    'created_tables',v_created_tables,
    'created_versions',v_created_versions,
    'upserted_conditions',v_upserted_conditions,
    'components',v_component_count,
    'factors',v_factor_count
  );
exception when others then
  perform set_config('corban.condition_rpc','off',true);
  perform set_config('corban.smart_import_rpc','off',true);
  raise;
end $function$;
