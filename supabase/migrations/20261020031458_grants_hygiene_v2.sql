-- Grants hygiene (19/10/2026, owner approved): the contract tests grants-hygiene and security-definer-inventory found
-- three gaps that came with recent migrations. None was reachable in practice, all are closed here.
--   1. anon could EXECUTE five private functions (default PUBLIC grant). anon has no usage on schema private, and four are
--      trigger functions (triggers never need EXECUTE grants), but the rule is: anon executes nothing.
--   2. anon held SELECT on the terms tables (default grant on new tables). RLS only has policies for authenticated, so
--      anon read nothing, but the rule is: anon holds no table privilege.
--   3. pay_account_in_batch had no caller check of its own; it relied on pay_account_now_checked. It now checks too.

revoke all on function private.guard_terms_immutable() from public, anon;
revoke all on function private.improvement_requests_guard() from public, anon;
revoke all on function private.payout_batch_on_paid() from public, anon;
revoke all on function private.guard_manual_component_write() from public, anon;
revoke all on function private.table_bank_code_from(text, text) from public, anon;
-- The product_tables trigger runs as the caller and uses it.
grant execute on function private.table_bank_code_from(text, text) to authenticated;

revoke all on table public.terms_versions from anon;
revoke all on table public.organization_terms_acceptances from anon;

create or replace function public.pay_account_in_batch(p_account uuid, p_paid_on date, p_reference text, p_expected numeric, p_batch uuid)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare v_id uuid; v_org uuid;
begin
  select organization_id into v_org from public.payout_accounts where id = p_account;
  if v_org is null or auth.uid() is null or not public.has_permission(v_org, 'repasse.approve') then raise exception 'not_authorized'; end if;
  if p_batch is null then raise exception 'invalid_payout_batch'; end if;
  perform set_config('corban.payout_batch', p_batch::text, true);
  v_id := public.pay_account_now_checked(p_account, p_paid_on, p_reference, p_expected);
  perform set_config('corban.payout_batch', '', true);
  return v_id;
end
$$;
revoke all on function public.pay_account_in_batch(uuid, date, text, numeric, uuid) from public, anon;
grant execute on function public.pay_account_in_batch(uuid, date, text, numeric, uuid) to authenticated;
