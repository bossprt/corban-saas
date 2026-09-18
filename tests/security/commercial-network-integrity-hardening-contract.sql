-- Contract for commercial network integrity hardening.
do $$
begin
 if to_regprocedure('public.assert_same_organization_reference()') is null then raise exception 'same_org_guard_missing'; end if;
 if to_regprocedure('public.freeze_published_commercial_rule()') is null then raise exception 'published_freeze_missing'; end if;
 if has_function_privilege('authenticated','public.assert_same_organization_reference()','EXECUTE') then raise exception 'guard_direct_execute'; end if;
 if has_function_privilege('authenticated','public.freeze_published_commercial_rule()','EXECUTE') then raise exception 'freeze_direct_execute'; end if;
 if (select count(*) from pg_trigger where not tgisinternal and tgname like '%_same_org_guard') < 8 then raise exception 'same_org_triggers_missing'; end if;
 if not exists(select 1 from pg_trigger where not tgisinternal and tgname='channel_commission_rule_versions_freeze_published') then raise exception 'commission_freeze_trigger_missing'; end if;
 if not exists(select 1 from pg_trigger where not tgisinternal and tgname='network_split_rule_versions_freeze_published') then raise exception 'split_freeze_trigger_missing'; end if;
end $$;
