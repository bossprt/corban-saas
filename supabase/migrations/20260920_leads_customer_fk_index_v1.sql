-- Forward-only performance hardening after leads_v1.
-- Covers composite FK leads(organization_id, customer_id) -> clients(organization_id, id).
create index if not exists leads_org_customer_idx
  on public.leads(organization_id, customer_id)
  where customer_id is not null;
