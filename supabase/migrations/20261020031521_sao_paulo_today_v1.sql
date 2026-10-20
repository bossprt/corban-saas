-- Owner (19/10/2026): the database runs in UTC, three hours ahead of Brasília. Functions that take "today" from
-- current_date (or truncate timestamps to days/months) used the UTC date, so between 21:00 and midnight in Brasília
-- "today" was already tomorrow: a contract moved to "Paga" without a date got tomorrow's date, a paid date of tomorrow
-- was accepted, and ledger/finance entries made in that window could be dated tomorrow.
--
-- Fix: these functions run with the São Paulo time zone (SET clause), so current_date, ::date and date_trunc follow
-- Brasília. Instants (timestamptz values) are unchanged; only the calendar day they fall on is read in Brasília.
-- A later "create or replace" of any of them must keep `set timezone to 'America/Sao_Paulo'`; the contract test
-- tests/security/sao-paulo-today-contract.sql fails when a function using current_date runs without it.

alter function private.api_contract_apply(p_org uuid, p_key_id uuid, p jsonb) set timezone to 'America/Sao_Paulo';
alter function private.api_contract_enrich_client(p_org uuid, p_client uuid, p_agreement uuid, cl jsonb) set timezone to 'America/Sao_Paulo';
alter function private.fin_post_payout(p_payout uuid) set timezone to 'America/Sao_Paulo';
alter function private.fin_post_receipt(p_receipt uuid) set timezone to 'America/Sao_Paulo';
alter function private.mark_paid_by_commission_report(p_proposal uuid, p_report uuid, p_paid_on date) set timezone to 'America/Sao_Paulo';
alter function private.payout_available(p_account uuid) set timezone to 'America/Sao_Paulo';
alter function private.post_receipt(p_receipt uuid) set timezone to 'America/Sao_Paulo';
alter function private.sync_contract_credit(p_proposal uuid, p_force boolean) set timezone to 'America/Sao_Paulo';
alter function public.add_payout_entry(p_account uuid, p_kind text, p_amount numeric, p_direction text, p_description text, p_effective_on date, p_installments integer) set timezone to 'America/Sao_Paulo';
alter function public.close_payout_period(p_org uuid, p_period_end date, p_frequency text) set timezone to 'America/Sao_Paulo';
alter function public.fin_cash_flow(p_org uuid, p_from date, p_to date, p_branch uuid) set timezone to 'America/Sao_Paulo';
alter function public.fin_create_entry(p_org uuid, p_direction text, p_description text, p_account uuid, p_branch uuid, p_counterpart text, p_document text, p_amount numeric, p_due_on date, p_competence_on date, p_installments integer, p_settled_on date, p_bank_account uuid, p_repeat boolean, p_interval_days integer) set timezone to 'America/Sao_Paulo';
alter function public.fin_income_statement(p_org uuid, p_from date, p_to date, p_branch uuid) set timezone to 'America/Sao_Paulo';
alter function public.fin_save_bank_account(p_org uuid, p_id uuid, p_bank_name text, p_label text, p_agency text, p_account_number text, p_opening_balance numeric, p_opening_on date, p_active boolean) set timezone to 'America/Sao_Paulo';
alter function public.fin_settle_entry(p_entry uuid, p_settled_on date, p_bank_account uuid) set timezone to 'America/Sao_Paulo';
alter function public.goal_progress(p_org uuid, p_month date) set timezone to 'America/Sao_Paulo';
alter function public.import_receipt_report(p_org uuid, p_source_kind text, p_source_id uuid, p_report_kind text, p_reference_month date, p_file_name text, p_file_sha256 text, p_declared_total numeric, p_rows jsonb) set timezone to 'America/Sao_Paulo';
alter function public.import_smart_commercial_rows(p_organization uuid, p_production_origin text, p_provider uuid, p_policy_version uuid, p_rows jsonb) set timezone to 'America/Sao_Paulo';
alter function public.mark_payout_paid(p_payout uuid, p_paid_on date, p_reference text) set timezone to 'America/Sao_Paulo';
alter function public.move_case_to_stage(p_case_id uuid, p_stage_id uuid, p_note text, p_pendency_due_at timestamp with time zone, p_paid_on date) set timezone to 'America/Sao_Paulo';
alter function public.owner_dashboard(p_org uuid, p_from date, p_to date, p_prev_from date, p_prev_to date) set timezone to 'America/Sao_Paulo';
alter function public.register_external_payout(p_proposal uuid, p_paid_on date, p_reference text) set timezone to 'America/Sao_Paulo';
alter function public.save_client_registration(p_client uuid, p_registration uuid, p_agreement uuid, p_agency_name text, p_registration_number text, p_status text, p_margin_amount numeric, p_margin_as_of date, p_portal_login text, p_password text, p_clear_password boolean, p_notes text) set timezone to 'America/Sao_Paulo';
alter function public.seller_dashboard(p_org uuid) set timezone to 'America/Sao_Paulo';
alter function public.set_legacy_settings(p_org uuid, p_cutoff_on date, p_opportunities boolean) set timezone to 'America/Sao_Paulo';
alter function public.set_payout_account_model(p_account uuid, p_model text) set timezone to 'America/Sao_Paulo';
alter function public.set_seller_goal(p_org uuid, p_user_id uuid, p_month date, p_target_amount numeric) set timezone to 'America/Sao_Paulo';
alter function public.stage_legacy_rows(p_org uuid, p_batch uuid, p_source text, p_file_name text, p_file_sha256 text, p_rows jsonb) set timezone to 'America/Sao_Paulo';
alter function public.update_client_profile(p_client uuid, p_birth_date date, p_father_name text, p_mother_name text, p_rg_number text, p_rg_issuer text, p_rg_state text, p_rg_issued_on date, p_gender text, p_marital_status text, p_birthplace_city text, p_birthplace_state text, p_whatsapp text) set timezone to 'America/Sao_Paulo';
alter function public.update_contract(p_proposal uuid, p_data jsonb, p_reason text) set timezone to 'America/Sao_Paulo';

alter table public.fin_bank_accounts alter column opening_on set default ((now() at time zone 'America/Sao_Paulo')::date);
