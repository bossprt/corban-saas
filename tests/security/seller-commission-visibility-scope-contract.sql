-- Seller commission visibility scope V1 contract
do $$
declare
  def text;
begin
  if not exists(
    select 1 from information_schema.columns
    where table_schema='public' and table_name='commercial_sellers' and column_name='user_id'
  ) then raise exception 'seller_user_binding_missing'; end if;

  if to_regclass('public.seller_supervisions') is null then
    raise exception 'seller_supervisions_missing';
  end if;
  if to_regclass('public.proposal_seller_commission_snapshots') is null then
    raise exception 'seller_commission_snapshots_missing';
  end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='can_view_seller_commission';
  if def is null
     or position('admin' in def)=0
     or position('manager' in def)=0
     or position('supervisor' in def)=0
     or position('auth.uid()' in def)=0
     or position('seller_supervisions' in def)=0 then
    raise exception 'seller_commission_scope_helper_incomplete';
  end if;

  if has_function_privilege('anon','public.can_view_seller_commission(uuid,uuid)','EXECUTE') then
    raise exception 'anon_can_check_seller_commission_scope';
  end if;

  if not exists(
    select 1 from pg_policies
    where schemaname='public'
      and tablename='proposal_seller_commission_snapshots'
      and policyname='proposal_seller_commission_select_scoped'
      and qual ilike '%can_view_seller_commission%'
  ) then raise exception 'seller_commission_rls_missing'; end if;

  if exists(
    select 1 from pg_policies
    where schemaname='public'
      and tablename='financial_events'
      and policyname='financial_events_select_supervisor_plus'
  ) then raise exception 'broad_financial_event_supervisor_policy_still_present'; end if;

  if not exists(
    select 1 from pg_policies
    where schemaname='public'
      and tablename='financial_events'
      and policyname='financial_events_select_scoped'
      and qual ilike '%can_view_seller_commission%'
  ) then raise exception 'financial_events_not_supervisor_scoped'; end if;

  if exists(
    select 1 from pg_policies
    where schemaname='public'
      and tablename='financial_reconciliation_cases'
      and policyname='financial_reconciliation_cases_select_supervisor_plus'
  ) then raise exception 'broad_reconciliation_supervisor_policy_still_present'; end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='snapshot_seller_commission';
  if def is null
     or position('commercial_condition_shares' in def)=0
     or position('effective_pct' in def)=0
     or position('seller_commission_share_not_resolved' in def)=0 then
    raise exception 'seller_commission_snapshot_fail_closed_missing';
  end if;

  if has_table_privilege('anon','public.proposal_seller_commission_snapshots','SELECT')
     or has_table_privilege('anon','public.proposal_seller_commission_snapshots','INSERT')
     or has_table_privilege('anon','public.proposal_seller_commission_snapshots','UPDATE')
     or has_table_privilege('anon','public.proposal_seller_commission_snapshots','DELETE') then
    raise exception 'anon_seller_commission_privilege_present';
  end if;

  if has_table_privilege('authenticated','public.proposal_seller_commission_snapshots','UPDATE')
     or has_table_privilege('authenticated','public.proposal_seller_commission_snapshots','DELETE') then
    raise exception 'seller_commission_snapshot_mutation_privilege_present';
  end if;
end $$;
