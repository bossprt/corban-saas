-- Tenant isolation fix (07/10/2026, found by tests/security/tenant-isolation-sweep.sql before the first client company).
--
-- private.caller_role_in(org) is NULL when the caller is not a member of that company. Five functions refused with
-- "caller_role_in(org) not in (...)", which is NULL (not true) for a non-member, so the refusal was skipped: an
-- administrator of another company could change company A's lead distribution, a member's "receives leads", a seller's
-- goal and a pipeline stage. save_payout_settings was already refused by its second check. The comparison now treats
-- "not a member" as no role. Only that comparison changes in each function.
-- Contract: tests/security/caller-role-null-contract.sql (and the sweep).

CREATE OR REPLACE FUNCTION public.set_lead_distribution(p_org uuid, p_distribution text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if auth.uid() is null or coalesce(private.caller_role_in(p_org), '') not in ('admin','manager') then raise exception 'not_authorized'; end if;
  if p_distribution not in ('round_robin','queue','manual') then raise exception 'invalid_distribution'; end if;
  insert into public.organization_lead_settings (organization_id, distribution, updated_by) values (p_org, p_distribution, auth.uid())
  on conflict (organization_id) do update set distribution = excluded.distribution, updated_at = now(), updated_by = auth.uid();
end
$function$

;

CREATE OR REPLACE FUNCTION public.set_member_receives_leads(p_membership_id uuid, p_receives boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_org uuid;
begin
  select organization_id into v_org from public.organization_memberships where id = p_membership_id;
  if v_org is null or auth.uid() is null or coalesce(private.caller_role_in(v_org), '') not in ('admin','manager') then raise exception 'not_authorized'; end if;
  perform set_config('corban.membership_rpc', 'on', true);
  update public.organization_memberships set receives_leads = coalesce(p_receives, false), updated_at = now() where id = p_membership_id;
  perform set_config('corban.membership_rpc', 'off', true);
end
$function$

;

CREATE OR REPLACE FUNCTION public.set_seller_goal(p_org uuid, p_user_id uuid, p_month date, p_target_amount numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if auth.uid() is null or coalesce(private.caller_role_in(p_org), '') not in ('admin','manager','supervisor') then raise exception 'not_authorized'; end if;
  if not private.can_see_owner(p_org, p_user_id) then raise exception 'not_authorized'; end if;
  if p_target_amount is null or p_target_amount < 0 or p_target_amount > 999999999999 then raise exception 'invalid_amount'; end if;
  if not exists (select 1 from public.organization_memberships m where m.organization_id = p_org and m.user_id = p_user_id and m.status = 'active') then raise exception 'membership_not_found'; end if;
  insert into public.seller_goals (organization_id, user_id, month, target_amount, updated_by)
  values (p_org, p_user_id, date_trunc('month', p_month)::date, round(p_target_amount, 2), auth.uid())
  on conflict (organization_id, user_id, month) do update set target_amount = excluded.target_amount, updated_at = now(), updated_by = auth.uid();
end
$function$

;

CREATE OR REPLACE FUNCTION public.update_operational_stage(p_stage_id uuid, p_name text, p_sort_order integer, p_sla_minutes integer, p_is_active boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s public.operational_stages%rowtype;
begin
  select * into s from public.operational_stages where id = p_stage_id for update;
  if not found or auth.uid() is null or coalesce(private.caller_role_in(s.organization_id), '') not in ('admin','manager') then raise exception 'not_authorized'; end if;
  if p_name is null or length(btrim(p_name)) not between 2 and 60 then raise exception 'invalid_stage_name'; end if;
  if p_sort_order is null or p_sort_order < 0 or p_sort_order > 10000 then raise exception 'invalid_stage_order'; end if;
  if p_sla_minutes is not null and (p_sla_minutes < 0 or p_sla_minutes > 525600) then raise exception 'invalid_stage_sla'; end if;
  if s.is_active and not coalesce(p_is_active, true) then
    if not exists (select 1 from public.operational_stages x where x.organization_id = s.organization_id and x.canonical_state = s.canonical_state and x.is_active and x.id <> s.id) then
      raise exception 'last_stage_of_state';
    end if;
    if exists (select 1 from public.operational_cases c where c.organization_id = s.organization_id and c.current_stage_id = s.id) then
      raise exception 'stage_in_use';
    end if;
  end if;
  update public.operational_stages
  set name = btrim(p_name), sort_order = p_sort_order, sla_minutes = p_sla_minutes, is_active = coalesce(p_is_active, true)
  where id = s.id;
end
$function$

;

CREATE OR REPLACE FUNCTION public.save_payout_settings(p_org uuid, p_default_model text, p_closing_frequency text, p_debt_limit_pct numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_old text;
begin
  if auth.uid() is null or coalesce(private.caller_role_in(p_org), '') not in ('admin','manager') or not public.has_permission(p_org, 'repasse.edit') then raise exception 'not_authorized'; end if;
  select default_model into v_old from public.payout_settings where organization_id = p_org;
  perform set_config('corban.payout_rpc', 'on', true);
  -- Changing the company default never moves accounts that already have history: they keep the model they had.
  if coalesce(v_old, 'closing') is distinct from p_default_model then
    update public.payout_accounts a set model = coalesce(v_old, 'closing')
    where a.organization_id = p_org and a.model is null and exists (select 1 from public.payout_entries e where e.account_id = a.id);
  end if;
  insert into public.payout_settings (organization_id, default_model, closing_frequency, debt_limit_pct, updated_by)
  values (p_org, p_default_model, p_closing_frequency, p_debt_limit_pct, auth.uid())
  on conflict (organization_id) do update
  set default_model = excluded.default_model, closing_frequency = excluded.closing_frequency, debt_limit_pct = excluded.debt_limit_pct,
      updated_by = auth.uid(), updated_at = now();
  perform set_config('corban.payout_rpc', 'off', true);
end
$function$

;
