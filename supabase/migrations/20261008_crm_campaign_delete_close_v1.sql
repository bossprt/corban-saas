-- Sales campaigns: delete a test campaign, close a finished one (owner request 08/10/2026).
--
-- A test campaign stayed on the sales board (13 leads) with no way to remove it, and the board shows every open lead
-- even of a closed campaign.
-- 1. delete_sales_campaign: admin or manager (leads.approve), typing the campaign's name to confirm. Only when no lead
--    of it became a proposal or a sale. Removes the campaign, its leads, their history, its imports and members.
--    Clients are never removed: a lead only pointed to an existing client.
-- 2. close_sales_campaign: the campaign is closed and its open leads (new, contacted, negotiating) go to Lost with the
--    reason "Campanha encerrada", each with its history event; leads in proposal or won stay as they are.
-- Both are recorded in the team history (organization_admin_events).
-- Contract: tests/security/crm-campaign-delete-close-contract.sql

alter table public.organization_admin_events drop constraint organization_admin_events_event_type_check;
alter table public.organization_admin_events add constraint organization_admin_events_event_type_check check (event_type = any (array[
  'invite_created', 'invite_revoked', 'invite_accepted', 'member_role_changed', 'member_deactivated', 'member_reactivated',
  'seller_created', 'seller_user_binding_updated', 'seller_supervision_updated', 'role_created', 'role_updated',
  'member_access_role_changed', 'member_hierarchy_changed', 'api_key_created', 'api_key_revoked', 'member_password_set',
  'sales_campaign_deleted', 'sales_campaign_closed']));

create or replace function public.delete_sales_campaign(p_org uuid, p_campaign uuid, p_confirm_name text)
returns integer language plpgsql security definer set search_path to '' as $$
declare c public.sales_campaigns%rowtype; v_leads integer;
begin
  if auth.uid() is null or p_org is null or not public.has_permission(p_org, 'leads.approve') then raise exception 'not_authorized'; end if;
  select * into c from public.sales_campaigns where organization_id = p_org and id = p_campaign for update;
  if c.id is null then raise exception 'campaign_not_found'; end if;
  if lower(btrim(coalesce(p_confirm_name, ''))) <> lower(btrim(c.name)) then raise exception 'campaign_name_mismatch'; end if;
  if exists (select 1 from public.leads l where l.campaign_id = c.id
             and (l.proposal_id is not null or l.won_at is not null or l.status in ('proposal', 'won'))) then
    raise exception 'campaign_has_sales';
  end if;
  select count(*) into v_leads from public.leads where campaign_id = c.id;
  delete from public.lead_events e using public.leads l where e.lead_id = l.id and l.campaign_id = c.id;
  delete from public.leads where campaign_id = c.id;
  delete from public.sales_campaign_imports where campaign_id = c.id;
  delete from public.sales_campaign_members where campaign_id = c.id;
  delete from public.sales_campaigns where id = c.id;
  insert into public.organization_admin_events (organization_id, actor_user_id, event_type, details)
  values (p_org, auth.uid(), 'sales_campaign_deleted', jsonb_build_object('campaign', c.name, 'leads', v_leads));
  return v_leads;
end
$$;

create or replace function public.close_sales_campaign(p_org uuid, p_campaign uuid)
returns integer language plpgsql security definer set search_path to '' as $$
declare c public.sales_campaigns%rowtype; l record; v_n integer := 0;
begin
  if auth.uid() is null or p_org is null or not public.has_permission(p_org, 'leads.approve') then raise exception 'not_authorized'; end if;
  select * into c from public.sales_campaigns where organization_id = p_org and id = p_campaign for update;
  if c.id is null then raise exception 'campaign_not_found'; end if;
  update public.sales_campaigns set status = 'closed', updated_at = now() where id = c.id;
  for l in select id, status from public.leads where campaign_id = c.id and status in ('new', 'contacted', 'negotiating') for update loop
    update public.leads set status = 'lost', lost_reason = 'Campanha encerrada', next_contact_at = null, stage_changed_at = now(), updated_at = now()
    where id = l.id;
    insert into public.lead_events (organization_id, lead_id, event_type, from_status, to_status, actor_user_id, detail)
    values (p_org, l.id, 'status_changed', l.status, 'lost', auth.uid(), jsonb_build_object('lost_reason', 'Campanha encerrada'));
    v_n := v_n + 1;
  end loop;
  insert into public.organization_admin_events (organization_id, actor_user_id, event_type, details)
  values (p_org, auth.uid(), 'sales_campaign_closed', jsonb_build_object('campaign', c.name, 'leads_closed', v_n));
  return v_n;
end
$$;

revoke all on function public.delete_sales_campaign(uuid, uuid, text) from public, anon;
revoke all on function public.close_sales_campaign(uuid, uuid) from public, anon;
grant execute on function public.delete_sales_campaign(uuid, uuid, text) to authenticated;
grant execute on function public.close_sales_campaign(uuid, uuid) to authenticated;
