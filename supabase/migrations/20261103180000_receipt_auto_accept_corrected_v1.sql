-- A divergent receipt is accepted by the system when the contract is corrected to the amount received (owner request
-- 03/11/2026, contract 15178: Gratificação received R$ 80,00 against 6% = R$ 81,60, then the Gratificação typed as
-- R$ 80,00; "faça o sistema aceitar sozinho").
--
-- * private.receipt_expected_now(receipt): what the calculation in force expects for that receipt, as the matcher does
--   (à vista without the Gratificação, the Gratificação, or the deferred installment); null for a chargeback.
-- * private.accept_corrected_receipts(proposal): every divergent receipt of the contract without a resolution whose
--   amount now equals the expected amount gets an "accepted" resolution with a fixed note and the user who corrected
--   it. The receipt itself is never changed (append-only ledger); the resolution is the same record a person writes in
--   Conciliação, so the seller credit follows the same path.
-- * Runs at commit after every new calculation (deferred trigger, before the credit sync), and once here for the
--   receipts already divergent.

create or replace function private.receipt_expected_now(p_receipt uuid)
returns numeric
language sql
stable security definer
set search_path to ''
as $function$
  select case x.component_key
           when 'upfront' then (select sum(l.amount) from public.proposal_commission_lines l
                                where l.calc_id = c.id and l.part = 'upfront' and l.line_kind = 'received' and l.component_key <> 'gratification')
           when 'gratification' then (select sum(l.amount * l.multiplier) from public.proposal_commission_lines l
                                      where l.calc_id = c.id and l.line_kind = 'received' and l.component_key = 'gratification')
           when 'deferred' then (select l.amount from public.proposal_commission_lines l
                                 where l.calc_id = c.id and l.line_kind = 'received'
                                   and l.part = case when x.installment_number = c.installments then 'deferred_last' else 'deferred_standard' end
                                 limit 1)
         end
  from public.commission_receipts x
  join public.proposal_commission_calcs c on c.proposal_id = x.proposal_id and c.status = 'active'
  where x.id = p_receipt and x.entry_kind = 'receipt'
$function$;
revoke all on function private.receipt_expected_now(uuid) from public, anon, authenticated;

create or replace function private.accept_corrected_receipts(p_proposal uuid)
returns integer
language plpgsql
security definer
set search_path to ''
as $function$
declare r record; n integer := 0;
begin
  for r in
    select x.id, x.organization_id from public.commission_receipts x
    where x.proposal_id = p_proposal and x.entry_kind = 'receipt' and x.reconciliation = 'divergent'
      and not exists (select 1 from public.commission_receipt_resolutions z where z.receipt_id = x.id)
      and x.amount = private.receipt_expected_now(x.id)
    order by x.created_at
  loop
    perform set_config('corban.receipt_rpc', 'on', true);
    insert into public.commission_receipt_resolutions (organization_id, receipt_id, decision, note, decided_by)
    values (r.organization_id, r.id, 'accepted', 'Aceito pelo sistema: o valor do contrato foi corrigido para o valor recebido', auth.uid());
    perform set_config('corban.receipt_rpc', 'off', true);
    n := n + 1;
  end loop;
  return n;
end
$function$;
revoke all on function private.accept_corrected_receipts(uuid) from public, anon, authenticated;

create or replace function private.accept_corrected_receipts_trigger()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if new.status = 'active' then perform private.accept_corrected_receipts(new.proposal_id); end if;
  return null;
end
$function$;
revoke all on function private.accept_corrected_receipts_trigger() from public, anon, authenticated;

-- Named before the credit sync (_95), so the sync sees the acceptance.
create constraint trigger proposal_commission_calcs_90_accept_corrected after insert on public.proposal_commission_calcs
  deferrable initially deferred for each row execute function private.accept_corrected_receipts_trigger();

-- The receipts already divergent (e.g. 15178).
do $$
declare r record; n integer := 0;
begin
  for r in select distinct x.proposal_id from public.commission_receipts x
           where x.entry_kind = 'receipt' and x.reconciliation = 'divergent'
             and not exists (select 1 from public.commission_receipt_resolutions z where z.receipt_id = x.id) loop
    n := n + private.accept_corrected_receipts(r.proposal_id);
  end loop;
  raise notice 'accept corrected receipts: % accepted', n;
end $$;
