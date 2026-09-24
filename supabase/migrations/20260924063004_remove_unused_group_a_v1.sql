-- F0 cleanup, group A (approved by the owner on 2026-09-24, ADR-0027 / MAPA-OPERACAO).
-- Removes tables and functions with no rows, no screen, no application caller and no dependents outside the group.
-- AI metering is rebuilt in F9; seller details are rebuilt in F3/F6; `contracts` is superseded by proposals_v2.
-- Kept on purpose: seller_profiles (holds the profile of a real seller), seller_supervisions (read by can_view_seller_commission in financial RLS) and lead_events
-- (written by private.lead_write); both leave with the phase that replaces them.
-- No CASCADE: an unexpected dependent makes the migration fail instead of silently dropping it.
-- Applied as one transaction by the migration runner.


do $$
declare
  v_rows bigint;
  t text;
begin
  foreach t in array array[
    'ai_credit_ledger','ai_usage_events','ai_usage_jobs','organization_ai_limits',
    'import_jobs','import_layout_mappings','contracts',
    'seller_addresses','seller_bank_aliases','seller_certifications','seller_payment_accounts'
  ] loop
    execute format('select count(*) from public.%I', t) into v_rows;
    if v_rows > 0 then
      raise exception 'group_a_table_not_empty: % has % rows', t, v_rows;
    end if;
  end loop;
end $$;

drop function if exists public.reserve_ai_job;
drop function if exists public.settle_ai_job;
drop function if exists public.ai_credit_balance;
drop function if exists public.platform_grant_ai_credits;
drop function if exists public.platform_set_ai_limits;
drop function if exists public.confirm_import_mapping;
drop function if exists public.replace_seller_address;
drop function if exists public.resolve_seller_bank_alias;
drop function if exists public.set_seller_payment_account;
drop function if exists public.upsert_seller_certification;

drop table if exists
  public.ai_usage_events,
  public.ai_credit_ledger,
  public.ai_usage_jobs,
  public.organization_ai_limits,
  public.import_layout_mappings,
  public.import_jobs,
  public.contracts,
  public.seller_addresses,
  public.seller_bank_aliases,
  public.seller_certifications,
  public.seller_payment_accounts;

-- Trigger function used only by the AI tables above; dropped after them.
drop function if exists public.guard_ai_write();

