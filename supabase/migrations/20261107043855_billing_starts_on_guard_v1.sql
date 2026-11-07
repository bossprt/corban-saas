-- Subscription first month guard (audit 06/11/2026, G2).
-- A NEW subscription with a first month before the current month (Brasília) created, on the next screen opened, one
-- charge per past month, already past the grace, and blocked the company at once; charges cannot be deleted.
-- From now on platform_set_subscription refuses a first month earlier than:
--   * the current month, for a company without a subscription;
--   * the earlier of the current month and the first month it already has, for an existing subscription (it keeps
--     working and may keep its first month; it only cannot be moved further back).
-- Nothing else changes: no existing subscription, charge or event is touched.
-- Contract: tests/security/billing-contract.sql

create or replace function public.platform_set_subscription(p_actor uuid, p_org uuid, p_amount numeric, p_due_day integer, p_grace_days integer, p_starts_on date, p_active boolean)
returns void language plpgsql security definer set search_path to '' set timezone to 'America/Sao_Paulo' as $$
declare v_current date; v_min date;
begin
  if p_amount is null or p_amount <> round(p_amount, 2) then raise exception 'billing_invalid_amount'; end if;
  select s.starts_on into v_current from public.organization_subscriptions s where s.organization_id = p_org for update;
  v_min := date_trunc('month', current_date)::date;
  if v_current is not null and v_current < v_min then v_min := v_current; end if;
  if p_starts_on is null or date_trunc('month', p_starts_on)::date < v_min then raise exception 'billing_starts_on_in_past'; end if;
  insert into public.organization_subscriptions (organization_id, amount, due_day, grace_days, starts_on, is_active, updated_at, updated_by)
  values (p_org, p_amount, p_due_day, p_grace_days, date_trunc('month', p_starts_on)::date, p_active, now(), p_actor)
  on conflict (organization_id) do update set amount = excluded.amount, due_day = excluded.due_day, grace_days = excluded.grace_days,
    starts_on = excluded.starts_on, is_active = excluded.is_active, updated_at = now(), updated_by = p_actor;
end
$$;

revoke all on function public.platform_set_subscription(uuid, uuid, numeric, integer, integer, date, boolean) from public, anon, authenticated;
grant execute on function public.platform_set_subscription(uuid, uuid, numeric, integer, integer, date, boolean) to service_role;
