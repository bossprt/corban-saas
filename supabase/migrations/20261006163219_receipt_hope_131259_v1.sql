-- Bank commission of contract 131259 (HOPE, Gov. AC): R$ 1.900,00 à vista, credited on 11/09/2026, as the owner read it
-- in the bank statement (06/10/2026). The seller was already paid outside Corban (2tech) on 11/09, so this is the last
-- step of the contract. Registered through public.register_manual_receipt, exactly like "Registrar recebimento" on
-- the contract, as the company's first administrator. Runs once: does nothing if the contract is not here or already
-- has a receipt.

do $$
declare
  v_proposal uuid;
  v_admin uuid;
begin
  select p.id into v_proposal from public.proposals_v2 p where p.external_proposal_id = '131259';
  if v_proposal is null then raise notice 'receipt 131259: contract not here, nothing to do'; return; end if;
  if exists (select 1 from public.commission_receipts r where r.proposal_id = v_proposal) then raise notice 'receipt 131259: already registered'; return; end if;
  select m.user_id into v_admin from public.organization_memberships m
  join public.proposals_v2 p on p.organization_id = m.organization_id and p.id = v_proposal
  where m.role = 'admin' and m.status = 'active' order by m.created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  perform public.register_manual_receipt(v_proposal, 'upfront', '1900.00', date '2026-09-11', null,
    'Comissão HOPE recebida em 11/09/2026 (extrato informado pelo dono em 06/10/2026)');
  perform set_config('request.jwt.claims', '', true);
end
$$;
