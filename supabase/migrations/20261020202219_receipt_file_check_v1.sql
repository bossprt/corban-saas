-- Owner (20/10/2026): a commission report whose contracts had no seller went through without a clear warning ("se ele me
-- fala o arquivo possui X contratos e os contratos não podem ser importados porque não possuem vendedor..."). Before
-- importing, the screen now checks every contract number of the file with the same match the import uses (ADE within the
-- routes of the paying source) and says, per contract, whether it is ready or why not. Read only.
--   ready      contract found, with seller and commission calculated
--   no_seller  contract found without seller: no commission is calculated until the seller is set
--   no_calc    contract found with seller but no commission calculated (e.g. table without commission condition)
--   received   this commission (à vista) was already received from the bank
--   not_found  no contract of this bank/promoter with this number
--   ambiguous  more than one contract with this number

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
