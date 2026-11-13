-- Bônus received apart from the à vista commission (owner request 13/11/2026, Banco Valor): the bank pays at most 6% in
-- the à vista report ("Rel_comissionamento") and the rest in a separate bonus report ("Rel_comissionamento_bonus"). Until
-- now the à vista receipt expected every non-deferred component, Bônus included, so every Valor à vista report was
-- divergent and the bonus report had no place.
--
-- * Receipts get a fourth component, "bonus": the à vista receipt expects the non-deferred components without the
--   Gratificação and without Bônus 1/2/3; the bonus report (kind "bonus") is compared with the sum of Bônus 1/2/3 of the
--   calculation in force. Same pattern as the Gratificação (20261103155956).
-- * Seller credit (owner, 13/11/2026: option A, "só quando o bônus for recebido"): the contract credit leaves Bônus 1/2/3
--   out; post_receipt credits the seller's, supervisor's and manager's share of the Bônus once its receipt is reconciled
--   and the contract credit is released (sync_contract_credit posts the ones reconciled before the release).
-- * Contracts already credited with the Bônus inside the contract credit (private.bonus_credit_legacy, filled here) keep
--   the old way, so nothing already credited is undone or credited twice.
-- * A Bônus receipt releases the contract credit only when the contract receives nothing else (like the Gratificação).
-- * "A receber dos bancos" expects the à vista without the Bônus; the file check says when a Bônus was already received;
--   a Bônus can be registered by hand on the contract.
-- * Both reports imported together as one à vista (the screen sums the files per contract, as Smart did on 28/10): the
--   à vista with the Bônus is also accepted; the Bônus then counts as received (its share stays in the contract credit and
--   a later Bônus receipt is a duplicate).
-- * Draft à vista reports are matched again. Confirmed receipts are not touched (financial history is immutable).
-- Function bodies start from the versions in production (md5 checked 13/11/2026) and change only what is said above.

alter table public.receipt_reports drop constraint receipt_reports_report_kind_check;
alter table public.receipt_reports add constraint receipt_reports_report_kind_check
  check (report_kind = any (array['upfront', 'deferred', 'chargeback', 'gratification', 'bonus']));
alter table public.receipt_lines drop constraint receipt_lines_component_key_check;
alter table public.receipt_lines add constraint receipt_lines_component_key_check
  check (component_key = any (array['upfront', 'deferred', 'gratification', 'bonus']));
alter table public.commission_receipts drop constraint commission_receipts_component_key_check;
alter table public.commission_receipts add constraint commission_receipts_component_key_check
  check (component_key = any (array['upfront', 'deferred', 'gratification', 'bonus']));
alter table public.receipt_layouts drop constraint receipt_layouts_report_kind_check;
alter table public.receipt_layouts add constraint receipt_layouts_report_kind_check
  check (report_kind = any (array['upfront', 'deferred', 'chargeback', 'bonus']));

create table private.bonus_credit_legacy (
  proposal_id uuid primary key references public.proposals_v2(id) on delete restrict,
  created_at timestamptz not null default now()
);
alter table private.bonus_credit_legacy enable row level security;
revoke all on table private.bonus_credit_legacy from public, anon, authenticated;

insert into private.bonus_credit_legacy (proposal_id)
select distinct c.proposal_id
from public.proposal_commission_calcs c
join public.proposal_commission_lines l on l.calc_id = c.id and l.component_key in ('bonus_1', 'bonus_2', 'bonus_3') and l.line_kind = 'received' and l.amount <> 0
where c.status = 'active'
  and exists (select 1 from public.payout_entries e where e.proposal_id = c.proposal_id and e.source = 'contract');

-- The à vista receipt of the contract already brought the Bônus: both reports were imported together as one à vista and
-- the line matched the à vista with the Bônus (match_receipt_line stores that amount as expected).
create or replace function private.contract_bonus_in_upfront(p_proposal uuid)
returns boolean
language sql
stable security definer
set search_path to ''
as $function$
  with c as (select id from public.proposal_commission_calcs where proposal_id = p_proposal and status = 'active'),
  t as (
    select coalesce(sum(l.amount) filter (where l.component_key in ('bonus_1', 'bonus_2', 'bonus_3')), 0) as bonus,
           coalesce(sum(l.amount) filter (where l.component_key <> 'gratification'), 0) as full_amount
    from public.proposal_commission_lines l join c on c.id = l.calc_id
    where l.part = 'upfront' and l.line_kind = 'received')
  select coalesce((select t.bonus > 0 from t), false)
     and exists (select 1 from public.commission_receipts r, t
                 where r.proposal_id = p_proposal and r.entry_kind = 'receipt' and r.component_key = 'upfront'
                   and r.expected_amount = t.full_amount)
$function$;
revoke all on function private.contract_bonus_in_upfront(uuid) from public, anon, authenticated;

create or replace function private.match_receipt_line(p_line_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  l public.receipt_lines%rowtype;
  rep public.receipt_reports%rowtype;
  v_proposal uuid;
  v_count int;
  v_calc public.proposal_commission_calcs%rowtype;
  v_component text;
  v_inst int;
  v_expected numeric;
  v_full numeric;
  v_status text;
begin
  select * into l from public.receipt_lines where id = p_line_id for update;
  select * into rep from public.receipt_reports where id = l.report_id;
  if l.status = 'ignored' then return; end if;

  -- Proposal: kept when linked by hand, else by ADE within the routes of the paying source.
  if l.matched_by = 'manual' and l.proposal_id is not null then
    v_proposal := l.proposal_id; v_count := 1;
  else
    select count(*), min(p.id::text)::uuid into v_count, v_proposal
    from public.proposals_v2 p
    join public.product_table_versions v on v.id = p.product_table_version_id
    join public.product_tables t on t.id = v.product_table_id
    join public.organization_product_routes r on r.id = t.route_id
    where p.organization_id = l.organization_id
      and (case rep.source_kind when 'bank' then r.org_bank_id = rep.source_id else r.org_provider_id = rep.source_id end)
      and (private.norm_ade(p.external_proposal_id) = private.norm_ade(l.ade)
           or exists (select 1 from public.proposal_external_identities e
                      where e.organization_id = p.organization_id and e.proposal_id = p.id and private.norm_ade(e.external_proposal_number) = private.norm_ade(l.ade)));
  end if;

  if v_count = 0 then
    v_status := 'not_found'; v_proposal := null;
  elsif v_count > 1 then
    v_status := 'ambiguous'; v_proposal := null;
  else
    select * into v_calc from public.proposal_commission_calcs c where c.proposal_id = v_proposal and c.status = 'active';
    if rep.report_kind = 'chargeback' then
      v_component := null;
      select coalesce(sum(case when x.entry_kind = 'receipt' then x.amount else -x.amount end), 0) into v_expected
      from public.commission_receipts x where x.proposal_id = v_proposal;
      -- Chargebacks already on earlier lines of this draft also consume what was received.
      v_expected := v_expected - coalesce((select sum(o.amount) from public.receipt_lines o
                                           where o.report_id = l.report_id and o.row_number < l.row_number and o.proposal_id = v_proposal and o.status in ('ok','divergent')), 0);
      v_status := case when l.amount <= v_expected then 'ok' else 'divergent' end;
    elsif v_calc.id is null then
      v_status := 'no_calc';
    elsif rep.report_kind = 'upfront' then
      -- The Gratificação (03/11/2026) and the Bônus (13/11/2026) are paid apart: the à vista receipt expects the other
      -- non-deferred components.
      v_component := 'upfront';
      select sum(x.amount) into v_expected from public.proposal_commission_lines x
      where x.calc_id = v_calc.id and x.part = 'upfront' and x.line_kind = 'received'
        and x.component_key <> 'gratification' and x.component_key not in ('bonus_1', 'bonus_2', 'bonus_3');
      -- Both reports imported together as one à vista (the screen sums the files per contract): the à vista with the
      -- Bônus is also accepted, and then the Bônus counts as received with it.
      select sum(x.amount) into v_full from public.proposal_commission_lines x
      where x.calc_id = v_calc.id and x.part = 'upfront' and x.line_kind = 'received' and x.component_key <> 'gratification';
      if v_expected is null then v_status := 'no_calc'; end if;
    elsif rep.report_kind = 'bonus' then
      v_component := 'bonus';
      select sum(x.amount * x.multiplier) into v_expected from public.proposal_commission_lines x
      where x.calc_id = v_calc.id and x.line_kind = 'received' and x.component_key in ('bonus_1', 'bonus_2', 'bonus_3');
      if coalesce(v_expected, 0) = 0 then v_status := 'no_calc'; end if;
    elsif rep.report_kind = 'gratification' then
      v_component := 'gratification';
      select sum(x.amount * x.multiplier) into v_expected from public.proposal_commission_lines x
      where x.calc_id = v_calc.id and x.line_kind = 'received' and x.component_key = 'gratification';
      if coalesce(v_expected, 0) = 0 then v_status := 'no_calc'; end if;
    else
      v_component := 'deferred';
      if not exists (select 1 from public.proposal_commission_lines x where x.calc_id = v_calc.id and x.part like 'deferred%') or coalesce(v_calc.installments, 0) < 1 then
        v_status := 'no_calc';
      else
        -- Installment given by the report, or the next one not yet received (ledger or earlier lines of this draft).
        v_inst := coalesce(l.installment_number, (
          select min(n) from generate_series(1, v_calc.installments) n
          where not exists (select 1 from public.commission_receipts x where x.proposal_id = v_proposal and x.entry_kind = 'receipt' and x.component_key = 'deferred' and x.installment_number = n)
            and not exists (select 1 from public.receipt_lines o where o.report_id = l.report_id and o.row_number < l.row_number and o.proposal_id = v_proposal
                            and o.component_key = 'deferred' and o.assigned_installment = n and o.status in ('ok','divergent'))));
        if v_inst is null or v_inst < 1 or v_inst > v_calc.installments then
          v_status := 'installment_invalid';
        else
          select x.amount into v_expected from public.proposal_commission_lines x
          where x.calc_id = v_calc.id and x.line_kind = 'received'
            and x.part = case when v_inst = v_calc.installments then 'deferred_last' else 'deferred_standard' end;
        end if;
      end if;
    end if;

    if v_status is null then
      if exists (select 1 from public.commission_receipts x where x.proposal_id = v_proposal and x.entry_kind = 'receipt'
                 and x.component_key = v_component and coalesce(x.installment_number, 0) = coalesce(v_inst, 0))
         or exists (select 1 from public.receipt_lines o where o.report_id = l.report_id and o.row_number < l.row_number and o.proposal_id = v_proposal
                    and o.component_key = v_component and coalesce(o.assigned_installment, 0) = coalesce(v_inst, 0) and o.status in ('ok','divergent')) then
        v_status := 'duplicate';
      else
        if v_component = 'bonus' and private.contract_bonus_in_upfront(v_proposal) then
          v_status := 'duplicate';
        elsif v_component = 'upfront' and l.amount <> v_expected and v_full > v_expected and l.amount = v_full then
          v_status := 'ok'; v_expected := v_full;
        else
          v_status := case when l.amount = v_expected then 'ok' else 'divergent' end;
        end if;
      end if;
    end if;
  end if;

  update public.receipt_lines
  set proposal_id = v_proposal,
      matched_by = case when v_proposal is null then null when l.matched_by = 'manual' then 'manual' else 'auto' end,
      component_key = v_component, assigned_installment = v_inst, calc_id = v_calc.id,
      expected_amount = v_expected, status = v_status
  where id = l.id;
end
$function$;

create or replace function private.contract_bank_receipt(p_proposal uuid)
returns text
language sql
stable security definer
set search_path to ''
as $function$
  with payable as (select * from private.contract_payable(p_proposal)),
  relevant as (
    select r.reconciliation = 'matched' or exists (select 1 from public.commission_receipt_resolutions z where z.receipt_id = r.id) as reconciled
    from public.commission_receipts r
    where r.proposal_id = p_proposal and r.entry_kind = 'receipt'
      and (r.component_key not in ('gratification', 'bonus')
           or not exists (select 1 from payable x where x.component_key <> 'gratification' and x.component_key not in ('bonus_1', 'bonus_2', 'bonus_3') and x.received > 0))
      and (r.component_key = 'upfront'
           or not exists (select 1 from payable x where x.component_key = 'upfront' and x.received > 0))
  )
  select case when bool_or(reconciled) then 'reconciled' when count(*) > 0 then 'divergent' end from relevant
$function$;

create or replace function private.sync_contract_credit(p_proposal uuid, p_force boolean default false)
returns void
language plpgsql
security definer
set search_path to ''
set "TimeZone" to 'America/Sao_Paulo'
as $function$
declare
  p public.proposals_v2%rowtype;
  c public.proposal_commission_calcs%rowtype;
  v_released boolean;
  v_paid boolean;
  v_legacy boolean;
  v_bonus_legacy boolean;
  v_skip text[];
  r record;
begin
  select * into p from public.proposals_v2 where id = p_proposal;
  if p.id is null then return; end if;
  select * into c from public.proposal_commission_calcs where proposal_id = p.id and status = 'active';
  -- Calculations of the old rule credit per receipt (post_receipt); only the table and group engine credits here.
  if c.id is not null and c.mode <> 'group_values' then return; end if;
  v_released := private.contract_credit_released(p.id);
  v_paid := private.contract_payout_received(p.id);
  -- The Gratificação is credited when it is received (post_receipt), except on contracts credited the old way.
  v_legacy := exists (select 1 from private.gratification_credit_legacy g where g.proposal_id = p.id);
  v_skip := case when v_legacy then array['deferred'] else array['deferred', 'gratification'] end;
  -- The Bônus (13/11/2026) too: credited when it is received, except on contracts already credited with it.
  v_bonus_legacy := exists (select 1 from private.bonus_credit_legacy g where g.proposal_id = p.id);
  -- An à vista receipt that already brought the Bônus (both reports imported together) keeps it in the contract credit.
  if not v_bonus_legacy and not private.contract_bonus_in_upfront(p.id) then v_skip := v_skip || array['bonus_1', 'bonus_2', 'bonus_3']; end if;
  perform set_config('corban.payout_rpc', 'on', true);
  for r in
    with target as (
      select 'originator'::text as role, private.payout_account_for(p.organization_id, c.seller_id, c.originator_user_id) as account,
             coalesce((select sum(x.payable) from private.contract_payable(p.id) x where x.component_key <> all (v_skip)), 0) as amount
      where (v_released or p_force) and c.id is not null and not v_paid
      union all
      select 'supervisor', private.payout_account_for(p.organization_id, null, c.supervisor_user_id),
             coalesce((select sum(l.amount * l.multiplier) from public.proposal_commission_lines l where l.calc_id = c.id and l.line_kind = 'supervisor' and l.component_key <> all (v_skip)), 0)
      where v_released and c.supervisor_user_id is not null
      union all
      select 'manager', private.payout_account_for(p.organization_id, null, c.manager_user_id),
             coalesce((select sum(l.amount * l.multiplier) from public.proposal_commission_lines l where l.calc_id = c.id and l.line_kind = 'manager' and l.component_key <> all (v_skip)), 0)
      where v_released and c.manager_user_id is not null
    ),
    existing as (
      select e.beneficiary_role as role, e.account_id as account, sum(e.amount) as amount
      from public.payout_entries e
      where e.proposal_id = p.id and e.source = 'contract' and e.status <> 'rejected'
        and not (v_paid and e.beneficiary_role = 'originator')
      group by 1, 2
    )
    select coalesce(t.role, x.role) as role, coalesce(t.account, x.account) as account,
           coalesce(t.amount, 0) - coalesce(x.amount, 0) as diff, coalesce(x.amount, 0) = 0 as first
    from target t full join existing x on x.role = t.role and x.account = t.account
  loop
    if r.account is not null and r.diff <> 0 then
      insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, proposal_id, beneficiary_role, description, status, created_by, source)
      values (p.organization_id, r.account, case when r.first and r.diff > 0 then 'commission' else 'adjustment' end, r.diff, current_date, p.id, r.role,
              left((case when r.first and r.diff > 0 then 'Comissão do contrato' else 'Ajuste da comissão do contrato' end)
                   || coalesce(' ' || p.external_proposal_id, '') || coalesce(' · ' || (p.customer_snapshot->>'full_name'), ''), 200),
              'approved', auth.uid(), 'contract');
    end if;
  end loop;
  perform set_config('corban.payout_rpc', 'off', true);
  -- Deferred installments and the Gratificação reconciled before the release are credited now (post_receipt skips
  -- what it already posted).
  if v_released then
    for r in select x.id from public.commission_receipts x
             where x.proposal_id = p.id and x.entry_kind = 'receipt'
               and (x.component_key = 'deferred' or (x.component_key = 'gratification' and not v_legacy) or (x.component_key = 'bonus' and not v_bonus_legacy))
               and (x.reconciliation = 'matched' or exists (select 1 from public.commission_receipt_resolutions z where z.receipt_id = x.id))
             order by x.component_key, x.installment_number loop
      perform private.post_receipt(r.id);
    end loop;
    perform set_config('corban.payout_rpc', 'off', true);
  end if;
end
$function$;

create or replace function private.post_receipt(p_receipt uuid)
returns void
language plpgsql
security definer
set search_path to ''
set "TimeZone" to 'America/Sao_Paulo'
as $function$
declare
  x public.commission_receipts%rowtype;
  c public.proposal_commission_calcs%rowtype;
  v_base numeric;
  v_ratio numeric;
  r record;
  v_debit numeric;
  v_total numeric;
  v_amount numeric;
  v_sched record;
  v_account uuid;
  v_ade text;
  v_keys text[];
  v_label text;
begin
  select * into x from public.commission_receipts where id = p_receipt;
  if x.id is null or exists (select 1 from public.payout_entries where receipt_id = x.id) then return; end if;
  perform set_config('corban.payout_rpc', 'on', true);

  if x.entry_kind = 'receipt' then
    select * into c from public.proposal_commission_calcs where id = x.calc_id;
    if c.id is null or c.mode <> 'group_values' or (x.component_key = 'deferred' and not c.pay_deferred) then return; end if;
    begin
      -- The Gratificação (03/11/2026): credited when it is received, after the contract credit is released, with the
      -- shares of the calculation in force; contracts credited the old way already have it in the contract credit.
      -- The Bônus (13/11/2026) the same way, with its own list of contracts credited the old way.
      if x.component_key in ('gratification', 'bonus') then
        if x.component_key = 'gratification' then
          if exists (select 1 from private.gratification_credit_legacy g where g.proposal_id = x.proposal_id) then return; end if;
          v_keys := array['gratification']; v_label := 'Gratificação do contrato';
        else
          if exists (select 1 from private.bonus_credit_legacy g where g.proposal_id = x.proposal_id) then return; end if;
          v_keys := array['bonus_1', 'bonus_2', 'bonus_3']; v_label := 'Bônus do contrato';
        end if;
        if not private.contract_credit_released(x.proposal_id) then return; end if;
        select * into c from public.proposal_commission_calcs where proposal_id = x.proposal_id and status = 'active';
        if c.id is null or c.mode <> 'group_values' then return; end if;
        select external_proposal_id into v_ade from public.proposals_v2 where id = x.proposal_id;
        for r in
          select 'originator'::text as role, private.payout_account_for(x.organization_id, c.seller_id, c.originator_user_id) as account,
                 coalesce((select sum(y.payable) from private.contract_payable(x.proposal_id) y where y.component_key = any (v_keys)), 0) as amount
          union all
          select 'supervisor', private.payout_account_for(x.organization_id, null, c.supervisor_user_id),
                 coalesce((select sum(l.amount * l.multiplier) from public.proposal_commission_lines l where l.calc_id = c.id and l.line_kind = 'supervisor' and l.component_key = any (v_keys)), 0)
          where c.supervisor_user_id is not null
          union all
          select 'manager', private.payout_account_for(x.organization_id, null, c.manager_user_id),
                 coalesce((select sum(l.amount * l.multiplier) from public.proposal_commission_lines l where l.calc_id = c.id and l.line_kind = 'manager' and l.component_key = any (v_keys)), 0)
          where c.manager_user_id is not null
        loop
          if r.account is not null and r.amount > 0 then
            insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, proposal_id, receipt_id, beneficiary_role, description, status, created_by,
                                               source, component_key)
            values (x.organization_id, r.account, 'commission', r.amount, current_date, x.proposal_id, x.id, r.role,
                    left(v_label || coalesce(' ' || v_ade, ''), 200), 'approved', auth.uid(), 'receipt', x.component_key);
          end if;
        end loop;
        return;
      end if;
      -- Part C3: à vista and the other types are credited with the contract (sync_contract_credit); deferred is
      -- credited here, installment by installment, only to a seller enabled to receive it and once the credit is due.
      if x.component_key <> 'deferred' or x.installment_number is null or coalesce(c.installments, 0) < 1 then return; end if;
      if not coalesce((select s.receives_deferred from public.commercial_sellers s where s.id = c.seller_id), false) then return; end if;
      if not private.contract_credit_released(x.proposal_id) then return; end if;
      select payable into v_total from private.contract_payable(x.proposal_id) where component_key = 'deferred';
      if coalesce(v_total, 0) <= 0 then return; end if;
      select * into v_sched from private.deferred_schedule(v_total, c.installments);
      v_amount := case when x.installment_number >= c.installments then v_sched.last else v_sched.standard end;
      v_account := private.payout_account_for(x.organization_id, c.seller_id, c.originator_user_id);
      if v_amount > 0 and v_account is not null then
        insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, proposal_id, receipt_id, beneficiary_role, description, status, created_by,
                                           source, component_key, installment_number)
        values (x.organization_id, v_account, 'commission', v_amount, current_date, x.proposal_id, x.id, 'originator',
                'Comissão diferido parcela ' || x.installment_number, 'approved', auth.uid(), 'receipt', 'deferred', x.installment_number);
      end if;
    end;
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
      where e.proposal_id = x.proposal_id and e.kind in ('commission','chargeback','adjustment') and e.status = 'approved'
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

create or replace function private.fin_post_receipt(p_receipt uuid)
returns uuid
language plpgsql
security definer
set search_path to ''
set "TimeZone" to 'America/Sao_Paulo'
as $function$
declare x public.commission_receipts%rowtype; v_account uuid; v_key text; v_id uuid; v_ade text; v_bank text; v_bank_account uuid;
begin
  select * into x from public.commission_receipts where id = p_receipt;
  if x.id is null then return null; end if;
  if exists (select 1 from public.fin_entries e where e.organization_id = x.organization_id and e.source = 'commission_receipt' and e.source_ref = x.id and e.status <> 'cancelled') then return null; end if;
  perform private.fin_ensure_chart(x.organization_id);
  v_key := case when x.entry_kind = 'chargeback' then 'chargeback' when x.component_key = 'deferred' then 'commission_deferred' else 'commission_upfront' end;
  select id into v_account from public.fin_chart_accounts where organization_id = x.organization_id and system_key = v_key;
  select p.external_proposal_id, p.commercial_snapshot->>'bank' into v_ade, v_bank from public.proposals_v2 p where p.id = x.proposal_id;
  -- The account that received the report's money, when the import said it.
  select r.bank_account_id into v_bank_account from public.receipt_reports r
  join public.fin_bank_accounts k on k.id = r.bank_account_id and k.organization_id = x.organization_id
  where r.id = x.report_id;
  insert into public.fin_entries (organization_id, direction, status, description, account_id, counterpart, amount, due_on, competence_on, settled_on, source, source_ref, proposal_id, bank_account_id, created_by)
  values (x.organization_id, case when x.entry_kind = 'chargeback' then 'out' else 'in' end, 'settled',
          left(case when x.entry_kind = 'chargeback' then 'Estorno de comissão' when x.component_key = 'deferred' then 'Comissão diferida parcela ' || coalesce(x.installment_number::text, '')
               when x.component_key = 'gratification' then 'Gratificação' when x.component_key = 'bonus' then 'Bônus' else 'Comissão à vista' end || coalesce(' · ADE ' || v_ade, ''), 200),
          v_account, left(v_bank, 120), x.amount, coalesce(x.received_on, current_date), coalesce(x.received_on, current_date), coalesce(x.received_on, current_date),
          'commission_receipt', x.id, x.proposal_id, v_bank_account, auth.uid())
  returning id into v_id;
  perform private.fin_event(x.organization_id, v_id, 'created', jsonb_build_object('source', 'commission_receipt'), null);
  return v_id;
end
$function$;

create or replace function public.register_manual_receipt(p_proposal_id uuid, p_kind text, p_amount text, p_received_on date, p_installment integer, p_note text)
returns uuid
language plpgsql
set search_path to ''
as $function$
declare
  p record;
  v_source_kind text;
  v_source uuid;
  v_report uuid;
  v_line public.receipt_lines%rowtype;
  v_receipt uuid;
  v_note text := left(btrim(coalesce(p_note, '')), 100);
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if coalesce(p_kind, '') not in ('upfront', 'deferred', 'chargeback', 'gratification', 'bonus') then raise exception 'invalid_receipt_kind'; end if;
  if coalesce(p_amount, '') !~ '^\d{1,13}(\.\d{1,2})?$' or p_amount::numeric <= 0 then raise exception 'invalid_receipt_amount'; end if;
  if p_received_on is null or p_received_on < date '2000-01-01' or p_received_on > (now() at time zone 'America/Sao_Paulo')::date then
    raise exception 'invalid_receipt_date';
  end if;
  if p_installment is not null and (p_kind <> 'deferred' or p_installment < 1 or p_installment > 9999) then raise exception 'invalid_receipt_installment'; end if;

  -- RLS: only a contract the caller can see.
  select x.id, x.organization_id, x.external_proposal_id, r.production_origin, r.org_bank_id, r.org_provider_id into p
  from public.proposals_v2 x
  join public.product_table_versions v on v.id = x.product_table_version_id
  join public.product_tables t on t.id = v.product_table_id
  join public.organization_product_routes r on r.id = t.route_id
  where x.id = p_proposal_id;
  if p.id is null then raise exception 'proposal_not_found'; end if;
  if not public.has_permission(p.organization_id, 'financeiro.approve') then raise exception 'not_authorized'; end if;
  if p.production_origin = 'third_party' and p.org_provider_id is not null then
    v_source_kind := 'provider'; v_source := p.org_provider_id;
  elsif p.org_bank_id is not null then
    v_source_kind := 'bank'; v_source := p.org_bank_id;
  else
    raise exception 'receipt_source_not_found';
  end if;

  v_report := public.import_receipt_report(
    p.organization_id, v_source_kind, v_source, p_kind, p_received_on,
    'Lançamento manual', encode(extensions.digest(convert_to(p.id::text || '|' || p_kind || '|' || p_amount || '|' || p_received_on::text || '|' || auth.uid()::text || '|' || clock_timestamp()::text, 'UTF8'), 'sha256'), 'hex'),
    p_amount::numeric,
    jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'row', 1, 'ade', coalesce(nullif(btrim(p.external_proposal_id), ''), 'MANUAL'), 'amount', p_amount,
      'installment', p_installment::text, 'paid_on', p_received_on::text,
      'bank', 'Lançamento manual' || case when v_note <> '' then ': ' || v_note else '' end))));

  select * into v_line from public.receipt_lines where report_id = v_report;
  perform public.link_receipt_line(v_line.id, p.id);
  select * into v_line from public.receipt_lines where id = v_line.id;
  if v_line.status = 'duplicate' then raise exception 'manual_receipt_duplicate'; end if;
  if v_line.status = 'no_calc' then raise exception 'manual_receipt_no_calc'; end if;
  if v_line.status = 'installment_invalid' then raise exception 'manual_receipt_installment_invalid'; end if;
  if v_line.status not in ('ok', 'divergent') then raise exception 'manual_receipt_not_matched'; end if;

  perform public.confirm_receipt_report(v_report);
  select id into v_receipt from public.commission_receipts where line_id = v_line.id;
  return v_receipt;
end
$function$;

create or replace function public.receipt_file_check(p_org uuid, p_source_kind text, p_source_id uuid, p_report_kind text, p_ades text[])
returns table(ade text, result text, contract_status text)
language sql
stable
security definer
set search_path to ''
as $$
  with a as (select distinct x as ade from unnest(coalesce(p_ades, '{}')) x where private.norm_ade(x) is not null limit 5000),
  m as (
    select a.ade, p.id, p.status, p.seller_id
    from a
    left join lateral (
      select p.* from public.proposals_v2 p
      join public.product_table_versions v on v.id = p.product_table_version_id
      join public.product_tables t on t.id = v.product_table_id
      join public.organization_product_routes r on r.id = t.route_id
      where p.organization_id = p_org
        and (case p_source_kind when 'bank' then r.org_bank_id = p_source_id else r.org_provider_id = p_source_id end)
        and (private.norm_ade(p.external_proposal_id) = private.norm_ade(a.ade)
             or exists (select 1 from public.proposal_external_identities e
                        where e.organization_id = p.organization_id and e.proposal_id = p.id and private.norm_ade(e.external_proposal_number) = private.norm_ade(a.ade)))
    ) p on true
  )
  select m.ade,
         case
           when count(m.id) = 0 then 'not_found'
           when count(m.id) > 1 then 'ambiguous'
           when p_report_kind = 'upfront' and exists (select 1 from public.commission_receipts x where x.proposal_id = min(m.id::text)::uuid
                                                       and x.entry_kind = 'receipt' and x.component_key = 'upfront') then 'received'
           when p_report_kind = 'bonus' and exists (select 1 from public.commission_receipts x where x.proposal_id = min(m.id::text)::uuid
                                                     and x.entry_kind = 'receipt' and x.component_key = 'bonus') then 'received'
           when p_report_kind <> 'chargeback' and bool_and(m.seller_id is null) then 'no_seller'
           when p_report_kind <> 'chargeback' and not exists (select 1 from public.proposal_commission_calcs c
                                                              where c.proposal_id = min(m.id::text)::uuid and c.status = 'active') then 'no_calc'
           else 'ready'
         end,
         min(m.status)
  from m
  where (select auth.uid()) is not null and public.has_permission(p_org, 'financeiro.edit')
  group by m.ade
  order by m.ade
$$;
revoke all on function public.receipt_file_check(uuid, text, uuid, text, text[]) from public, anon;
grant execute on function public.receipt_file_check(uuid, text, uuid, text, text[]) to authenticated;

create or replace function public.commission_receivable(p_org uuid, p_source uuid default null, p_min_days integer default 0,
                                                        p_limit integer default 50, p_offset integer default 0)
returns table (proposal_id uuid, reference text, client text, source_id uuid, source_name text, paid_at timestamptz,
               expected_amount text, total_count bigint, total_expected text)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or p_org is null or not public.has_permission(p_org, 'financeiro.view') then raise exception 'not_authorized'; end if;
  if coalesce(p_limit, 0) < 1 or p_limit > 200 or coalesce(p_offset, -1) < 0 or coalesce(p_min_days, -1) < 0 or p_min_days > 3650 then
    raise exception 'invalid_page';
  end if;
  return query
  with paid as (
    select p.id, p.external_proposal_id, p.customer_snapshot->>'full_name' as client,
           case when r.production_origin = 'third_party' and r.org_provider_id is not null then r.org_provider_id else r.org_bank_id end as src,
           coalesce((select max(e.evidenced_at) from public.proposal_status_evidence e where e.proposal_id = p.id and e.canonical_status = 'paid'), p.updated_at) as paid_at
    from public.proposals_v2 p
    left join public.product_table_versions v on v.id = p.product_table_version_id
    left join public.product_tables t on t.id = v.product_table_id
    left join public.organization_product_routes r on r.id = t.route_id
    where p.organization_id = p_org and p.status = 'paid'
      and not exists (select 1 from public.commission_receipts x where x.proposal_id = p.id and x.entry_kind = 'receipt' and x.component_key = 'upfront')
  ), rows as (
    select pd.id, coalesce(pd.external_proposal_id, '') as reference, coalesce(pd.client, '') as client, pd.src,
           coalesce((select b.name from public.organization_banks b where b.id = pd.src), (select o.name from public.organization_providers o where o.id = pd.src), '') as src_name,
           pd.paid_at,
           (select sum(l.amount) from public.proposal_commission_calcs c
              join public.proposal_commission_lines l on l.calc_id = c.id
            where c.proposal_id = pd.id and c.status = 'active' and l.part = 'upfront' and l.line_kind = 'received'
              and l.component_key <> 'gratification' and l.component_key not in ('bonus_1', 'bonus_2', 'bonus_3')) as expected
    from paid pd
    where (p_source is null or pd.src = p_source)
      and pd.paid_at < now() - make_interval(days => p_min_days)
  )
  select x.id, x.reference, x.client, x.src, x.src_name, x.paid_at, x.expected::text,
         count(*) over (), coalesce(sum(x.expected) over (), 0)::text
  from rows x
  order by x.paid_at, x.id
  limit p_limit offset p_offset;
end
$$;
revoke all on function public.commission_receivable(uuid, uuid, integer, integer, integer) from public, anon;
grant execute on function public.commission_receivable(uuid, uuid, integer, integer, integer) to authenticated;

-- Draft à vista reports are matched again with the new expected amount.
do $$
declare r record; n int := 0;
begin
  perform set_config('corban.receipt_rpc', 'on', true);
  for r in select id from public.receipt_reports where status = 'draft' and report_kind = 'upfront' loop
    perform private.rematch_receipt_report(r.id);
    n := n + 1;
  end loop;
  perform set_config('corban.receipt_rpc', 'off', true);
  raise notice 'bonus apart: % draft reports matched again, % legacy contracts', n, (select count(*) from private.bonus_credit_legacy);
end $$;
