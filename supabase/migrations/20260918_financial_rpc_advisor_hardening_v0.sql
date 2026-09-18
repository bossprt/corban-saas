-- CORBAN OS V2 — Financial RPC Advisor Hardening V0
-- Preserve guarded RPCs while avoiding exposed SECURITY DEFINER functions.
-- Dedicated write policies allow only rows whose actor is the current authenticated user.

create policy financial_events_insert_guarded_actor on public.financial_events for insert to authenticated
with check(public.has_active_organization_role(organization_id,array['admin','manager','supervisor']) and created_by=(select auth.uid()));
create policy financial_evidence_links_insert_guarded_member on public.financial_evidence_links for insert to authenticated
with check(public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy financial_reconciliation_cases_insert_guarded on public.financial_reconciliation_cases for insert to authenticated
with check(public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));
create policy financial_reconciliation_cases_update_guarded on public.financial_reconciliation_cases for update to authenticated
using(public.has_active_organization_role(organization_id,array['admin','manager','supervisor']))
with check(public.has_active_organization_role(organization_id,array['admin','manager','supervisor']));

grant insert on public.financial_events,public.financial_evidence_links,public.financial_reconciliation_cases to authenticated;
grant update on public.financial_reconciliation_cases to authenticated;
alter function public.publish_financial_evidence_event(uuid,text,text,numeric,timestamptz,text,text,uuid,uuid,uuid) security invoker;
alter function public.refresh_financial_reconciliation(uuid,text) security invoker;
