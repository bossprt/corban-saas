-- Seller full profile + payout readiness V1 contract
do $$
declare def text;
begin
  if to_regclass('public.seller_profiles') is null then raise exception 'seller_profiles_missing'; end if;
  if to_regclass('public.seller_addresses') is null then raise exception 'seller_addresses_missing'; end if;
  if to_regclass('public.seller_payment_accounts') is null then raise exception 'seller_payment_accounts_missing'; end if;
  if to_regclass('public.seller_certifications') is null then raise exception 'seller_certifications_missing'; end if;

  if not exists(
    select 1 from pg_indexes where schemaname='public'
      and indexname='seller_payment_accounts_one_current'
  ) then raise exception 'seller_payment_account_version_guard_missing'; end if;

  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='set_seller_payment_account';
  if def is null
     or position('valid_until=now()' in replace(def,' ',''))=0
     or position('is_current=false' in replace(def,' ',''))=0 then
    raise exception 'seller_payment_history_not_versioned';
  end if;

  if not exists(
    select 1 from pg_policies
    where schemaname='public' and tablename='seller_payment_accounts'
      and policyname='seller_payment_accounts_select_scoped'
      and qual ilike '%can_view_seller_payment%'
  ) then raise exception 'seller_payment_rls_missing'; end if;

  if has_function_privilege('anon','public.set_seller_payment_account(uuid,uuid,text,text,text,text,text,text,text,text)','EXECUTE') then
    raise exception 'anon_can_change_seller_payment';
  end if;
end $$;
