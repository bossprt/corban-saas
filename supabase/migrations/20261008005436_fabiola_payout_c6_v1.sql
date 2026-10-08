-- Owner decision 07/10/2026: the R$ 800,00 paid to the seller of contract 131259 on 11/09/2026 (registered as paid outside
-- Corban, posted to the finance on 07/10/2026) left from the C6 account. Only the account of that finance entry changes,
-- with an event; amount and date do not. Before the account's opening date, so the balance does not change.
do $$
declare v_org uuid := '62405e20-af29-4359-b39c-79c206146b6c'; v_c6 uuid; v_entry uuid;
begin
  select k.id into v_c6 from public.fin_bank_accounts k where k.organization_id = v_org and k.label = 'C6 MART PROMOTORA' and k.is_active;
  select e.id into v_entry from public.fin_entries e
  where e.organization_id = v_org and e.source = 'payout' and e.source_ref = 'bd308f52-07b6-4549-8335-6adab7a39a95'
    and e.status = 'settled' and e.amount = 800.00 and e.bank_account_id is null;
  if v_c6 is null or v_entry is null then raise notice 'fabiola payout c6: nothing to do'; return; end if;
  update public.fin_entries set bank_account_id = v_c6, updated_at = now() where id = v_entry;
  perform private.fin_event(v_org, v_entry, 'edited', jsonb_build_object('field', 'bank_account', 'from', null, 'to', v_c6),
                            'Decisão do dono 07/10/2026: o repasse de 11/09 saiu da conta C6');
end
$$;
