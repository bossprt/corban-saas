-- Payout reports (owner, 21/10/2026: "relatório de comissão... muito amador"): a printable statement ("demonstrativo")
-- with who pays (company and CNPJ), who receives (name, CPF/CNPJ, PIX or bank account), each contract (client, bank,
-- agreement, product, released amount, day paid to the client, commission) and the total; per batch and per person over
-- a period. Read only.

-- The contracts one payment paid (closing: its entries; payment from the balance: oldest contracts first, ADR-0061),
-- each with its details. Shared by the batch screen and the reports.
create or replace function private.payout_contracts(p_payout uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  select case when p.kind = 'withdrawal' then coalesce((
    select jsonb_agg(jsonb_build_object('proposal_id', c.proposal_id, 'ade', c.ade, 'client', c.client, 'amount', c.amount::text,
                                        'partial', c.partial, 'kind', c.kind) || coalesce(private.batch_contract_info(c.proposal_id), '{}'::jsonb) order by c.ade nulls last, c.kind)
    from (select a.r_proposal as proposal_id, pr.external_proposal_id as ade, pr.customer_snapshot->>'full_name' as client,
                 sum(a.r_amount) as amount, bool_or(a.r_amount < a.r_item) as partial,
                 case when a.r_proposal is null then a.r_kind end as kind
          from private.withdrawal_allocation(p.account_id) a left join public.proposals_v2 pr on pr.id = a.r_proposal
          where a.r_payout = p.id
          group by a.r_proposal, pr.external_proposal_id, pr.customer_snapshot->>'full_name', case when a.r_proposal is null then a.r_kind end) c), '[]'::jsonb)
  else coalesce((
    select jsonb_agg(jsonb_build_object('proposal_id', c.proposal_id, 'ade', c.ade, 'client', c.client, 'amount', c.amount::text,
                                        'partial', false, 'kind', null) || coalesce(private.batch_contract_info(c.proposal_id), '{}'::jsonb) order by c.ade)
    from (select e.proposal_id, pr.external_proposal_id as ade, pr.customer_snapshot->>'full_name' as client, sum(e.amount) as amount
          from public.payout_entries e join public.proposals_v2 pr on pr.id = e.proposal_id
          where e.statement_id = p.id and e.kind in ('commission', 'chargeback', 'adjustment') and e.status = 'approved'
          group by e.proposal_id, pr.external_proposal_id, pr.customer_snapshot->>'full_name') c), '[]'::jsonb) end
  from public.payouts p where p.id = p_payout
$$;
revoke all on function private.payout_contracts(uuid) from public, anon, authenticated;

-- Who receives: CPF/CNPJ of the seller and where the money goes (the primary PIX or bank account of the seller).
create or replace function private.payout_holder_info(p_account uuid)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  select jsonb_build_object(
    'name', private.payout_holder_name(a.id),
    'document', s.tax_id,
    'pay_target', (select jsonb_build_object('transfer_method', b.transfer_method, 'pix_key_type', b.pix_key_type, 'pix_key', b.pix_key,
                                             'bank_code', b.bank_code, 'bank_name', b.bank_name, 'branch', b.branch, 'account_number', b.account_number,
                                             'account_digit', b.account_digit, 'holder_name', b.holder_name, 'holder_document', b.holder_document)
                   from public.seller_bank_accounts b
                   where b.seller_id = a.seller_id and b.removed_at is null
                   order by b.is_primary desc, b.created_at limit 1))
  from public.payout_accounts a left join public.commercial_sellers s on s.id = a.seller_id
  where a.id = p_account
$$;
revoke all on function private.payout_holder_info(uuid) from public, anon, authenticated;

-- One batch: header (with the paying company) and one line per payment with who receives and the contracts it paid.
create or replace function public.payout_batch_detail(p_batch uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare b public.payout_batches%rowtype;
begin
  select * into b from public.payout_batches where id = p_batch;
  if b.id is null or auth.uid() is null or not public.has_permission(b.organization_id, 'repasse.view') then raise exception 'not_authorized'; end if;
  return jsonb_build_object(
    'id', b.id, 'paid_on', b.paid_on, 'payment_reference', b.payment_reference, 'origin', b.origin, 'created_at', b.created_at,
    'company', (select jsonb_build_object('name', o.name, 'document', o.document) from public.organizations o where o.id = b.organization_id),
    'paid_by', (select coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), u.email) from auth.users u where u.id = b.created_by),
    'reversed_at', b.reversed_at, 'reversal_reason', b.reversal_reason,
    'total', (select coalesce(sum(x.amount), 0)::text from public.payouts x where x.batch_id = b.id),
    'reversed_by', (select coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), u.email) from auth.users u where u.id = b.reversed_by),
    'bank_accounts', (select string_agg(distinct coalesce(nullif(a.label, ''), a.bank_name), ', ') from public.fin_entries f join public.fin_bank_accounts a on a.id = f.bank_account_id
                      where f.organization_id = b.organization_id and f.source = 'payout' and f.source_ref in (select x.id from public.payouts x where x.batch_id = b.id)),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'payout_id', p.id, 'account_id', p.account_id, 'holder', private.payout_holder_name(p.account_id), 'kind', p.kind,
        'amount', p.amount::text, 'status', p.status, 'reversal_reason', p.reversal_reason,
        'holder_document', private.payout_holder_info(p.account_id)->>'document', 'pay_target', private.payout_holder_info(p.account_id)->'pay_target',
        'contracts', private.payout_contracts(p.id)
      ) order by private.payout_holder_name(p.account_id))
      from public.payouts p where p.batch_id = b.id), '[]'::jsonb));
end
$$;
revoke all on function public.payout_batch_detail(uuid) from public, anon;
grant execute on function public.payout_batch_detail(uuid) to authenticated;

-- One person over a period: every payment made to them (paid, not undone) with its contracts. Finance, or the person.
create or replace function public.payout_account_report(p_account uuid, p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare a public.payout_accounts%rowtype;
begin
  select * into a from public.payout_accounts where id = p_account;
  if a.id is null or auth.uid() is null
     or not (public.has_permission(a.organization_id, 'repasse.view') or private.is_payout_holder(a.id)) then raise exception 'not_authorized'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 400 then raise exception 'invalid_period'; end if;
  return jsonb_build_object(
    'company', (select jsonb_build_object('name', o.name, 'document', o.document) from public.organizations o where o.id = a.organization_id),
    'holder', private.payout_holder_info(a.id),
    'from', p_from, 'to', p_to,
    'total', (select coalesce(sum(p.amount), 0)::text from public.payouts p where p.account_id = a.id and p.status = 'paid' and p.paid_on between p_from and p_to),
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object('payout_id', p.id, 'paid_on', p.paid_on, 'kind', p.kind, 'amount', p.amount::text,
                                          'reference', p.payment_reference, 'contracts', private.payout_contracts(p.id)) order by p.paid_on, p.requested_at)
      from public.payouts p where p.account_id = a.id and p.status = 'paid' and p.paid_on between p_from and p_to), '[]'::jsonb));
end
$$;
revoke all on function public.payout_account_report(uuid, date, date) from public, anon;
grant execute on function public.payout_account_report(uuid, date, date) to authenticated;
