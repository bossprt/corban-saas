create extension if not exists btree_gist with schema extensions;
--
-- PostgreSQL database dump
--


-- Dumped from database version 17.6
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA IF NOT EXISTS public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: accept_organization_invitations(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.accept_organization_invitations(p_user_id uuid, p_email text) RETURNS TABLE(organization_id uuid, role text, outcome text)
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_email text:=lower(btrim(coalesce(p_email,'')));
  i public.organization_invitations%rowtype;
  m public.organization_memberships%rowtype;
  v_out text;
begin
  if p_user_id is null or v_email='' then raise exception 'invalid_identity'; end if;

  perform set_config('corban.membership_rpc','on',true);
  update public.organization_invitations x
  set status='expired',resolved_at=now()
  where x.email=v_email and x.status='pending' and x.expires_at<=now();

  for i in
    select * from public.organization_invitations x
    where x.email=v_email and x.status='pending'
    order by x.created_at
    for update
  loop
    select * into m
    from public.organization_memberships mm
    where mm.organization_id=i.organization_id and mm.user_id=p_user_id
    for update;

    if not found then
      insert into public.organization_memberships(organization_id,user_id,role,status)
      values(i.organization_id,p_user_id,i.role,'active');
      v_out:='joined';
    elsif m.status='active' then
      v_out:='already_member';
    else
      update public.organization_memberships
      set role=i.role,status='active',updated_at=now()
      where id=m.id;
      v_out:='reactivated';
    end if;

    if i.seller_id is not null then
      if i.role <> 'agent' then raise exception 'seller_invitation_must_be_agent'; end if;
      if m.id is not null and m.status='active' and m.role<>'agent' then
        raise exception 'seller_access_requires_agent_role';
      end if;
      if exists(
        select 1 from public.commercial_sellers s
        where s.organization_id=i.organization_id
          and s.id=i.seller_id
          and s.user_id is not null
          and s.user_id<>p_user_id
      ) then raise exception 'seller_already_bound_to_other_user'; end if;

      perform set_config('corban.seller_access_rpc','on',true);
      update public.commercial_sellers s
      set user_id=p_user_id,updated_at=now()
      where s.organization_id=i.organization_id
        and s.id=i.seller_id;
      perform set_config('corban.seller_access_rpc','off',true);
    end if;

    update public.organization_invitations
    set status='accepted',resolved_at=now(),accepted_user_id=p_user_id
    where id=i.id;

    insert into public.organization_admin_events(
      organization_id,actor_user_id,event_type,target_user_id,target_email,details
    ) values(
      i.organization_id,p_user_id,'invite_accepted',p_user_id,v_email,
      jsonb_build_object(
        'role',i.role,
        'outcome',v_out,
        'invitation_id',i.id,
        'seller_id',i.seller_id
      )
    );

    organization_id:=i.organization_id;
    role:=i.role;
    outcome:=v_out;
    return next;
  end loop;

  perform set_config('corban.membership_rpc','off',true);
end
$$;


--
-- Name: ai_credit_balance(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ai_credit_balance(p_organization uuid) RETURNS numeric
    LANGUAGE plpgsql STABLE
    SET search_path TO ''
    AS $$
begin
 if auth.uid() is null or p_organization is null or not public.has_active_organization_role(p_organization,array['admin','manager','supervisor']) then raise exception 'not_authorized'; end if;
 return coalesce((select sum(l.credits) from public.ai_credit_ledger l where l.organization_id=p_organization),0);
end $$;


--
-- Name: apply_approved_import_match(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apply_approved_import_match(p_decision_id uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
 v_org uuid; v_user uuid:=auth.uid(); v_decision public.import_decisions%rowtype;
 v_candidate public.import_match_candidates%rowtype; v_row record;
 v_applied uuid; v_proposal_identity uuid; v_table_identity uuid; v_existing_target uuid; v_latest uuid;
begin
 select * into v_decision from public.import_decisions where id=p_decision_id;
 if not found or v_decision.decision<>'approve' or v_decision.candidate_id is null then raise exception 'approved_decision_required'; end if;
 v_org:=v_decision.organization_id;
 if not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'approved_decision_required'; end if;
 select id into v_latest from public.import_decisions where organization_id=v_org and candidate_id=v_decision.candidate_id order by decided_at desc,id desc limit 1;
 if v_latest is distinct from p_decision_id then raise exception 'superseded_decision'; end if;
 select id into v_applied from public.import_applied_decisions where organization_id=v_org and decision_id=p_decision_id;
 if v_applied is not null then return v_applied; end if;
 select * into v_candidate from public.import_match_candidates where id=v_decision.candidate_id and organization_id=v_org and normalized_row_id=v_decision.normalized_row_id;
 if not found or v_candidate.match_strength not in ('exact','strong') then raise exception 'strong_match_required'; end if;
 select id,bank_key,external_proposal_number,external_table_code,external_table_name into v_row from public.import_normalized_rows where id=v_decision.normalized_row_id and organization_id=v_org;
 if not found then raise exception 'normalized_row_missing'; end if;
 if v_candidate.proposal_id is not null then
  if not exists(select 1 from public.proposals_v2 where id=v_candidate.proposal_id and organization_id=v_org) then raise exception 'proposal_tenant_mismatch'; end if;
  if v_candidate.channel_id is not null and not exists(select 1 from public.commercial_channels where id=v_candidate.channel_id and organization_id=v_org) then raise exception 'channel_tenant_mismatch'; end if;
  if v_row.external_proposal_number is null or v_row.bank_key is null then raise exception 'proposal_identity_incomplete'; end if;
  select id,proposal_id into v_proposal_identity,v_existing_target from public.proposal_external_identities where organization_id=v_org and lower(institution_key)=lower(v_row.bank_key) and external_proposal_number=v_row.external_proposal_number;
  if v_proposal_identity is not null and v_existing_target is distinct from v_candidate.proposal_id then raise exception 'proposal_identity_conflict'; end if;
  if v_proposal_identity is null then
   insert into public.proposal_external_identities(organization_id,proposal_id,institution_key,external_proposal_number,channel_id,source,metadata)
   values(v_org,v_candidate.proposal_id,lower(v_row.bank_key),v_row.external_proposal_number,v_candidate.channel_id,'import_reconciliation',jsonb_build_object('decision_id',p_decision_id,'normalized_row_id',v_row.id))
   returning id into v_proposal_identity;
  end if;
 end if;
 if v_candidate.product_table_id is not null then
  if not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'table_identity_requires_manager'; end if;
  if not exists(select 1 from public.product_tables where id=v_candidate.product_table_id and organization_id=v_org) then raise exception 'table_tenant_mismatch'; end if;
  if v_candidate.channel_id is null or not exists(select 1 from public.commercial_channels where id=v_candidate.channel_id and organization_id=v_org) then raise exception 'channel_tenant_mismatch'; end if;
  if v_row.external_table_code is null then raise exception 'table_identity_incomplete'; end if;
  select id,product_table_id into v_table_identity,v_existing_target from public.product_table_external_identities where organization_id=v_org and channel_id=v_candidate.channel_id and external_code=v_row.external_table_code;
  if v_table_identity is not null and v_existing_target is distinct from v_candidate.product_table_id then raise exception 'table_identity_conflict'; end if;
  if v_table_identity is null then
   insert into public.product_table_external_identities(organization_id,product_table_id,channel_id,external_code,external_name,effective_from)
   values(v_org,v_candidate.product_table_id,v_candidate.channel_id,v_row.external_table_code,v_row.external_table_name,now()) returning id into v_table_identity;
  end if;
 end if;
 if v_proposal_identity is null and v_table_identity is null then raise exception 'canonical_target_required'; end if;
 insert into public.import_applied_decisions(organization_id,decision_id,proposal_external_identity_id,table_external_identity_id,applied_by)
 values(v_org,p_decision_id,v_proposal_identity,v_table_identity,v_user) returning id into v_applied;
 return v_applied;
end $$;


--
-- Name: apply_smart_commercial_remittance(uuid, text, uuid, uuid, jsonb, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apply_smart_commercial_remittance(p_organization uuid, p_production_origin text, p_provider uuid, p_policy_version uuid, p_rows jsonb, p_mode text, p_remittance_effective_from timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_import jsonb;
  rowj jsonb;
  v_bank_name text;
  v_agreement_name text;
  v_first_bank text;
  v_first_agreement text;
  v_scope_route uuid;
  v_scope_bank uuid;
  v_scope_agreement uuid;
  v_table public.product_tables%rowtype;
  v_version public.product_table_versions%rowtype;
  v_touched uuid[]:='{}';
  v_names text[]:='{}';
  v_published integer:=0;
  v_retired integer:=0;
  v_name text;
begin
  if auth.uid() is null or p_organization is null
     or not public.has_active_organization_role(p_organization,array['admin','manager'])
  then raise exception 'not_authorized'; end if;
  if p_mode not in ('partial','complete') then raise exception 'invalid_remittance_mode'; end if;
  if p_mode='complete' and p_remittance_effective_from is null then raise exception 'remittance_effective_from_required'; end if;
  if p_rows is null or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)<1 then raise exception 'invalid_smart_import_rows'; end if;

  -- Complete remittances are intentionally scoped to one Institution + Agreement.
  for rowj in select * from jsonb_array_elements(p_rows) loop
    v_bank_name:=lower(btrim(rowj->>'bank_name'));
    v_agreement_name:=lower(btrim(rowj->>'agreement_name'));
    if v_first_bank is null then
      v_first_bank:=v_bank_name;
      v_first_agreement:=v_agreement_name;
    elsif p_mode='complete' and (v_bank_name<>v_first_bank or v_agreement_name<>v_first_agreement) then
      raise exception 'complete_remittance_requires_single_scope';
    end if;
    v_name:=lower(btrim(rowj->>'table_name'));
    if not (v_name=any(v_names)) then v_names:=v_names||v_name; end if;
  end loop;

  v_import:=public.import_smart_commercial_rows(
    p_organization,p_production_origin,p_provider,p_policy_version,p_rows
  );

  -- Identify every table touched by this file and publish its resulting draft atomically.
  for v_table in
    select distinct pt.*
    from public.product_tables pt
    join public.organization_product_routes r on r.id=pt.route_id
    join public.organization_banks b on b.id=r.org_bank_id
    join public.organization_agreements a on a.id=r.org_agreement_id
    where pt.organization_id=p_organization
      and lower(btrim(pt.name))=any(v_names)
      and exists(
        select 1
        from jsonb_array_elements(p_rows) j
        where lower(btrim(j->>'table_name'))=lower(btrim(pt.name))
          and lower(btrim(j->>'bank_name'))=lower(btrim(b.name))
          and lower(btrim(j->>'agreement_name'))=lower(btrim(a.name))
      )
  loop
    select * into v_version
    from public.product_table_versions x
    where x.organization_id=p_organization
      and x.product_table_id=v_table.id
      and x.status='draft'
    order by x.version desc
    limit 1;

    if v_version.id is null then raise exception 'imported_draft_version_not_found'; end if;

    if p_mode='complete' then
      update public.product_table_versions
      set metadata=metadata||jsonb_build_object(
        'remittance_mode','complete',
        'remittance_effective_from',p_remittance_effective_from
      )
      where id=v_version.id;
    else
      update public.product_table_versions
      set metadata=metadata||jsonb_build_object('remittance_mode','partial')
      where id=v_version.id;
    end if;

    perform public.publish_product_table_version(v_version.id);
    v_touched:=v_touched||v_table.id;
    v_published:=v_published+1;
  end loop;

  if p_mode='complete' then
    select r.id,r.org_bank_id,r.org_agreement_id
    into v_scope_route,v_scope_bank,v_scope_agreement
    from public.organization_product_routes r
    join public.organization_banks b on b.id=r.org_bank_id
    join public.organization_agreements a on a.id=r.org_agreement_id
    where r.organization_id=p_organization
      and lower(btrim(b.name))=v_first_bank
      and lower(btrim(a.name))=v_first_agreement
      and ((p_provider is null and r.org_provider_id is null) or r.org_provider_id=p_provider)
      and r.production_origin=p_production_origin
    limit 1;

    if v_scope_route is null then raise exception 'complete_remittance_scope_not_found'; end if;

    perform set_config('corban.catalog_rpc','on',true);

    -- Any table absent from a complete remittance stops being available at the cutover.
    update public.product_table_versions x
    set effective_until=p_remittance_effective_from
    from public.product_tables pt
    where pt.id=x.product_table_id
      and pt.organization_id=p_organization
      and pt.route_id=v_scope_route
      and not (pt.id=any(v_touched))
      and x.status='published'
      and coalesce(x.effective_from,x.published_at,x.created_at)<p_remittance_effective_from
      and (x.effective_until is null or x.effective_until>p_remittance_effective_from);
    get diagnostics v_retired=row_count;

    -- A scheduled future version of an absent table must not resurrect it after the cutover.
    update public.product_table_versions x
    set status='superseded',
        effective_until=coalesce(x.effective_until,p_remittance_effective_from)
    from public.product_tables pt
    where pt.id=x.product_table_id
      and pt.organization_id=p_organization
      and pt.route_id=v_scope_route
      and not (pt.id=any(v_touched))
      and x.status='published'
      and coalesce(x.effective_from,x.published_at,x.created_at)>=p_remittance_effective_from;

    perform set_config('corban.catalog_rpc','off',true);
  end if;

  return v_import||jsonb_build_object(
    'published_versions',v_published,
    'retired_absent_versions',v_retired,
    'remittance_mode',p_mode
  );
exception when others then
  perform set_config('corban.catalog_rpc','off',true);
  raise;
end
$$;


--
-- Name: assert_same_organization_reference(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assert_same_organization_reference() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare ref_org uuid;
begin
 if tg_table_name='commercial_relationships' then
  select organization_id into ref_org from public.commercial_entities where id=new.upstream_entity_id;
  if ref_org is distinct from new.organization_id then raise exception 'cross_tenant_upstream_entity'; end if;
  select organization_id into ref_org from public.commercial_entities where id=new.downstream_entity_id;
  if ref_org is distinct from new.organization_id then raise exception 'cross_tenant_downstream_entity'; end if;
 elsif tg_table_name='commercial_channels' then
  if new.relationship_id is not null then select organization_id into ref_org from public.commercial_relationships where id=new.relationship_id; if ref_org is distinct from new.organization_id then raise exception 'cross_tenant_relationship'; end if; end if;
  if new.payer_entity_id is not null then select organization_id into ref_org from public.commercial_entities where id=new.payer_entity_id; if ref_org is distinct from new.organization_id then raise exception 'cross_tenant_payer'; end if; end if;
 elsif tg_table_name='product_table_external_identities' then
  select organization_id into ref_org from public.product_tables where id=new.product_table_id; if ref_org is distinct from new.organization_id then raise exception 'cross_tenant_product_table'; end if;
  select organization_id into ref_org from public.commercial_channels where id=new.channel_id; if ref_org is distinct from new.organization_id then raise exception 'cross_tenant_channel'; end if;
 elsif tg_table_name='proposal_external_identities' then
  select organization_id into ref_org from public.proposals_v2 where id=new.proposal_id; if ref_org is distinct from new.organization_id then raise exception 'cross_tenant_proposal'; end if;
  if new.channel_id is not null then select organization_id into ref_org from public.commercial_channels where id=new.channel_id; if ref_org is distinct from new.organization_id then raise exception 'cross_tenant_channel'; end if; end if;
 elsif tg_table_name='proposal_commercial_snapshots' then
  select organization_id into ref_org from public.proposals_v2 where id=new.proposal_id; if ref_org is distinct from new.organization_id then raise exception 'cross_tenant_proposal'; end if;
  select organization_id into ref_org from public.commercial_channels where id=new.channel_id; if ref_org is distinct from new.organization_id then raise exception 'cross_tenant_channel'; end if;
 elsif tg_table_name='channel_commission_rule_versions' then
  select organization_id into ref_org from public.commercial_channels where id=new.channel_id; if ref_org is distinct from new.organization_id then raise exception 'cross_tenant_channel'; end if;
  select organization_id into ref_org from public.product_tables where id=new.product_table_id; if ref_org is distinct from new.organization_id then raise exception 'cross_tenant_product_table'; end if;
 elsif tg_table_name='commission_rule_components' then
  select organization_id into ref_org from public.channel_commission_rule_versions where id=new.rule_version_id; if ref_org is distinct from new.organization_id then raise exception 'cross_tenant_commission_rule'; end if;
 elsif tg_table_name='network_split_rule_versions' then
  select organization_id into ref_org from public.commercial_relationships where id=new.relationship_id; if ref_org is distinct from new.organization_id then raise exception 'cross_tenant_relationship'; end if;
 end if;
 return new;
end $$;


--
-- Name: assign_attention_item(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assign_attention_item(p_item uuid, p_assignee uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare i public.operational_attention_items%rowtype;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into i from public.operational_attention_items x where x.id=p_item for update;
 if not found then raise exception 'item_not_found'; end if;
 if not public.has_active_organization_role(i.organization_id,array['admin','manager']) then raise exception 'not_authorized'; end if;
 if i.status='resolved' then raise exception 'item_already_resolved'; end if;
 if p_assignee is not null and not exists(select 1 from public.organization_memberships m where m.organization_id=i.organization_id and m.user_id=p_assignee and m.status='active') then raise exception 'assignee_not_member'; end if;
 perform set_config('corban.attention_rpc','on',true);
 update public.operational_attention_items set assigned_to=p_assignee where id=i.id;
 insert into public.operational_attention_events(organization_id,item_id,event,actor,detail) values(i.organization_id,i.id,'assigned',auth.uid(),jsonb_build_object('assignee',p_assignee));
 perform set_config('corban.attention_rpc','off',true);
 return i.id;
end $$;


--
-- Name: assign_proposal_seller(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assign_proposal_seller(p_proposal_id uuid, p_seller_id uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_org uuid;
  v_seller public.commercial_sellers%rowtype;
  v_attr jsonb;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;

  select p.organization_id,p.attribution_snapshot
    into v_org,v_attr
  from public.proposals_v2 p
  where p.id=p_proposal_id
    and p.status='draft'
    and public.is_active_organization_member(p.organization_id)
  for update;

  if v_org is null then raise exception 'draft_proposal_not_found_or_forbidden'; end if;
  if not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then
    raise exception 'forbidden';
  end if;
  if exists(
    select 1 from public.proposal_commercial_snapshots s
    where s.proposal_id=p_proposal_id and s.organization_id=v_org
  ) then
    raise exception 'proposal_commercial_route_already_frozen';
  end if;

  if p_seller_id is not null then
    select * into v_seller
    from public.commercial_sellers s
    where s.id=p_seller_id and s.organization_id=v_org and s.is_active;
    if not found then raise exception 'active_seller_not_found'; end if;

    v_attr:=coalesce(v_attr,'{}'::jsonb) ||
      jsonb_build_object('seller',jsonb_build_object(
        'id',v_seller.id,
        'name',v_seller.name,
        'category',v_seller.seller_category,
        'seller_group_id',v_seller.seller_group_id,
        'assigned_at',now()
      ));
  else
    v_attr:=coalesce(v_attr,'{}'::jsonb)-'seller';
  end if;

  perform set_config('corban.proposal_seller_rpc','on',true);
  update public.proposals_v2
     set seller_id=p_seller_id,
         attribution_snapshot=v_attr,
         updated_at=now()
   where id=p_proposal_id and organization_id=v_org;
  perform set_config('corban.proposal_seller_rpc','off',true);

  return p_proposal_id;
end
$$;


--
-- Name: attach_import_batch_adapter(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.attach_import_batch_adapter(p_batch_id uuid, p_adapter_key text) RETURNS void
    LANGUAGE sql
    SET search_path TO ''
    AS $$ select private.attach_import_batch_adapter(p_batch_id,p_adapter_key); $$;


--
-- Name: bootstrap_organization_admin(uuid, uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.bootstrap_organization_admin(p_platform_actor_user_id uuid, p_user_id uuid, p_organization_name text, p_organization_document text, p_plan_type text DEFAULT 'founder'::text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare v_org_id uuid;
begin
  if not exists (select 1 from public.platform_administrators pa where pa.user_id=p_platform_actor_user_id and pa.status='active')
    then raise exception 'active_platform_admin_required'; end if;
  if p_user_id is null then raise exception 'user_id_required'; end if;
  if nullif(btrim(p_organization_name),'') is null then raise exception 'organization_name_required'; end if;
  if nullif(btrim(p_organization_document),'') is null then raise exception 'organization_document_required'; end if;
  if not exists (select 1 from auth.users u where u.id=p_user_id) then raise exception 'auth_user_not_found'; end if;
  if exists (select 1 from public.organization_memberships m where m.user_id=p_user_id and m.status='active')
    then raise exception 'user_already_has_active_membership'; end if;
  insert into public.organizations(name,document,plan_type,is_active)
  values(btrim(p_organization_name),btrim(p_organization_document),p_plan_type,true) returning id into v_org_id;
  insert into public.organization_memberships(organization_id,user_id,role,status)
  values(v_org_id,p_user_id,'admin','active');
  insert into public.profiles(id,organization_id,full_name,role)
  select p_user_id,v_org_id,coalesce(nullif(btrim(u.raw_user_meta_data->>'full_name'),''),u.email,'Admin'),'admin'
  from auth.users u where u.id=p_user_id
  on conflict(id) do update set organization_id=excluded.organization_id,role='admin';
  insert into public.platform_admin_audit_events(actor_user_id,action,target_user_id,organization_id,metadata)
  values(p_platform_actor_user_id,'organization.bootstrap_admin',p_user_id,v_org_id,jsonb_build_object('plan_type',p_plan_type));
  return v_org_id;
end;
$$;


--
-- Name: can_manage_member_role(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_manage_member_role(p_actor text, p_target_current text, p_target_new text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
 select case
  when p_actor='admin' then p_target_new in ('admin','manager','supervisor','agent') and (p_target_current is null or p_target_current in ('admin','manager','supervisor','agent'))
  when p_actor='manager' then p_target_new in ('supervisor','agent') and (p_target_current is null or p_target_current in ('supervisor','agent'))
  else false end
$$;


--
-- Name: can_view_seller_commission(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_view_seller_commission(p_organization_id uuid, p_seller_id uuid) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
  select
    public.has_active_organization_role(p_organization_id,array['admin','manager'])
    or exists(
      select 1
      from public.commercial_sellers s
      join public.organization_memberships m
        on m.organization_id=s.organization_id
       and m.user_id=s.user_id
       and m.status='active'
      where s.organization_id=p_organization_id
        and s.id=p_seller_id
        and s.is_active
        and s.user_id=auth.uid()
    )
    or (
      public.has_active_organization_role(p_organization_id,array['supervisor'])
      and exists(
        select 1 from public.seller_supervisions ss
        where ss.organization_id=p_organization_id
          and ss.seller_id=p_seller_id
          and ss.supervisor_user_id=auth.uid()
          and ss.is_active
      )
    )
$$;


--
-- Name: can_view_seller_payment(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_view_seller_payment(p_org uuid, p_seller uuid) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
  select
    public.has_active_organization_role(p_org,array['admin','manager'])
    or exists(
      select 1 from public.commercial_sellers s
      where s.organization_id=p_org and s.id=p_seller
        and s.user_id=auth.uid() and s.is_active
    )
$$;


--
-- Name: can_view_seller_profile(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_view_seller_profile(p_org uuid, p_seller uuid) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
  select
    public.has_active_organization_role(p_org,array['admin','manager'])
    or exists(
      select 1 from public.commercial_sellers s
      where s.organization_id=p_org and s.id=p_seller
        and s.user_id=auth.uid() and s.is_active
    )
    or (
      public.has_active_organization_role(p_org,array['supervisor'])
      and exists(
        select 1 from public.seller_supervisions ss
        where ss.organization_id=p_org
          and ss.seller_id=p_seller
          and ss.supervisor_user_id=auth.uid()
          and ss.is_active
      )
    )
$$;


--
-- Name: cancel_integration_run(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cancel_integration_run(p_org uuid, p_run uuid, p_actor uuid) RETURNS text
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_run public.integration_runs%rowtype;
begin
 if p_actor is null or not exists(select 1 from public.organization_memberships m where m.organization_id=p_org and m.user_id=p_actor and m.status='active' and m.role in ('admin','manager')) then raise exception 'actor_not_authorized'; end if;
 select * into v_run from public.integration_runs r where r.id=p_run and r.organization_id=p_org for update;
 if not found then raise exception 'run_not_found'; end if;
 if v_run.status not in ('queued','failed') then raise exception 'illegal_integration_run_transition: % -> cancelled',v_run.status; end if;
 perform set_config('corban.integration_run_rpc','on',true);
 update public.integration_runs set status='cancelled',next_attempt_at=null where id=p_run;
 perform set_config('corban.integration_run_rpc','off',true);
 return 'cancelled';
end $$;


--
-- Name: claim_integration_run(uuid, uuid, text, text, uuid, integer, integer, jsonb, text, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_integration_run(p_org uuid, p_binding uuid, p_capability text, p_fingerprint text, p_actor uuid, p_max_attempts integer, p_lease_seconds integer, p_request jsonb, p_correlation text, p_now timestamp with time zone DEFAULT now(), p_adapter_key text DEFAULT NULL::text) RETURNS TABLE(run_id uuid, outcome text, claim_token uuid, attempt_count integer, status text, next_attempt_at timestamp with time zone, external_request_id text, error_code text)
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
declare v_adapter uuid;v_adapter_key text;v_run public.integration_runs%rowtype;v_token uuid:=gen_random_uuid();v_id uuid;
begin
 if p_lease_seconds is null or p_lease_seconds not between 5 and 3600 then raise exception 'invalid_lease'; end if;
 if p_max_attempts is null or p_max_attempts not between 1 and 10 then raise exception 'invalid_max_attempts'; end if;
 if p_fingerprint !~ '^[0-9a-f]{64}$' then raise exception 'invalid_fingerprint'; end if;
 if p_actor is null or not exists(select 1 from public.organization_memberships m where m.organization_id=p_org and m.user_id=p_actor and m.status='active' and m.role in ('admin','manager','supervisor')) then raise exception 'actor_not_authorized'; end if;
 select b.adapter_id,a.adapter_key into v_adapter,v_adapter_key from public.integration_source_bindings b join public.integration_adapters a on a.id=b.adapter_id where b.id=p_binding and b.organization_id=p_org and b.enabled;
 if v_adapter is null then raise exception 'binding_not_found'; end if;
 if p_adapter_key is not null and p_adapter_key<>v_adapter_key then raise exception 'adapter_mismatch'; end if;
 perform set_config('corban.integration_run_rpc','on',true);
 insert into public.integration_runs(organization_id,binding_id,adapter_id,capability,status,request_fingerprint,max_attempts,metadata,created_by,correlation_id)
 values(p_org,p_binding,v_adapter,p_capability,'queued',p_fingerprint,p_max_attempts,jsonb_build_object('request',coalesce(p_request,'{}'::jsonb)),p_actor,left(p_correlation,128))
 on conflict(organization_id,binding_id,request_fingerprint) do nothing;
 select * into v_run from public.integration_runs r where r.organization_id=p_org and r.binding_id=p_binding and r.request_fingerprint=p_fingerprint for update;
 v_id:=v_run.id;
 if v_run.status='succeeded' then perform set_config('corban.integration_run_rpc','off',true); return query select v_id,'replayed',null::uuid,v_run.attempt_count,v_run.status,null::timestamptz,v_run.external_request_id,null::text; return; end if;
 if v_run.status='cancelled' then perform set_config('corban.integration_run_rpc','off',true); return query select v_id,'cancelled',null::uuid,v_run.attempt_count,v_run.status,null::timestamptz,null::text,null::text; return; end if;
 if v_run.status='failed' and (v_run.terminal or v_run.attempt_count>=v_run.max_attempts) then perform set_config('corban.integration_run_rpc','off',true); return query select v_id,'failed_terminal',null::uuid,v_run.attempt_count,v_run.status,null::timestamptz,null::text,v_run.error_code; return; end if;
 if v_run.status='failed' and v_run.next_attempt_at is not null and p_now<v_run.next_attempt_at then perform set_config('corban.integration_run_rpc','off',true); return query select v_id,'retry_scheduled',null::uuid,v_run.attempt_count,v_run.status,v_run.next_attempt_at,null::text,v_run.error_code; return; end if;
 if v_run.status='running' and v_run.lease_expires_at>p_now then perform set_config('corban.integration_run_rpc','off',true); return query select v_id,'in_progress',null::uuid,v_run.attempt_count,v_run.status,null::timestamptz,null::text,null::text; return; end if;
 if v_run.status='running' then
  -- the previous worker never reported: keep a trace of that attempt before the row is reused
  insert into public.integration_run_artifacts(organization_id,run_id,artifact_kind,payload,content_sha256)
  values(p_org,v_id,'diagnostic',jsonb_build_object('attempt',v_run.attempt_count,'outcome','lease_expired','at',p_now),md5(v_id::text||':lease:'||v_run.attempt_count::text))
  on conflict do nothing; -- (no conflict target: the OUT column run_id of this function would make one ambiguous)
 end if;
 if v_run.status='running' and v_run.attempt_count>=v_run.max_attempts then
  update public.integration_runs set status='failed',terminal=true,error_code='terminal:lease_expired_attempts_exhausted',error_message='worker lease expired on the last attempt',next_attempt_at=null where id=v_id;
  perform set_config('corban.integration_run_rpc','off',true);
  return query select v_id,'failed_terminal',null::uuid,v_run.attempt_count,'failed'::text,null::timestamptz,null::text,'terminal:lease_expired_attempts_exhausted'; return;
 end if;
 update public.integration_runs set status='running',attempt_count=v_run.attempt_count+1,claim_token=v_token,lease_expires_at=p_now+make_interval(secs=>p_lease_seconds),started_at=p_now,next_attempt_at=null,error_code=null,error_message=null,terminal=false where id=v_id;
 perform set_config('corban.integration_run_rpc','off',true);
 return query select v_id,case when v_run.status='running' then 'takeover' else 'claimed' end,v_token,v_run.attempt_count+1,'running'::text,null::timestamptz,null::text,null::text;
end $_$;


--
-- Name: close_simulation(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.close_simulation(p_simulation_id uuid, p_target_status text) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_sim public.simulations%rowtype;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if p_target_status not in ('cancelled','expired') then raise exception 'invalid_target_status'; end if;

  select s.* into v_sim
  from public.simulations s
  where s.id=p_simulation_id
    and public.is_active_organization_member(s.organization_id)
  for update;

  if v_sim.id is null then raise exception 'simulation_not_found_or_forbidden'; end if;
  if not public.has_active_organization_role(v_sim.organization_id,array['admin','manager','supervisor']) then
    raise exception 'forbidden';
  end if;
  if v_sim.status<>'calculated' then raise exception 'simulation_not_closable'; end if;
  if exists(
    select 1 from public.proposals_v2 p
    where p.organization_id=v_sim.organization_id
      and p.simulation_id=v_sim.id
  ) then raise exception 'simulation_has_proposal'; end if;

  perform set_config('corban.simulation_rpc','on',true);
  update public.simulations
  set status=p_target_status,updated_at=now()
  where organization_id=v_sim.organization_id and id=v_sim.id;
  perform set_config('corban.simulation_rpc','off',true);

  return v_sim.id;
end
$$;


--
-- Name: complete_integration_run(uuid, uuid, uuid, text, jsonb, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.complete_integration_run(p_org uuid, p_run uuid, p_token uuid, p_external_request_id text, p_artifacts jsonb, p_now timestamp with time zone DEFAULT now()) RETURNS text
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_run public.integration_runs%rowtype;a jsonb;
begin
 select * into v_run from public.integration_runs r where r.id=p_run and r.organization_id=p_org for update;
 if not found then raise exception 'run_not_found'; end if;
 if v_run.status='succeeded' then return case when v_run.external_request_id is not distinct from p_external_request_id then 'duplicate_ignored' else 'conflicting_duplicate' end; end if;
 if v_run.status<>'running' or v_run.claim_token is distinct from p_token then return 'lease_lost'; end if;
 if jsonb_typeof(p_artifacts)<>'array' or jsonb_array_length(p_artifacts)>20 then raise exception 'invalid_artifacts'; end if;
 perform set_config('corban.integration_run_rpc','on',true);
 for a in select value from jsonb_array_elements(p_artifacts) loop
  insert into public.integration_run_artifacts(organization_id,run_id,artifact_kind,payload,content_sha256)
  values(p_org,p_run,a->>'kind',coalesce(a->'payload','{}'::jsonb),nullif(a->>'sha256',''))
  on conflict(run_id,artifact_kind,content_sha256) where content_sha256 is not null do nothing;
 end loop;
 update public.integration_runs set status='succeeded',external_request_id=left(p_external_request_id,200),error_code=null,error_message=null,terminal=false where id=p_run;
 perform set_config('corban.integration_run_rpc','off',true);
 return 'succeeded';
end $$;


--
-- Name: confirm_import_mapping(uuid, text, text, jsonb, jsonb, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.confirm_import_mapping(p_organization uuid, p_source_label text, p_fingerprint text, p_mapping jsonb, p_unknown jsonb, p_confidence numeric, p_provider text, p_model text) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
declare k text; v_ver integer; v_id uuid; v_allowed text[]:=array['bank','agreement','product_table','contract_type','term','coefficient','rate','received_commission','valid_from','valid_until','production_origin'];
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 if p_organization is null or not public.has_active_organization_role(p_organization,array['admin','manager','supervisor']) then raise exception 'not_authorized'; end if;
 if p_source_label is null or length(btrim(p_source_label)) not between 1 and 120 then raise exception 'invalid_mapping'; end if;
 if p_fingerprint is null or p_fingerprint !~ '^[0-9a-f]{64}$' then raise exception 'invalid_mapping'; end if;
 if p_mapping is null or jsonb_typeof(p_mapping)<>'object' or p_mapping='{}'::jsonb then raise exception 'invalid_mapping'; end if;
 for k in select jsonb_object_keys(p_mapping) loop
  if k<>all(v_allowed) or jsonb_typeof(p_mapping->k)<>'string' or length(p_mapping->>k) not between 1 and 120 then raise exception 'invalid_mapping'; end if;
 end loop;
 if p_unknown is null or jsonb_typeof(p_unknown)<>'array' or jsonb_array_length(p_unknown)>200 then raise exception 'invalid_mapping'; end if;
 if exists(select 1 from jsonb_array_elements(p_unknown) u where jsonb_typeof(u)<>'string' or length(u #>> '{}')>120) then raise exception 'invalid_mapping'; end if;
 if p_confidence is not null and (p_confidence<0 or p_confidence>1) then raise exception 'invalid_mapping'; end if;
 perform set_config('corban.mapping_rpc','on',true);
 select coalesce(max(m.version),0)+1 into v_ver from public.import_layout_mappings m where m.organization_id=p_organization and lower(btrim(m.source_label))=lower(btrim(p_source_label)) and m.layout_fingerprint=p_fingerprint;
 update public.import_layout_mappings m set status='superseded' where m.organization_id=p_organization and lower(btrim(m.source_label))=lower(btrim(p_source_label)) and m.layout_fingerprint=p_fingerprint and m.status='confirmed';
 insert into public.import_layout_mappings(organization_id,source_label,layout_fingerprint,version,mapping,unknown_columns,confidence,provider,model,confirmed_by)
  values(p_organization,btrim(p_source_label),p_fingerprint,v_ver,p_mapping,p_unknown,p_confidence,nullif(p_provider,''),nullif(p_model,''),auth.uid()) returning id into v_id;
 perform set_config('corban.mapping_rpc','off',true);
 return v_id;
end $_$;


--
-- Name: confirm_proposal_paid_from_import(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.confirm_proposal_paid_from_import(p_decision_id uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare v_org uuid;v_batch uuid;v_candidate uuid;v_proposal uuid;v_row uuid;v_kind text;v_payload jsonb;v_semantic text;v_raw_status text;v_at timestamptz;v_id uuid;
begin
 select d.organization_id,d.batch_id,d.candidate_id into v_org,v_batch,v_candidate from public.import_decisions d where d.id=p_decision_id and d.decision='approve';
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'approved_decision_not_found_or_forbidden'; end if;
 if exists(select 1 from public.import_decisions newer where newer.candidate_id=v_candidate and newer.organization_id=v_org and newer.decided_at>(select decided_at from public.import_decisions where id=p_decision_id)) then raise exception 'superseded_decision'; end if;
 if not exists(select 1 from public.import_applied_decisions a where a.decision_id=p_decision_id and a.organization_id=v_org) then raise exception 'identity_match_must_be_applied_first'; end if;
 select c.proposal_id,c.normalized_row_id into v_proposal,v_row from public.import_match_candidates c where c.id=v_candidate and c.organization_id=v_org and c.match_strength='exact' and c.proposal_id is not null;
 if v_proposal is null then raise exception 'exact_status_proposal_match_required'; end if;
 -- replay: this exact decision was already confirmed; return its evidence (nothing is written again)
 select e.id into v_id from public.proposal_status_evidence e where e.organization_id=v_org and e.import_decision_id=p_decision_id and e.canonical_status='paid';
 if v_id is not null then return v_id; end if;
 select e.record_kind,e.normalized_payload into v_kind,v_payload from private.import_row_evidence(v_row) e;
 if v_kind is distinct from 'status' then raise exception 'exact_status_proposal_match_required'; end if;
 select s.financial_semantic into v_semantic from public.import_batches b join public.import_sources s on s.id=b.source_id and s.organization_id=b.organization_id where b.id=v_batch and b.organization_id=v_org;
 if v_semantic<>'production_report' then raise exception 'production_report_required'; end if;
 if lower(coalesce(v_payload->>'canonicalStatus',''))<>'paid' then raise exception 'paid_status_evidence_required'; end if;
 v_raw_status:=nullif(v_payload->>'rawStatus','');v_at:=nullif(v_payload->>'occurredAt','')::timestamptz;
 if v_raw_status is null or v_at is null then raise exception 'status_evidence_details_required'; end if;
 if not exists(select 1 from public.proposals_v2 where id=v_proposal and organization_id=v_org and status='approved') then raise exception 'proposal_must_be_approved'; end if;
 insert into public.proposal_status_evidence(organization_id,proposal_id,import_decision_id,canonical_status,raw_status,evidenced_at,created_by)
 values(v_org,v_proposal,p_decision_id,'paid',v_raw_status,v_at,auth.uid()) on conflict(organization_id,import_decision_id,canonical_status) do nothing returning id into v_id;
 if v_id is null then select id into v_id from public.proposal_status_evidence where organization_id=v_org and import_decision_id=p_decision_id and canonical_status='paid'; end if;
 perform set_config('corban.paid_evidence_rpc','on',true);
 update public.proposals_v2 set status='paid',updated_at=now() where id=v_proposal and organization_id=v_org;
 perform set_config('corban.paid_evidence_rpc','off',true);
 return v_id;
end $$;


--
-- Name: convert_lead_to_customer(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.convert_lead_to_customer(p_lead_id uuid, p_cpf text) RETURNS uuid
    LANGUAGE sql
    SET search_path TO ''
    AS $$
 select private.lead_write((select l.organization_id from public.leads l where l.id=p_lead_id),p_lead_id,'convert',jsonb_build_object('cpf',p_cpf))
$$;


--
-- Name: create_and_publish_commission_rule(uuid, uuid, text, numeric, numeric, numeric, text, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_and_publish_commission_rule(p_channel_id uuid, p_product_table_id uuid, p_component_type text, p_percentage numeric, p_fixed_amount numeric, p_anticipation_factor numeric, p_calculation_base text, p_effective_from timestamp with time zone, p_operation_type text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare v_org uuid;v_id uuid;v_version int;
begin
 -- tenant = the CHANNEL's organization
 select organization_id into v_org from public.commercial_channels where id=p_channel_id;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'channel_not_found'; end if;
 if not exists(select 1 from public.product_tables where id=p_product_table_id and organization_id=v_org) then raise exception 'table_not_found'; end if;
 if p_percentage is null and p_fixed_amount is null then raise exception 'component_value_required'; end if;
 if p_component_type='deferred_anticipation' and p_anticipation_factor is null then raise exception 'anticipation_factor_required'; end if;
 select coalesce(max(version),0)+1 into v_version from public.channel_commission_rule_versions where organization_id=v_org and channel_id=p_channel_id and product_table_id=p_product_table_id;
 insert into public.channel_commission_rule_versions(organization_id,channel_id,product_table_id,version,status,operation_type,effective_from,published_at)
 values(v_org,p_channel_id,p_product_table_id,v_version,'published',p_operation_type,p_effective_from,now()) returning id into v_id;
 insert into public.commission_rule_components(organization_id,rule_version_id,component_type,percentage,fixed_amount,anticipation_factor,calculation_base)
 values(v_org,v_id,p_component_type,p_percentage,p_fixed_amount,p_anticipation_factor,p_calculation_base);
 return v_id;
end $$;


--
-- Name: create_and_publish_split_rule(uuid, uuid, uuid, text, numeric, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_and_publish_split_rule(p_relationship_id uuid, p_bank_id uuid, p_product_table_id uuid, p_component_type text, p_downstream_share numeric, p_payment_flow text, p_effective_from timestamp with time zone) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare v_org uuid;v_id uuid;v_version int;
begin
 -- tenant = the RELATIONSHIP's organization
 select organization_id into v_org from public.commercial_relationships where id=p_relationship_id;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'relationship_not_found'; end if;
 if p_downstream_share<0 or p_downstream_share>1 then raise exception 'invalid_share'; end if;
 if p_product_table_id is not null and not exists(select 1 from public.product_tables where id=p_product_table_id and organization_id=v_org) then raise exception 'table_not_found'; end if;
 select coalesce(max(version),0)+1 into v_version from public.network_split_rule_versions where organization_id=v_org and relationship_id=p_relationship_id and product_table_id is not distinct from p_product_table_id and component_type is not distinct from p_component_type;
 insert into public.network_split_rule_versions(organization_id,relationship_id,bank_id,product_table_id,component_type,version,downstream_share,upstream_share,payment_flow,effective_from,status)
 values(v_org,p_relationship_id,p_bank_id,p_product_table_id,p_component_type,v_version,p_downstream_share,1-p_downstream_share,p_payment_flow,p_effective_from,'published') returning id into v_id;
 return v_id;
end $$;


--
-- Name: create_customer_with_timeline(text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_customer_with_timeline(p_full_name text, p_cpf text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_original_source text DEFAULT 'corban_os'::text) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_orgs uuid[];
begin
 select array_agg(m.organization_id) into v_orgs from public.organization_memberships m where m.user_id=(select auth.uid()) and m.status='active';
 if v_orgs is null or cardinality(v_orgs)<>1 then raise exception 'organization_required'; end if;
 return public.create_customer_with_timeline(v_orgs[1],p_full_name,p_cpf,p_phone,p_email,p_original_source);
end $$;


--
-- Name: create_customer_with_timeline(uuid, text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_customer_with_timeline(p_organization_id uuid, p_full_name text, p_cpf text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_original_source text DEFAULT 'corban_os'::text) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
declare v_customer_id uuid;
begin
 if p_organization_id is null or not public.is_active_organization_member(p_organization_id) then raise exception 'active_membership_required'; end if;
 if nullif(btrim(p_full_name),'') is null then raise exception 'full_name_required'; end if;
 if p_cpf !~ '^[0-9]{11}$' then raise exception 'invalid_cpf_format'; end if;
 insert into public.clients(organization_id,full_name,cpf,phone,email,original_source)
 values(p_organization_id,btrim(p_full_name),p_cpf,nullif(btrim(p_phone),''),nullif(lower(btrim(p_email)),''),p_original_source) returning id into v_customer_id;
 perform set_config('corban.timeline_rpc','on',true);
 insert into public.customer_timeline_events(organization_id,customer_id,event_type,source,actor_user_id)
 values(p_organization_id,v_customer_id,'customer.created','corban_os',(select auth.uid()));
 perform set_config('corban.timeline_rpc','off',true);
 return v_customer_id;
end $_$;


--
-- Name: create_integration_reexecution(uuid, uuid, uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_integration_reexecution(p_org uuid, p_parent uuid, p_actor uuid, p_reason text, p_correlation text) RETURNS TABLE(run_id uuid, fingerprint text, created boolean)
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_parent public.integration_runs%rowtype;v_child uuid;v_fp text;
begin
 if p_actor is null or not exists(select 1 from public.organization_memberships m where m.organization_id=p_org and m.user_id=p_actor and m.status='active' and m.role in ('admin','manager')) then raise exception 'actor_not_authorized'; end if;
 if p_reason is null or length(btrim(p_reason)) not between 10 and 500 then raise exception 'reexecution_reason_length_invalid'; end if;
 select * into v_parent from public.integration_runs r where r.id=p_parent and r.organization_id=p_org for update;
 if not found then raise exception 'run_not_found'; end if;
 select r.id,r.request_fingerprint into v_child,v_fp from public.integration_runs r where r.parent_run_id=p_parent;
 if v_child is not null then return query select v_child,v_fp,false; return; end if;
 if not ((v_parent.status='failed' and (v_parent.terminal or v_parent.attempt_count>=v_parent.max_attempts)) or v_parent.status='cancelled') then raise exception 'parent_not_reexecutable'; end if;
 v_fp:=encode(extensions.digest(v_parent.request_fingerprint||':reexec:'||p_parent::text,'sha256'),'hex');
 perform set_config('corban.integration_run_rpc','on',true);
 insert into public.integration_runs(organization_id,binding_id,adapter_id,capability,status,request_fingerprint,max_attempts,metadata,created_by,correlation_id,parent_run_id,reexecution_reason)
 values(p_org,v_parent.binding_id,v_parent.adapter_id,v_parent.capability,'queued',v_fp,v_parent.max_attempts,jsonb_build_object('request',coalesce(v_parent.metadata->'request','{}'::jsonb),'reexecution_of',p_parent),p_actor,left(coalesce(p_correlation,v_parent.correlation_id),128),p_parent,btrim(p_reason))
 returning id into v_child;
 perform set_config('corban.integration_run_rpc','off',true);
 return query select v_child,v_fp,true;
end $$;


--
-- Name: create_lead(uuid, text, text, text, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_lead(p_organization_id uuid, p_channel text, p_full_name text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_campaign text DEFAULT NULL::text, p_external_ref text DEFAULT NULL::text, p_metadata jsonb DEFAULT '{}'::jsonb) RETURNS uuid
    LANGUAGE sql
    SET search_path TO ''
    AS $$
 select private.lead_write(p_organization_id,null,'create',jsonb_build_object('channel',p_channel,'full_name',p_full_name,'phone',p_phone,'email',p_email,'campaign',p_campaign,'external_ref',p_external_ref,'metadata',coalesce(p_metadata,'{}'::jsonb)))
$$;


--
-- Name: create_organization_invitation(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_organization_invitation(p_org uuid, p_email text, p_role text) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
declare v_actor text; v_email text:=lower(btrim(coalesce(p_email,''))); v_id uuid;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 v_actor:=private.caller_role_in(p_org);
 if v_actor is null or v_actor not in ('admin','manager') then raise exception 'not_authorized'; end if;
 if p_role is null or p_role not in ('admin','manager','supervisor','agent') then raise exception 'invalid_role'; end if;
 if not public.can_manage_member_role(v_actor,null,p_role) then raise exception 'role_change_not_permitted'; end if;
 if length(v_email) not between 3 and 254 or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+$' then raise exception 'invalid_email'; end if;
 if (select count(*) from public.organization_invitations i where i.organization_id=p_org and i.invited_by=auth.uid() and i.created_at>now()-interval '1 hour')>=20 then raise exception 'invitation_rate_limited'; end if;
 perform set_config('corban.membership_rpc','on',true);
 update public.organization_invitations i set status='expired',resolved_at=now() where i.organization_id=p_org and i.email=v_email and i.status='pending' and i.expires_at<=now();
 begin
  insert into public.organization_invitations(organization_id,email,role,invited_by) values(p_org,v_email,p_role,auth.uid()) returning id into v_id;
 exception when unique_violation then
  perform set_config('corban.membership_rpc','off',true);
  raise exception 'invitation_already_pending';
 end;
 insert into public.organization_admin_events(organization_id,actor_user_id,event_type,target_email,details) values(p_org,auth.uid(),'invite_created',v_email,jsonb_build_object('role',p_role,'invitation_id',v_id));
 perform set_config('corban.membership_rpc','off',true);
 return v_id;
end $_$;


--
-- Name: create_proposal_from_simulation(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_proposal_from_simulation(p_simulation_id uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_org uuid;
  v_sim public.simulations%rowtype;
  v_customer public.clients%rowtype;
  v_version public.product_table_versions%rowtype;
  v_table public.product_tables%rowtype;
  v_proposal_id uuid;
  v_pricing_at timestamptz;
begin
  select s.* into v_sim
  from public.simulations s
  where s.id=p_simulation_id
    and public.is_active_organization_member(s.organization_id)
  for update;

  if v_sim.id is null then raise exception 'simulation_not_found_or_forbidden'; end if;
  if v_sim.status<>'calculated' then raise exception 'simulation_not_available_for_proposal'; end if;

  v_org:=v_sim.organization_id;
  v_pricing_at:=coalesce(
    nullif(v_sim.input_snapshot->>'pricing_effective_at','')::timestamptz,
    v_sim.created_at
  );

  select c.* into v_customer
  from public.clients c
  where c.organization_id=v_org and c.id=v_sim.customer_id and c.deleted_at is null;
  if v_customer.id is null then raise exception 'customer_not_available'; end if;

  -- The version is validated against the instant when the simulation was created,
  -- never against today's pricing.
  select v.* into v_version
  from public.product_table_versions v
  where v.organization_id=v_org
    and v.id=v_sim.product_table_version_id
    and v.status in ('published','superseded')
    and coalesce(v.effective_from,v.published_at,v.created_at)<=v_pricing_at
    and (v.effective_until is null or v_pricing_at<v.effective_until);

  if v_version.id is null then raise exception 'simulation_pricing_version_not_available'; end if;

  select pt.* into v_table
  from public.product_tables pt
  where pt.organization_id=v_org and pt.id=v_version.product_table_id;
  if v_table.id is null then raise exception 'product_table_not_available'; end if;

  perform set_config('corban.proposal_rpc','on',true);
  insert into public.proposals_v2(
    organization_id,customer_id,simulation_id,product_table_version_id,status,
    requested_amount,released_amount,installment_amount,term,rate,coefficient,
    expected_commission_amount,customer_snapshot,commercial_snapshot,attribution_snapshot,created_by
  ) values(
    v_org,v_customer.id,v_sim.id,v_version.id,'draft',
    v_sim.requested_amount,v_sim.released_amount,v_sim.installment_amount,
    v_sim.term,v_sim.rate,v_sim.coefficient,v_sim.expected_commission_amount,
    jsonb_build_object(
      'full_name',v_customer.full_name,'cpf',v_customer.cpf,
      'phone',v_customer.phone,'email',v_customer.email
    ),
    jsonb_build_object(
      'pricing_effective_at',v_pricing_at,
      'product_table',jsonb_build_object('id',v_table.id,'code',v_table.code,'name',v_table.name),
      'table_version',jsonb_build_object(
        'id',v_version.id,'version',v_version.version,
        'effective_from',v_version.effective_from,'effective_until',v_version.effective_until,
        'rate',v_version.rate,'coefficient',v_version.coefficient
      )
    ),
    jsonb_build_object('original_source',v_customer.original_source),
    auth.uid()
  ) returning id into v_proposal_id;
  perform set_config('corban.proposal_rpc','off',true);

  perform set_config('corban.simulation_rpc','on',true);
  update public.simulations
  set status='selected',updated_at=now()
  where organization_id=v_org and id=v_sim.id;
  perform set_config('corban.simulation_rpc','off',true);

  return v_proposal_id;
exception when others then
  perform set_config('corban.proposal_rpc','off',true);
  perform set_config('corban.simulation_rpc','off',true);
  raise;
end
$$;


--
-- Name: create_seller_with_access(uuid, text, text, text, uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_seller_with_access(p_org uuid, p_name text, p_seller_category text, p_tax_id text, p_seller_group_id uuid, p_commission_group_id uuid, p_email text DEFAULT NULL::text) RETURNS TABLE(seller_id uuid, invitation_id uuid)
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
declare
  v_actor text;
  v_name text:=btrim(coalesce(p_name,''));
  v_tax text:=nullif(regexp_replace(coalesce(p_tax_id,''),'[^0-9]','','g'),'');
  v_email text:=nullif(lower(btrim(coalesce(p_email,''))),'');
  v_seller uuid;
  v_inv uuid;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  v_actor:=private.caller_role_in(p_org);
  if v_actor is null or v_actor not in ('admin','manager') then raise exception 'not_authorized'; end if;

  if length(v_name) not between 1 and 160 then raise exception 'invalid_seller_name'; end if;
  if p_seller_category not in ('pf','pj','sub') then raise exception 'invalid_seller_category'; end if;
  if v_tax is not null and length(v_tax) not in (11,14) then raise exception 'invalid_seller_tax_id'; end if;

  if not exists(
    select 1 from public.seller_groups g
    where g.organization_id=p_org and g.id=p_seller_group_id and g.is_active
  ) then raise exception 'active_seller_group_required'; end if;

  if not exists(
    select 1 from public.commission_groups g
    where g.organization_id=p_org and g.id=p_commission_group_id and g.is_active
  ) then raise exception 'active_commission_group_required'; end if;

  if v_email is not null and (
    length(v_email) not between 3 and 254
    or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+$'
  ) then raise exception 'invalid_email'; end if;

  insert into public.commercial_sellers(
    organization_id,name,seller_category,tax_id,seller_group_id,commission_group_id
  ) values(
    p_org,v_name,p_seller_category,v_tax,p_seller_group_id,p_commission_group_id
  )
  returning id into v_seller;

  if v_email is not null then
    v_inv:=public.create_organization_invitation(p_org,v_email,'agent');
    perform set_config('corban.membership_rpc','on',true);
    update public.organization_invitations i
    set seller_id=v_seller
    where i.id=v_inv and i.organization_id=p_org;
    perform set_config('corban.membership_rpc','off',true);
  end if;

  perform set_config('corban.membership_rpc','on',true);
  insert into public.organization_admin_events(
    organization_id,actor_user_id,event_type,target_email,details
  ) values(
    p_org,auth.uid(),'seller_created',v_email,
    jsonb_build_object(
      'seller_id',v_seller,
      'seller_category',p_seller_category,
      'seller_group_id',p_seller_group_id,
      'commission_group_id',p_commission_group_id,
      'access_invitation_id',v_inv
    )
  );
  perform set_config('corban.membership_rpc','off',true);

  seller_id:=v_seller;
  invitation_id:=v_inv;
  return next;
end
$_$;


--
-- Name: create_simulation(uuid, uuid, numeric, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_simulation(p_customer_id uuid, p_table_version_id uuid, p_requested_amount numeric, p_term integer) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_customer public.clients%rowtype;
  v_version public.product_table_versions%rowtype;
  v_amount numeric;
  v_installment numeric;
  v_id uuid;
  v_now timestamptz:=now();
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if p_requested_amount is null or p_requested_amount<=0 or p_requested_amount>999999999 then raise exception 'invalid_amount'; end if;
  if p_term is null or p_term<=0 or p_term>600 then raise exception 'invalid_term'; end if;
  v_amount:=round(p_requested_amount,2);

  select c.* into v_customer
  from public.clients c
  where c.id=p_customer_id and c.deleted_at is null;
  if v_customer.id is null then raise exception 'customer_not_found_or_forbidden'; end if;
  if not public.is_active_organization_member(v_customer.organization_id) then raise exception 'not_authorized'; end if;

  select v.* into v_version
  from public.product_table_versions v
  where v.id=p_table_version_id
    and v.organization_id=v_customer.organization_id
    and v.status='published'
    and coalesce(v.effective_from,v.published_at,v.created_at)<=v_now
    and (v.effective_until is null or v_now<v.effective_until);

  if v_version.id is null then raise exception 'published_table_version_not_available'; end if;
  if v_version.term_min is not null and p_term<v_version.term_min then raise exception 'term_below_table_minimum'; end if;
  if v_version.term_max is not null and p_term>v_version.term_max then raise exception 'term_above_table_maximum'; end if;

  v_installment:=case when v_version.coefficient is not null and v_version.coefficient>0 then round(v_amount*v_version.coefficient,2) else null end;

  perform set_config('corban.simulation_rpc','on',true);
  insert into public.simulations(
    organization_id,customer_id,product_table_version_id,status,
    requested_amount,installment_amount,term,rate,coefficient,
    input_snapshot,result_snapshot,created_by
  ) values(
    v_customer.organization_id,v_customer.id,v_version.id,'calculated',
    v_amount,v_installment,p_term,v_version.rate,v_version.coefficient,
    jsonb_build_object('requested_amount',v_amount,'term',p_term,'pricing_effective_at',v_now),
    jsonb_build_object('calculation',case when v_installment is null then 'manual_pending' else 'requested_amount_x_coefficient' end),
    auth.uid()
  ) returning id into v_id;
  perform set_config('corban.simulation_rpc','off',true);
  return v_id;
exception when others then
  perform set_config('corban.simulation_rpc','off',true);
  raise;
end
$$;


--
-- Name: create_simulation_for_condition(uuid, uuid, uuid, numeric, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_simulation_for_condition(p_customer_id uuid, p_table_version_id uuid, p_contract_type_id uuid, p_requested_amount numeric, p_term integer) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_customer public.clients%rowtype;
  v_version public.product_table_versions%rowtype;
  c public.commercial_conditions%rowtype;
  v_amount numeric;
  v_installment numeric;
  v_id uuid;
  v_now timestamptz:=now();
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if p_requested_amount is null or p_requested_amount<=0 or p_requested_amount>999999999 then raise exception 'invalid_amount'; end if;
  if p_term is null or p_term<=0 or p_term>600 then raise exception 'invalid_term'; end if;
  v_amount:=round(p_requested_amount,2);

  select cl.* into v_customer from public.clients cl where cl.id=p_customer_id and cl.deleted_at is null;
  if v_customer.id is null then raise exception 'customer_not_found_or_forbidden'; end if;
  if not public.is_active_organization_member(v_customer.organization_id) then raise exception 'not_authorized'; end if;

  select x.* into v_version from public.product_table_versions x
  where x.id=p_table_version_id
    and x.organization_id=v_customer.organization_id
    and x.status='published'
    and coalesce(x.effective_from,x.published_at,x.created_at)<=v_now
    and (x.effective_until is null or v_now<x.effective_until);
  if v_version.id is null then raise exception 'published_table_version_not_available'; end if;

  select k.* into c from public.commercial_conditions k
  where k.organization_id=v_customer.organization_id
    and k.product_table_version_id=v_version.id
    and k.contract_type_id=p_contract_type_id
    and p_term between k.term_min and k.term_max
    and k.amount_min is null and k.amount_max is null
  order by k.term_min desc limit 1;

  if c.id is null then
    if exists(
      select 1 from public.commercial_conditions k
      where k.organization_id=v_customer.organization_id
        and k.product_table_version_id=v_version.id
        and k.contract_type_id=p_contract_type_id
        and p_term between k.term_min and k.term_max
        and k.amount_min is not null
    ) then raise exception 'contract_value_required'; end if;
    raise exception 'condition_not_found';
  end if;

  v_installment:=case when c.coefficient is not null and c.coefficient>0 then round(v_amount*c.coefficient,2) else null end;

  perform set_config('corban.simulation_rpc','on',true);
  insert into public.simulations(
    organization_id,customer_id,product_table_version_id,status,
    requested_amount,installment_amount,term,rate,coefficient,input_snapshot,result_snapshot,created_by
  ) values(
    v_customer.organization_id,v_customer.id,v_version.id,'calculated',
    v_amount,v_installment,p_term,c.rate,c.coefficient,
    jsonb_build_object(
      'requested_amount',v_amount,'term',p_term,'contract_type_id',p_contract_type_id,
      'condition_id',c.id,'condition_term_min',c.term_min,'condition_term_max',c.term_max,
      'condition_amount_min',c.amount_min,'condition_amount_max',c.amount_max,'pricing_effective_at',v_now
    ),
    jsonb_build_object('calculation',case when v_installment is null then 'manual_pending' else 'requested_amount_x_coefficient' end),
    auth.uid()
  ) returning id into v_id;
  perform set_config('corban.simulation_rpc','off',true);
  return v_id;
exception when others then
  perform set_config('corban.simulation_rpc','off',true);
  raise;
end
$$;


--
-- Name: create_simulation_for_condition(uuid, uuid, uuid, numeric, integer, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_simulation_for_condition(p_customer_id uuid, p_table_version_id uuid, p_contract_type_id uuid, p_requested_amount numeric, p_term integer, p_contract_value numeric) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_customer public.clients%rowtype;
  v_version public.product_table_versions%rowtype;
  c public.commercial_conditions%rowtype;
  v_amount numeric;
  v_contract_value numeric;
  v_installment numeric;
  v_id uuid;
  v_now timestamptz:=now();
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if p_requested_amount is null or p_requested_amount<=0 or p_requested_amount>999999999 then raise exception 'invalid_amount'; end if;
  if p_contract_value is null or p_contract_value<0 or p_contract_value>999999999.99 then raise exception 'invalid_contract_value'; end if;
  if p_term is null or p_term<=0 or p_term>600 then raise exception 'invalid_term'; end if;
  v_amount:=round(p_requested_amount,2);
  v_contract_value:=round(p_contract_value,2);

  select cl.* into v_customer from public.clients cl where cl.id=p_customer_id and cl.deleted_at is null;
  if v_customer.id is null then raise exception 'customer_not_found_or_forbidden'; end if;
  if not public.is_active_organization_member(v_customer.organization_id) then raise exception 'not_authorized'; end if;

  select x.* into v_version from public.product_table_versions x
  where x.id=p_table_version_id
    and x.organization_id=v_customer.organization_id
    and x.status='published'
    and coalesce(x.effective_from,x.published_at,x.created_at)<=v_now
    and (x.effective_until is null or v_now<x.effective_until);
  if v_version.id is null then raise exception 'published_table_version_not_available'; end if;

  select k.* into c from public.commercial_conditions k
  where k.organization_id=v_customer.organization_id
    and k.product_table_version_id=v_version.id
    and k.contract_type_id=p_contract_type_id
    and p_term between k.term_min and k.term_max
    and (
      (k.amount_min is null and k.amount_max is null)
      or v_contract_value between k.amount_min and k.amount_max
    )
  order by (k.amount_min is not null) desc,k.term_min desc,k.amount_min desc nulls last
  limit 1;

  if c.id is null then raise exception 'condition_not_found'; end if;

  v_installment:=case when c.coefficient is not null and c.coefficient>0 then round(v_amount*c.coefficient,2) else null end;

  perform set_config('corban.simulation_rpc','on',true);
  insert into public.simulations(
    organization_id,customer_id,product_table_version_id,status,
    requested_amount,installment_amount,term,rate,coefficient,input_snapshot,result_snapshot,created_by
  ) values(
    v_customer.organization_id,v_customer.id,v_version.id,'calculated',
    v_amount,v_installment,p_term,c.rate,c.coefficient,
    jsonb_build_object(
      'requested_amount',v_amount,'contract_value',v_contract_value,'term',p_term,'contract_type_id',p_contract_type_id,
      'condition_id',c.id,'condition_term_min',c.term_min,'condition_term_max',c.term_max,
      'condition_amount_min',c.amount_min,'condition_amount_max',c.amount_max,'pricing_effective_at',v_now
    ),
    jsonb_build_object('calculation',case when v_installment is null then 'manual_pending' else 'requested_amount_x_coefficient' end),
    auth.uid()
  ) returning id into v_id;
  perform set_config('corban.simulation_rpc','off',true);
  return v_id;
exception when others then
  perform set_config('corban.simulation_rpc','off',true);
  raise;
end
$$;


--
-- Name: decide_attention_item(uuid, text, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.decide_attention_item(p_item uuid, p_action text, p_note text, p_snooze_until timestamp with time zone) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare i public.operational_attention_items%rowtype; v_note text:=nullif(btrim(coalesce(p_note,'')),'');
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into i from public.operational_attention_items x where x.id=p_item for update;
 if not found then raise exception 'item_not_found'; end if;
 if not public.has_active_organization_role(i.organization_id,array['admin','manager','supervisor']) then raise exception 'not_authorized'; end if;
 if p_action is null or p_action not in ('resolve','dismiss','snooze','reopen') then raise exception 'invalid_action'; end if;
 if v_note is not null and length(v_note)>500 then raise exception 'invalid_action'; end if;
 if i.status='resolved' then raise exception 'item_already_resolved'; end if;
 perform set_config('corban.attention_rpc','on',true);
 if p_action='resolve' then
  update public.operational_attention_items set status='resolved',resolved_at=now(),decided_by=auth.uid(),snoozed_until=null where id=i.id;
  insert into public.operational_attention_events(organization_id,item_id,event,actor,note) values(i.organization_id,i.id,'resolved',auth.uid(),v_note);
 elsif p_action='dismiss' then
  -- ignoring a signal is a decision: it needs a reason (audit)
  if v_note is null or length(v_note)<3 then raise exception 'note_required'; end if;
  update public.operational_attention_items set status='dismissed',decided_by=auth.uid(),snoozed_until=null where id=i.id;
  insert into public.operational_attention_events(organization_id,item_id,event,actor,note) values(i.organization_id,i.id,'dismissed',auth.uid(),v_note);
 elsif p_action='snooze' then
  if p_snooze_until is null or p_snooze_until<=now() or p_snooze_until>now()+interval '90 days' then raise exception 'invalid_snooze'; end if;
  update public.operational_attention_items set status='snoozed',snoozed_until=p_snooze_until,decided_by=auth.uid() where id=i.id;
  insert into public.operational_attention_events(organization_id,item_id,event,actor,note,detail) values(i.organization_id,i.id,'snoozed',auth.uid(),v_note,jsonb_build_object('until',p_snooze_until));
 else
  if i.status='open' then raise exception 'invalid_action'; end if;
  update public.operational_attention_items set status='open',snoozed_until=null,decided_by=auth.uid() where id=i.id;
  insert into public.operational_attention_events(organization_id,item_id,event,actor,note) values(i.organization_id,i.id,'reopened',auth.uid(),v_note);
 end if;
 perform set_config('corban.attention_rpc','off',true);
 return i.id;
end $$;


--
-- Name: enqueue_integration_run(uuid, uuid, text, text, uuid, integer, jsonb, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enqueue_integration_run(p_org uuid, p_binding uuid, p_capability text, p_fingerprint text, p_actor uuid, p_max_attempts integer, p_request jsonb, p_correlation text, p_adapter_key text DEFAULT NULL::text) RETURNS TABLE(run_id uuid, status text, created boolean)
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
declare v_adapter uuid;v_adapter_key text;v_id uuid;v_status text;
begin
 if p_max_attempts is null or p_max_attempts not between 1 and 10 then raise exception 'invalid_max_attempts'; end if;
 if p_fingerprint !~ '^[0-9a-f]{64}$' then raise exception 'invalid_fingerprint'; end if;
 if p_actor is null or not exists(select 1 from public.organization_memberships m where m.organization_id=p_org and m.user_id=p_actor and m.status='active' and m.role in ('admin','manager','supervisor')) then raise exception 'actor_not_authorized'; end if;
 select b.adapter_id,a.adapter_key into v_adapter,v_adapter_key from public.integration_source_bindings b join public.integration_adapters a on a.id=b.adapter_id where b.id=p_binding and b.organization_id=p_org and b.enabled;
 if v_adapter is null then raise exception 'binding_not_found'; end if;
 if p_adapter_key is not null and p_adapter_key<>v_adapter_key then raise exception 'adapter_mismatch'; end if;
 perform set_config('corban.integration_run_rpc','on',true);
 insert into public.integration_runs(organization_id,binding_id,adapter_id,capability,status,request_fingerprint,max_attempts,metadata,created_by,correlation_id)
 values(p_org,p_binding,v_adapter,p_capability,'queued',p_fingerprint,p_max_attempts,jsonb_build_object('request',coalesce(p_request,'{}'::jsonb)),p_actor,left(p_correlation,128))
 on conflict(organization_id,binding_id,request_fingerprint) do nothing returning id into v_id;
 perform set_config('corban.integration_run_rpc','off',true);
 if v_id is not null then return query select v_id,'queued'::text,true; return; end if;
 select r.id,r.status into v_id,v_status from public.integration_runs r where r.organization_id=p_org and r.binding_id=p_binding and r.request_fingerprint=p_fingerprint;
 return query select v_id,v_status,false;
end $_$;


--
-- Name: fail_integration_run(uuid, uuid, uuid, text, text, boolean, integer, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fail_integration_run(p_org uuid, p_run uuid, p_token uuid, p_code text, p_message text, p_retryable boolean, p_backoff_seconds integer, p_now timestamp with time zone DEFAULT now()) RETURNS text
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_run public.integration_runs%rowtype;v_terminal boolean;v_msg text;v_code text;
begin
 select * into v_run from public.integration_runs r where r.id=p_run and r.organization_id=p_org for update;
 if not found then raise exception 'run_not_found'; end if;
 if v_run.status<>'running' or v_run.claim_token is distinct from p_token then return 'lease_lost'; end if;
 v_terminal:=not coalesce(p_retryable,false) or v_run.attempt_count>=v_run.max_attempts;
 v_msg:=case when public.integration_content_has_secret(p_message) then '[redacted by database guard]' else left(p_message,500) end;
 v_code:=case when public.integration_content_has_secret(p_code) then 'redacted_code' else left(p_code,80) end;
 perform set_config('corban.integration_run_rpc','on',true);
 insert into public.integration_run_artifacts(organization_id,run_id,artifact_kind,payload,content_sha256)
 values(p_org,p_run,'diagnostic',jsonb_build_object('attempt',v_run.attempt_count,'outcome',case when v_terminal then 'failed_terminal' else 'retry_scheduled' end,'code',v_code,'message',v_msg,'retryable',coalesce(p_retryable,false),'at',p_now),md5(p_run::text||':fail:'||v_run.attempt_count::text))
 on conflict(run_id,artifact_kind,content_sha256) where content_sha256 is not null do nothing;
 update public.integration_runs set status='failed',terminal=v_terminal,error_code=case when not coalesce(p_retryable,false) then 'terminal:'||v_code else v_code end,error_message=v_msg,
  next_attempt_at=case when v_terminal then null else p_now+make_interval(secs=>greatest(0,least(coalesce(p_backoff_seconds,0),3600))) end where id=p_run;
 perform set_config('corban.integration_run_rpc','off',true);
 return case when v_terminal then 'failed_terminal' else 'retry_scheduled' end;
end $$;


--
-- Name: freeze_import_source_financial_semantic(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.freeze_import_source_financial_semantic() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
 if old.financial_semantic is distinct from new.financial_semantic and exists(select 1 from public.import_batches where source_id=old.id) then
  raise exception 'source_financial_semantic_in_use';
 end if;
 return new;
end $$;


--
-- Name: freeze_proposal_commercial_route(uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.freeze_proposal_commercial_route(p_proposal_id uuid, p_channel_id uuid, p_commission_rule_version_id uuid, p_producer_entity_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_org uuid;
  v_table uuid;
  v_amount numeric;
  v_seller_id uuid;
  v_channel public.commercial_channels%rowtype;
  v_rule public.channel_commission_rule_versions%rowtype;
  v_comp public.commission_rule_components%rowtype;
  v_split public.network_split_rule_versions%rowtype;
  v_seller public.commercial_sellers%rowtype;
  v_sub public.seller_sub_rule_versions%rowtype;
  v_sub_share numeric:=0;
  v_company_share numeric:=100;
begin
 select p.organization_id,v.product_table_id,coalesce(p.released_amount,p.requested_amount),p.seller_id
   into v_org,v_table,v_amount,v_seller_id
 from public.proposals_v2 p
 join public.product_table_versions v
   on v.id=p.product_table_version_id and v.organization_id=p.organization_id
 where p.id=p_proposal_id
   and p.status='draft'
   and public.is_active_organization_member(p.organization_id);

 if v_org is null then raise exception 'draft_proposal_not_found_or_forbidden'; end if;
 if not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 if v_amount is null or v_amount<0 then raise exception 'proposal_calculation_base_required'; end if;

 if v_seller_id is not null then
  select * into v_seller
  from public.commercial_sellers s
  where s.id=v_seller_id and s.organization_id=v_org and s.is_active;
  if not found then raise exception 'active_seller_required'; end if;
 end if;

 select * into v_channel
 from public.commercial_channels
 where id=p_channel_id and organization_id=v_org and is_active;
 if not found then raise exception 'active_channel_required'; end if;

 select * into v_rule
 from public.channel_commission_rule_versions
 where id=p_commission_rule_version_id
   and organization_id=v_org
   and channel_id=p_channel_id
   and product_table_id=v_table
   and status='published'
   and (effective_from is null or effective_from<=now())
   and (effective_until is null or effective_until>now());
 if not found then raise exception 'published_effective_rule_for_channel_table_required'; end if;

 if p_producer_entity_id is not null
    and not exists(
      select 1 from public.commercial_entities
      where id=p_producer_entity_id and organization_id=v_org and is_active
    ) then
  raise exception 'producer_not_found';
 end if;

 if exists(select 1 from public.proposal_commercial_snapshots where proposal_id=p_proposal_id) then
  raise exception 'commercial_route_already_frozen';
 end if;

 perform set_config('corban.commercial_route_rpc','on',true);

 insert into public.proposal_commercial_snapshots(
   proposal_id,organization_id,channel_id,commission_rule_version_id,
   producer_entity_id,payer_entity_id,split_rule_version_id,snapshot
 )
 values(
   p_proposal_id,v_org,p_channel_id,p_commission_rule_version_id,
   p_producer_entity_id,v_channel.payer_entity_id,null,
   jsonb_build_object(
     'calculation_base_amount',v_amount,
     'product_table_id',v_table,
     'per_component_split',true,
     'seller_id',v_seller_id,
     'seller_category',case when v_seller_id is null then null else v_seller.seller_category end,
     'seller_group_id',case when v_seller_id is null then null else v_seller.seller_group_id end
   )
 );

 for v_comp in
   select * from public.commission_rule_components
   where organization_id=v_org and rule_version_id=v_rule.id
 loop
  v_split:=null;
  if v_channel.relationship_id is not null then
   select * into v_split
   from public.network_split_rule_versions s
   where s.organization_id=v_org
     and s.relationship_id=v_channel.relationship_id
     and s.status='published'
     and (s.bank_id is null or s.bank_id=v_channel.bank_id)
     and (s.product_table_id is null or s.product_table_id=v_table)
     and (s.component_type is null or s.component_type=v_comp.component_type)
     and s.effective_from<=now()
     and (s.effective_until is null or s.effective_until>now())
   order by
     (s.component_type=v_comp.component_type) desc,
     (s.product_table_id=v_table) desc,
     (s.bank_id=v_channel.bank_id) desc,
     s.version desc
   limit 1;
  end if;

  v_sub:=null;
  v_sub_share:=0;
  v_company_share:=100;

  if v_seller_id is not null and v_seller.seller_category='sub' then
   select * into v_sub
   from public.seller_sub_rule_versions sr
   where sr.organization_id=v_org
     and sr.seller_id=v_seller_id
     and sr.status='published'
     and sr.effective_from<=now()
     and sr.component_key in (v_comp.component_type,'all')
   order by
     (sr.component_key=v_comp.component_type) desc,
     sr.effective_from desc,
     sr.version desc
   limit 1;

   if not found then
    raise exception 'published_sub_rule_required_for_component:%',v_comp.component_type;
   end if;
   v_sub_share:=v_sub.sub_share_pct;
   v_company_share:=v_sub.company_share_pct;
  end if;

  insert into public.proposal_commercial_component_snapshots(
    organization_id,proposal_id,component_type,commission_component_id,
    split_rule_version_id,gross_percentage,fixed_amount,anticipation_factor,
    upstream_share,downstream_share,
    seller_id,seller_sub_rule_version_id,seller_sub_share_pct,seller_company_share_pct,
    snapshot
  )
  values(
    v_org,p_proposal_id,v_comp.component_type,v_comp.id,
    v_split.id,v_comp.percentage,v_comp.fixed_amount,v_comp.anticipation_factor,
    coalesce(v_split.upstream_share,1),coalesce(v_split.downstream_share,0),
    v_seller_id,v_sub.id,v_sub_share,v_company_share,
    jsonb_build_object(
      'calculation_base',v_comp.calculation_base,
      'commission_rule_version_id',v_rule.id,
      'split_rule_version_id',v_split.id,
      'seller_id',v_seller_id,
      'seller_category',case when v_seller_id is null then null else v_seller.seller_category end,
      'seller_group_id',case when v_seller_id is null then null else v_seller.seller_group_id end,
      'commission_group_id',case when v_seller_id is null then null else v_seller.commission_group_id end,
      'seller_sub_rule_version_id',v_sub.id,
      'seller_sub_share_pct',v_sub_share,
      'seller_company_share_pct',v_company_share
    )
  );
 end loop;

 perform set_config('corban.commercial_route_rpc','off',true);
 return p_proposal_id;
end
$$;


--
-- Name: freeze_published_commercial_rule(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.freeze_published_commercial_rule() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
 if old.status='published' then raise exception 'published_commercial_rule_is_immutable'; end if;
 return new;
end $$;


--
-- Name: generate_import_match_candidates(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_import_match_candidates(p_batch_id uuid) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_org uuid;
  v_count integer:=0;
  r record;
  v_proposal uuid;
  v_proposal_count integer;
  v_table uuid;
  v_table_count integer;
  v_channel uuid;
begin
  select b.organization_id into v_org
  from public.import_batches b
  where b.id=p_batch_id
    and public.is_active_organization_member(b.organization_id);
  if v_org is null then raise exception 'batch_not_found_or_forbidden'; end if;

  perform set_config('corban.import_match_rpc','on',true);

  for r in
    select n.id,n.external_proposal_number,n.bank_key,n.external_table_code,n.resolved_seller_id
    from public.import_normalized_rows n
    join public.import_raw_rows rr
      on rr.id=n.raw_row_id and rr.organization_id=n.organization_id
    where rr.batch_id=p_batch_id and n.organization_id=v_org
  loop
    if exists(
      select 1 from public.import_match_candidates c
      where c.organization_id=v_org and c.normalized_row_id=r.id
    ) then continue; end if;

    v_proposal:=null;v_proposal_count:=0;v_table:=null;v_table_count:=0;v_channel:=null;

    if r.external_proposal_number is not null then
      select count(*),(array_agg(e.proposal_id))[1]
      into v_proposal_count,v_proposal
      from public.proposal_external_identities e
      where e.organization_id=v_org
        and e.external_proposal_number=r.external_proposal_number
        and (r.bank_key is null or lower(e.institution_key)=lower(r.bank_key));
    end if;

    if r.external_table_code is not null then
      select count(*),(array_agg(e.product_table_id))[1],(array_agg(e.channel_id))[1]
      into v_table_count,v_table,v_channel
      from public.product_table_external_identities e
      where e.organization_id=v_org
        and e.external_code=r.external_table_code
        and (e.effective_until is null or e.effective_until>now());
    end if;

    if v_proposal_count=1 then
      insert into public.import_match_candidates(
        organization_id,normalized_row_id,proposal_id,product_table_id,channel_id,
        seller_id,match_strength,match_basis,status
      ) values(
        v_org,r.id,v_proposal,
        case when v_table_count=1 then v_table end,
        case when v_table_count=1 then v_channel end,
        r.resolved_seller_id,
        'exact',
        jsonb_build_object(
          'external_proposal_number',r.external_proposal_number,
          'bank_key',r.bank_key,
          'proposal_matches',v_proposal_count,
          'table_matches',v_table_count,
          'seller_alias_resolved',r.resolved_seller_id is not null
        ),
        'suggested'
      );
    elsif v_proposal_count>1 then
      insert into public.import_match_candidates(
        organization_id,normalized_row_id,seller_id,match_strength,match_basis,status
      ) values(
        v_org,r.id,r.resolved_seller_id,'ambiguous',
        jsonb_build_object(
          'external_proposal_number',r.external_proposal_number,
          'proposal_matches',v_proposal_count,
          'seller_alias_resolved',r.resolved_seller_id is not null
        ),
        'human_required'
      );
    elsif v_table_count=1 then
      insert into public.import_match_candidates(
        organization_id,normalized_row_id,product_table_id,channel_id,seller_id,
        match_strength,match_basis,status
      ) values(
        v_org,r.id,v_table,v_channel,r.resolved_seller_id,'strong',
        jsonb_build_object(
          'external_table_code',r.external_table_code,
          'table_matches',1,
          'seller_alias_resolved',r.resolved_seller_id is not null
        ),
        'suggested'
      );
    elsif v_table_count>1 then
      insert into public.import_match_candidates(
        organization_id,normalized_row_id,seller_id,match_strength,match_basis,status
      ) values(
        v_org,r.id,r.resolved_seller_id,'ambiguous',
        jsonb_build_object(
          'external_table_code',r.external_table_code,
          'table_matches',v_table_count,
          'seller_alias_resolved',r.resolved_seller_id is not null
        ),
        'human_required'
      );
    else
      insert into public.import_match_candidates(
        organization_id,normalized_row_id,seller_id,match_strength,match_basis,status
      ) values(
        v_org,r.id,r.resolved_seller_id,'none',
        jsonb_build_object(
          'external_proposal_number',r.external_proposal_number,
          'external_table_code',r.external_table_code,
          'seller_alias_resolved',r.resolved_seller_id is not null
        ),
        'human_required'
      );
    end if;

    v_count:=v_count+1;
  end loop;

  perform set_config('corban.import_match_rpc','off',true);
  update public.import_batches
  set status='ready_for_review',completed_at=coalesce(completed_at,now())
  where id=p_batch_id and organization_id=v_org;

  return v_count;
end
$$;


--
-- Name: get_commercial_route(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_commercial_route(p_proposal_id uuid) RETURNS TABLE(proposal_id uuid, channel_id uuid, producer_entity_id uuid, payer_entity_id uuid, commission_rule_version_id uuid, split_rule_version_id uuid, snapshot jsonb, created_at timestamp with time zone)
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$ select * from private.commercial_route(p_proposal_id) $$;


--
-- Name: get_user_organization_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_organization_id() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
  select p.organization_id
  from public.profiles p
  where p.id = auth.uid()
  limit 1
$$;


--
-- Name: guard_admin_event_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_admin_event_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if tg_op<>'INSERT' then raise exception 'admin_events_append_only'; end if;
 if current_user in ('authenticated','anon') and current_setting('corban.membership_rpc',true) is distinct from 'on' then raise exception 'admin_event_requires_governed_rpc'; end if;
 return new;
end $$;


--
-- Name: guard_ai_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_ai_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 -- ledger and events are append-only, for everyone
 if tg_table_name in ('ai_credit_ledger','ai_usage_events') and tg_op in ('UPDATE','DELETE') then raise exception 'ai_records_are_append_only'; end if;
 if tg_op='DELETE' then raise exception 'ai_records_are_append_only'; end if;
 if current_user in ('authenticated','anon') and current_setting('corban.ai_rpc',true) is distinct from 'on' then raise exception 'ai_write_requires_governed_rpc'; end if;
 if tg_table_name='ai_usage_jobs' and tg_op='UPDATE' then
  -- a settled job never changes again; only the settlement columns may move, and only once
  if old.status<>'reserved' then raise exception 'job_already_settled'; end if;
  if (to_jsonb(new)-'status'-'credits_charged'-'actual_provider_cost'-'input_units'-'output_units'-'settled_at') is distinct from (to_jsonb(old)-'status'-'credits_charged'-'actual_provider_cost'-'input_units'-'output_units'-'settled_at') then raise exception 'job_identity_is_immutable'; end if;
 end if;
 return new;
end $$;


--
-- Name: guard_attention_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_attention_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if tg_op='DELETE' or (tg_table_name='operational_attention_events' and tg_op='UPDATE') then raise exception 'attention_records_are_not_deletable'; end if;
 if current_user in ('authenticated','anon') and current_setting('corban.attention_rpc',true) is distinct from 'on' then raise exception 'attention_write_requires_governed_rpc'; end if;
 -- (nested on purpose: plpgsql does not short-circuit "and", and the events table has no rule_key column)
 if tg_table_name='operational_attention_items' and tg_op='UPDATE' then
  if new.organization_id is distinct from old.organization_id or new.rule_key is distinct from old.rule_key or new.dedupe_key is distinct from old.dedupe_key or new.first_detected_at is distinct from old.first_detected_at then raise exception 'attention_identity_is_immutable'; end if;
  -- a resolved item is history: it never comes back (a new detection opens a new item)
  if old.status='resolved' then raise exception 'attention_item_is_resolved'; end if;
 end if;
 return new;
end $$;


--
-- Name: guard_catalog_publication(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_catalog_publication() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if current_user in ('authenticated','anon') then
  if tg_op='INSERT' and new.status is distinct from 'draft' then raise exception 'catalog_insert_must_be_draft'; end if;
  if tg_op='UPDATE' and old.status='draft' and new.status is distinct from 'draft' and current_setting('corban.catalog_rpc',true) is distinct from 'on' then raise exception 'catalog_publication_requires_governed_rpc'; end if;
  if tg_op='UPDATE' and old.status<>'draft' and new.status is distinct from old.status and current_setting('corban.catalog_rpc',true) is distinct from 'on' then raise exception 'catalog_status_requires_governed_rpc'; end if;
 end if;
 return new;
end $$;


--
-- Name: guard_commission_group_component_limit_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_commission_group_component_limit_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if current_user in ('authenticated','anon')
     and current_setting('corban.commission_group_config_rpc',true) is distinct from 'on' then
    raise exception 'commission_group_component_write_requires_governed_rpc';
  end if;
  if tg_op='UPDATE' then
    if new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.group_id is distinct from old.group_id
       or new.component_type_id is distinct from old.component_type_id
       or new.created_at is distinct from old.created_at
       or new.created_by is distinct from old.created_by
    then raise exception 'commission_group_component_identity_immutable'; end if;
    new.updated_at:=now();
    new.updated_by:=auth.uid();
  elsif tg_op='INSERT' then
    new.created_by:=auth.uid();
    new.updated_by:=auth.uid();
  end if;
  return new;
end
$$;


--
-- Name: guard_commission_group_received_basis(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_commission_group_received_basis() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if new.calculation_basis is distinct from 'percent_of_received_commission' then
    raise exception 'commission_group_received_basis_required';
  end if;
  return new;
end
$$;


--
-- Name: guard_component_commission_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_component_commission_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_status text;
begin
  if tg_table_name='commercial_condition_components' then
    select v.status into v_status
    from public.commercial_conditions c
    join public.product_table_versions v on v.id=c.product_table_version_id and v.organization_id=c.organization_id
    where c.id=coalesce(new.condition_id,old.condition_id) and c.organization_id=coalesce(new.organization_id,old.organization_id);
    if v_status is distinct from 'draft' then raise exception 'published_version_components_are_immutable'; end if;
    if current_user in ('authenticated','anon') and current_setting('corban.component_condition_rpc',true) is distinct from 'on' then
      raise exception 'component_condition_write_requires_governed_rpc';
    end if;
    if tg_op='DELETE' then return old; end if;
    if tg_op='INSERT' and current_user in ('authenticated','anon') then new.created_by:=auth.uid(); end if;
    if tg_op='UPDATE' then
      if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id or new.condition_id is distinct from old.condition_id or new.component_type_id is distinct from old.component_type_id or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
        raise exception 'component_identity_is_immutable';
      end if;
      new.updated_at:=now();
    end if;
    return new;
  end if;

  if tg_table_name in ('component_payout_policy_versions','component_payout_policy_items') and tg_op in ('UPDATE','DELETE') then
    raise exception 'component_payout_policy_version_is_immutable';
  end if;
  if tg_table_name in ('component_payout_policy_versions','component_payout_policy_items') and current_user in ('authenticated','anon') and current_setting('corban.component_policy_rpc',true) is distinct from 'on' then
    raise exception 'component_policy_write_requires_governed_rpc';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;


--
-- Name: guard_component_payout_group_limit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_component_payout_group_limit() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_limit numeric;
begin
  if new.mode='direct' then
    raise exception 'commission_group_direct_component_mode_forbidden';
  end if;

  select l.max_received_share_pct into v_limit
  from public.commission_group_component_limits l
  join public.commission_component_types t
    on t.id=l.component_type_id and t.is_active
  where l.organization_id=new.organization_id
    and l.group_id=new.group_id
    and l.component_type_id=new.component_type_id;

  if v_limit is null then
    raise exception 'commission_group_component_not_configured';
  end if;

  -- A specific table/rule may always choose to repass nothing.
  if new.mode='exclude' then
    return new;
  end if;

  if new.mode<>'share_of_received'
     or new.share_pct is null
     or new.share_pct<0
     or new.share_pct>v_limit then
    raise exception 'commission_group_component_share_exceeds_limit';
  end if;

  return new;
end
$$;


--
-- Name: guard_component_payout_policy_scope(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_component_payout_policy_scope() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_bank uuid; v_agreement uuid;
begin
  if new.product_table_id is not null then
    select r.org_bank_id,r.org_agreement_id into v_bank,v_agreement
    from public.product_tables t
    join public.organization_product_routes r on r.id=t.route_id and r.organization_id=t.organization_id
    where t.id=new.product_table_id and t.organization_id=new.organization_id;
    if not found then raise exception 'component_policy_table_not_found'; end if;
    if new.org_bank_id is not null and new.org_bank_id is distinct from v_bank then raise exception 'component_policy_bank_mismatch'; end if;
    if new.org_agreement_id is not null and new.org_agreement_id is distinct from v_agreement then raise exception 'component_policy_agreement_mismatch'; end if;
  end if;
  return new;
end $$;


--
-- Name: guard_condition_component_policy(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_condition_component_policy() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_status text;
  v_table_id uuid;
  v_bank_id uuid;
  v_agreement_id uuid;
  v_policy public.component_payout_policies%rowtype;
begin
  select v.status,t.id,r.org_bank_id,r.org_agreement_id
    into v_status,v_table_id,v_bank_id,v_agreement_id
  from public.commercial_conditions c
  join public.product_table_versions v
    on v.id=c.product_table_version_id and v.organization_id=c.organization_id
  join public.product_tables t
    on t.id=v.product_table_id and t.organization_id=v.organization_id
  join public.organization_product_routes r
    on r.id=t.route_id and r.organization_id=t.organization_id
  where c.id=new.condition_id and c.organization_id=new.organization_id;

  if v_status is distinct from 'draft' then
    raise exception 'published_version_component_policy_is_immutable';
  end if;

  select p.* into v_policy
  from public.component_payout_policy_versions pv
  join public.component_payout_policies p
    on p.id=pv.policy_id and p.organization_id=pv.organization_id
  where pv.id=new.policy_version_id
    and pv.organization_id=new.organization_id
    and p.is_active;

  if not found then
    raise exception 'component_policy_not_found';
  end if;

  if v_policy.org_bank_id is not null and v_policy.org_bank_id is distinct from v_bank_id then
    raise exception 'component_policy_scope_mismatch';
  end if;
  if v_policy.org_agreement_id is not null and v_policy.org_agreement_id is distinct from v_agreement_id then
    raise exception 'component_policy_scope_mismatch';
  end if;
  if v_policy.product_table_id is not null and v_policy.product_table_id is distinct from v_table_id then
    raise exception 'component_policy_scope_mismatch';
  end if;

  if current_user in ('authenticated','anon')
     and current_setting('corban.smart_import_rpc',true) is distinct from 'on' then
    raise exception 'condition_component_policy_write_requires_governed_rpc';
  end if;

  if tg_op='UPDATE' and (
    new.condition_id is distinct from old.condition_id
    or new.organization_id is distinct from old.organization_id
    or new.attached_at is distinct from old.attached_at
  ) then
    raise exception 'condition_component_policy_identity_is_immutable';
  end if;

  if current_user in ('authenticated','anon') then
    new.attached_by:=auth.uid();
  end if;
  return new;
end
$$;


--
-- Name: guard_condition_contract_type_scope(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_condition_contract_type_scope() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_type_org uuid; v_active boolean; v_enabled boolean;
begin
  select organization_id,is_active into v_type_org,v_active from public.contract_types where id=new.contract_type_id;
  if not found or not v_active then raise exception 'contract_type_not_found'; end if;
  if v_type_org is not null and v_type_org is distinct from new.organization_id then raise exception 'cross_tenant_contract_type'; end if;
  select s.is_enabled into v_enabled from public.organization_contract_type_settings s where s.organization_id=new.organization_id and s.contract_type_id=new.contract_type_id;
  if v_enabled is false then raise exception 'contract_type_disabled'; end if;
  return new;
end $$;


--
-- Name: guard_condition_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_condition_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_version uuid; v_status text; v_org uuid;
begin
 if tg_table_name='commercial_conditions' then v_version:=case when tg_op='DELETE' then old.product_table_version_id else new.product_table_version_id end; v_org:=case when tg_op='DELETE' then old.organization_id else new.organization_id end;
 else select c.product_table_version_id,c.organization_id into v_version,v_org from public.commercial_conditions c where c.id=case when tg_op='DELETE' then old.condition_id else new.condition_id end; end if;
 if current_user in ('authenticated','anon') and current_setting('corban.condition_rpc',true) is distinct from 'on' then raise exception 'condition_write_requires_governed_rpc'; end if;
 select v.status into v_status from public.product_table_versions v where v.organization_id=v_org and v.id=v_version;
 if v_status is distinct from 'draft' then raise exception 'published_version_conditions_are_immutable'; end if;
 if tg_op='UPDATE' and (to_jsonb(new)->>'organization_id') is distinct from (to_jsonb(old)->>'organization_id') then raise exception 'catalog_identity_is_immutable'; end if;
 if tg_op='UPDATE' and tg_table_name='commercial_conditions' then
  if (to_jsonb(new)->>'id') is distinct from (to_jsonb(old)->>'id') or (to_jsonb(new)->>'product_table_version_id') is distinct from (to_jsonb(old)->>'product_table_version_id') then raise exception 'catalog_identity_is_immutable'; end if;
 end if;
 if tg_op='DELETE' then return old; end if;
 return new;
end $$;


--
-- Name: guard_contract_type_catalog(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_contract_type_catalog() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if tg_op='INSERT' then
    if current_user in ('authenticated','anon') then
      if new.organization_id is null then raise exception 'global_contract_type_is_platform_managed'; end if;
      if not public.has_active_organization_role(new.organization_id,array['admin','manager']) then raise exception 'not_authorized'; end if;
      new.created_by:=auth.uid();
      if new.tech_key is null or length(btrim(new.tech_key))<8 then new.tech_key:='tenant_'||replace(gen_random_uuid()::text,'-',''); end if;
    end if;
  else
    if old.organization_id is null and current_user in ('authenticated','anon') then raise exception 'global_contract_type_is_platform_managed'; end if;
    if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id or new.tech_key is distinct from old.tech_key or new.created_at is distinct from old.created_at or new.created_by is distinct from old.created_by then raise exception 'contract_type_identity_is_immutable'; end if;
    new.updated_at:=now();
  end if;
  return new;
end $$;


--
-- Name: guard_contract_type_setting(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_contract_type_setting() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_org uuid;
begin
  select organization_id into v_org from public.contract_types where id=new.contract_type_id;
  if v_org is not null and v_org is distinct from new.organization_id then raise exception 'cross_tenant_contract_type'; end if;
  if current_user in ('authenticated','anon') then new.updated_by:=auth.uid(); end if;
  new.updated_at:=now();
  return new;
end $$;


--
-- Name: guard_customer_document_evidence_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_customer_document_evidence_immutable() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if new.organization_id is distinct from old.organization_id
     or new.customer_id is distinct from old.customer_id
     or new.document_type_id is distinct from old.document_type_id
     or new.version is distinct from old.version
     or new.storage_bucket is distinct from old.storage_bucket
     or new.storage_path is distinct from old.storage_path
     or new.original_file_name is distinct from old.original_file_name
     or new.mime_type is distinct from old.mime_type
     or new.file_size_bytes is distinct from old.file_size_bytes
     or new.sha256 is distinct from old.sha256
     or new.issued_at is distinct from old.issued_at
     or new.expires_at is distinct from old.expires_at
     or new.uploaded_by is distinct from old.uploaded_by
     or new.created_at is distinct from old.created_at then
    raise exception 'customer_document_evidence_is_immutable_create_new_version';
  end if;
  return new;
end;
$$;


--
-- Name: guard_customer_timeline_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_customer_timeline_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if tg_op='UPDATE' then raise exception 'customer_timeline_is_append_only'; end if;
 if current_user in ('authenticated','anon','service_role') and current_setting('corban.timeline_rpc',true) is distinct from 'on' then
  raise exception 'timeline_write_requires_governed_rpc';
 end if;
 return new;
end $$;


--
-- Name: guard_digitization_job_documents_ready(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_digitization_job_documents_ready() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if not exists (
    select 1 from public.proposals_v2 p
    where p.organization_id = new.organization_id
      and p.id = new.proposal_id
      and p.status = 'ready_for_digitization'
  ) then
    raise exception 'proposal_not_ready_for_digitization';
  end if;

  -- If the proposal route has a published checklist, its requirements must have
  -- been instantiated. This prevents an empty requirement set from passing open.
  if exists (
    select 1
    from public.proposals_v2 p
    join public.product_table_versions v
      on v.organization_id = p.organization_id and v.id = p.product_table_version_id
    join public.product_tables pt
      on pt.organization_id = v.organization_id and pt.id = v.product_table_id
    join public.document_checklist_templates t
      on t.organization_id = pt.organization_id and t.route_id = pt.route_id
    where p.organization_id = new.organization_id
      and p.id = new.proposal_id
      and t.status = 'published'
  ) and not exists (
    select 1 from public.proposal_document_requirements r
    where r.organization_id = new.organization_id
      and r.proposal_id = new.proposal_id
  ) then
    raise exception 'published_checklist_requirements_not_instantiated';
  end if;

  if exists (
    select 1 from public.proposal_document_requirements r
    where r.organization_id = new.organization_id
      and r.proposal_id = new.proposal_id
      and r.required_snapshot = true
      and r.status not in ('validated','waived')
  ) then
    raise exception 'required_documents_not_ready';
  end if;
  return new;
end;
$$;


--
-- Name: guard_document_checklist_item_draft_parent(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_document_checklist_item_draft_parent() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if not exists (
    select 1 from public.document_checklist_templates t
    where t.organization_id = new.organization_id
      and t.id = new.template_id
      and t.status = 'draft'
  ) then
    raise exception 'checklist_items_require_draft_template';
  end if;
  return new;
end;
$$;


--
-- Name: guard_document_checklist_template_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_document_checklist_template_immutable() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if old.status = 'draft' and new.status not in ('draft','published') then
    raise exception 'invalid_checklist_template_transition';
  end if;
  if old.status = 'published' and new.status not in ('published','superseded') then
    raise exception 'invalid_checklist_template_transition';
  end if;
  if old.status = 'superseded' and new.status is distinct from old.status then
    raise exception 'terminal_checklist_template_status';
  end if;
  if old.status <> 'draft' and (
    new.organization_id is distinct from old.organization_id
    or new.route_id is distinct from old.route_id
    or new.version is distinct from old.version
    or new.name is distinct from old.name
    or new.created_at is distinct from old.created_at
  ) then
    raise exception 'published_checklist_template_is_immutable';
  end if;
  return new;
end;
$$;


--
-- Name: guard_factor_batch(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_factor_batch() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_org uuid;
begin
  select p.organization_id into v_org from public.commercial_factor_profiles p where p.id=coalesce(new.profile_id,old.profile_id);
  if v_org is distinct from coalesce(new.organization_id,old.organization_id) then raise exception 'factor_profile_cross_tenant'; end if;

  if tg_op='INSERT' then
    if current_user in ('authenticated','anon') and new.status<>'draft' then raise exception 'factor_batch_must_start_draft'; end if;
    if new.import_batch_id is not null then
      select organization_id into v_org from public.import_batches where id=new.import_batch_id;
      if v_org is distinct from new.organization_id then raise exception 'factor_import_batch_cross_tenant'; end if;
    end if;
    if current_user in ('authenticated','anon') then new.created_by:=auth.uid(); end if;
    return new;
  end if;

  if tg_op='DELETE' then
    if old.status='published' then raise exception 'published_factor_batch_is_immutable'; end if;
    return old;
  end if;

  if old.status='published' then raise exception 'published_factor_batch_is_immutable'; end if;
  if new.id is distinct from old.id
     or new.organization_id is distinct from old.organization_id
     or new.profile_id is distinct from old.profile_id
     or new.effective_date is distinct from old.effective_date
     or new.revision is distinct from old.revision
     or new.source_kind is distinct from old.source_kind
     or new.import_batch_id is distinct from old.import_batch_id
     or new.created_by is distinct from old.created_by
     or new.created_at is distinct from old.created_at
  then raise exception 'factor_batch_identity_is_immutable'; end if;
  if old.status='draft' and new.status='published' then
    if current_user in ('authenticated','anon') and current_setting('corban.factor_publish',true) is distinct from 'on' then
      raise exception 'factor_publish_requires_governed_rpc';
    end if;
    new.published_at:=coalesce(new.published_at,now());
  elsif new.status is distinct from old.status then
    raise exception 'invalid_factor_batch_transition';
  end if;
  return new;
end $$;


--
-- Name: guard_factor_entry(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_factor_entry() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_status text; v_org uuid;
begin
  select b.status,b.organization_id into v_status,v_org from public.commercial_factor_batches b where b.id=coalesce(new.batch_id,old.batch_id);
  if v_org is distinct from coalesce(new.organization_id,old.organization_id) then raise exception 'factor_batch_cross_tenant'; end if;
  if v_status='published' then raise exception 'published_factor_entries_are_immutable'; end if;
  if tg_op='UPDATE' and (
       new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.batch_id is distinct from old.batch_id
       or new.created_at is distinct from old.created_at
     ) then raise exception 'factor_entry_identity_is_immutable'; end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;


--
-- Name: guard_factor_profile(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_factor_profile() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_route record; v_batch_org uuid;
begin
  if tg_op='INSERT' then
    if current_user in ('authenticated','anon') then new.created_by:=auth.uid(); end if;
  else
    if new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.tech_key is distinct from old.tech_key
       or new.created_at is distinct from old.created_at
       or new.created_by is distinct from old.created_by
    then raise exception 'factor_profile_identity_is_immutable'; end if;
    new.updated_at:=now();
  end if;

  if new.product_table_id is not null then
    select r.org_bank_id,r.org_agreement_id
      into v_route
    from public.product_tables t
    join public.organization_product_routes r on r.id=t.route_id and r.organization_id=t.organization_id
    where t.id=new.product_table_id and t.organization_id=new.organization_id;
    if not found then raise exception 'factor_product_table_not_found'; end if;
    if v_route.org_bank_id is distinct from new.org_bank_id then raise exception 'factor_bank_mismatch'; end if;
    if new.org_agreement_id is not null and v_route.org_agreement_id is distinct from new.org_agreement_id then raise exception 'factor_agreement_mismatch'; end if;
  end if;
  return new;
end $$;


--
-- Name: guard_financial_event_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_financial_event_insert() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare o record; v_already numeric;
begin
 if new.event_type in ('commission_reported','payment_received','downstream_paid') then
  if current_setting('corban.financial_evidence_rpc',true) is distinct from 'on' then raise exception 'financial_fact_requires_evidence_rpc'; end if;
 elsif new.event_type='commission_expected' then
  if current_setting('corban.financial_expected_rpc',true) is distinct from 'on' then raise exception 'expected_commission_requires_governed_rpc'; end if;
 elsif new.event_type='reversal' then
  if current_setting('corban.financial_reversal_rpc',true) is distinct from 'on' then raise exception 'financial_reversal_requires_governed_rpc'; end if;
  if current_setting('transaction_isolation') is distinct from 'read committed' then raise exception 'reversal_requires_read_committed'; end if;
  perform pg_advisory_xact_lock(hashtextextended('financial_reversal:'||new.reverses_event_id::text,0));
  select * into o from public.financial_events where id=new.reverses_event_id;
  if not found then raise exception 'reversed_event_not_found'; end if;
  if o.organization_id<>new.organization_id or o.proposal_id is distinct from new.proposal_id or o.component_type is distinct from new.component_type or o.currency<>new.currency then raise exception 'reversal_target_mismatch'; end if;
  if o.event_type in ('reversal','adjustment') then raise exception 'cannot_reverse_a_reversal_or_adjustment'; end if;
  if new.amount<=0 then raise exception 'invalid_reversal_amount'; end if;
  select coalesce(sum(amount),0) into v_already from public.financial_events where reverses_event_id=o.id and event_type='reversal';
  if v_already+new.amount>o.amount then raise exception 'reversal_exceeds_original'; end if;
 else raise exception 'financial_event_type_not_governed'; end if;
 return new;
end $$;


--
-- Name: guard_import_batch_adapter_contract(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_import_batch_adapter_contract() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v text;
begin
 if new.adapter_id is null then
   if new.adapter_contract_version is not null then raise exception 'adapter_contract_version requires adapter_id'; end if;
   return new;
 end if;
 select contract_version into v from public.integration_adapters where id=new.adapter_id and status <> 'disabled';
 if v is null then raise exception 'adapter is missing or disabled'; end if;
 if new.adapter_contract_version is null then new.adapter_contract_version:=v;
 elsif new.adapter_contract_version<>v then raise exception 'adapter contract version mismatch'; end if;
 return new;
end $$;


--
-- Name: guard_import_batch_adapter_write_once(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_import_batch_adapter_write_once() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if old.adapter_id is not null and (new.adapter_id is distinct from old.adapter_id or new.adapter_contract_version is distinct from old.adapter_contract_version) then raise exception 'batch_adapter_immutable'; end if;
 if new.adapter_id is distinct from old.adapter_id and current_setting('corban.adapter_attach_rpc',true) is distinct from 'on' then raise exception 'adapter_lineage_requires_governed_rpc'; end if;
 return new;
end $$;


--
-- Name: guard_import_conflict_row_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_import_conflict_row_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare c_org uuid; r_org uuid; c_batch uuid; r_batch uuid;
begin
 if current_setting('corban.import_conflict_rpc',true) is distinct from 'on' then raise exception 'import_conflict_requires_governed_rpc'; end if;
 select organization_id,batch_id into c_org,c_batch from public.import_conflicts where id=new.conflict_id;
 select organization_id,batch_id into r_org,r_batch from public.import_raw_rows where id=new.raw_row_id;
 if c_org is null or c_org<>new.organization_id or r_org is distinct from c_org or r_batch is distinct from c_batch then raise exception 'import_conflict_tenant_or_batch_mismatch'; end if;
 return new;
end $$;


--
-- Name: guard_import_conflict_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_import_conflict_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare b_org uuid;
begin
 if tg_op='INSERT' then
  if current_setting('corban.import_conflict_rpc',true) is distinct from 'on' then raise exception 'import_conflict_requires_governed_rpc'; end if;
  select organization_id into b_org from public.import_batches where id=new.batch_id;
  if b_org is null or b_org<>new.organization_id then raise exception 'import_conflict_tenant_mismatch'; end if;
  return new;
 end if;
 -- UPDATE: only the resolution columns may change, only open -> resolved/dismissed, and only with a note.
 if new.organization_id is distinct from old.organization_id or new.batch_id is distinct from old.batch_id or new.kind is distinct from old.kind
    or new.severity is distinct from old.severity or new.identity_key is distinct from old.identity_key or new.detail is distinct from old.detail
    or new.fingerprint is distinct from old.fingerprint or new.created_at is distinct from old.created_at or new.auto_publish_allowed is distinct from old.auto_publish_allowed then
  raise exception 'import_conflict_evidence_is_immutable';
 end if;
 if new.status is distinct from old.status then
  if old.status<>'open' then raise exception 'import_conflict_already_closed'; end if;
  if nullif(btrim(new.resolution_note),'') is null then raise exception 'resolution_note_required'; end if;
  new.resolved_by:=(select auth.uid()); new.resolved_at:=now();
 elsif new.resolution_note is distinct from old.resolution_note or new.resolved_by is distinct from old.resolved_by or new.resolved_at is distinct from old.resolved_at then
  raise exception 'import_conflict_evidence_is_immutable';
 end if;
 return new;
end $$;


--
-- Name: guard_import_layout_mapping(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_import_layout_mapping() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if current_user in ('authenticated','anon') and current_setting('corban.mapping_rpc',true) is distinct from 'on' then raise exception 'mapping_write_requires_governed_rpc'; end if;
 if tg_op='UPDATE' then
  -- a confirmed mapping is history: the only allowed change is confirmed -> superseded
  if old.status<>'confirmed' or new.status<>'superseded' or (to_jsonb(new)-'status') is distinct from (to_jsonb(old)-'status') then raise exception 'mapping_is_immutable'; end if;
 end if;
 return new;
end $$;


--
-- Name: guard_import_match_candidate_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_import_match_candidate_insert() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$ begin if current_setting('corban.import_match_rpc',true) is distinct from 'on' then raise exception 'match_candidate_requires_governed_rpc'; end if; return new; end $$;


--
-- Name: guard_import_normalized_row_consistency(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_import_normalized_row_consistency() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare raw_org uuid;
begin
 select organization_id into raw_org from public.import_raw_rows where id=new.raw_row_id;
 if raw_org is null or raw_org<>new.organization_id then raise exception 'normalized row organization mismatch'; end if;
 if jsonb_typeof(new.normalized_payload)<>'object' then raise exception 'normalized_payload must be object'; end if;
 if new.record_kind in ('proposal','commission','payment','status') and coalesce(btrim(new.external_proposal_number),'')='' then
   raise exception 'external proposal number required for record kind %',new.record_kind;
 end if;
 return new;
end $$;


--
-- Name: guard_import_raw_row_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_import_raw_row_immutable() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin raise exception 'import_raw_rows are immutable; append a new batch/row instead'; end $$;


--
-- Name: guard_integration_artifact_consistency(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_integration_artifact_consistency() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare r_org uuid; b_org uuid;
begin
 select organization_id into r_org from public.integration_runs where id=new.run_id;
 if r_org is null or r_org<>new.organization_id then raise exception 'artifact organization mismatch'; end if;
 if new.import_batch_id is not null then
   select organization_id into b_org from public.import_batches where id=new.import_batch_id;
   if b_org is null or b_org<>new.organization_id then raise exception 'artifact batch organization mismatch'; end if;
 end if;
 return new;
end $$;


--
-- Name: guard_integration_artifact_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_integration_artifact_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare r record;
begin
 if tg_op<>'INSERT' then raise exception 'integration_artifact_is_append_only'; end if;
 if current_setting('corban.integration_run_rpc',true) is distinct from 'on' then raise exception 'integration_artifact_requires_governed_rpc'; end if;
 if public.integration_content_has_secret(new.payload::text) then raise exception 'integration_artifact_secret_like_content'; end if;
 select organization_id,status into r from public.integration_runs where id=new.run_id;
 if r.organization_id is null or r.organization_id<>new.organization_id then raise exception 'artifact organization mismatch'; end if;
 if r.status<>'running' then raise exception 'artifact_requires_running_run'; end if;
 if octet_length(new.payload::text)>200000 then raise exception 'artifact_payload_too_large'; end if;
 return new;
end $$;


--
-- Name: guard_integration_binding_no_secrets(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_integration_binding_no_secrets() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare k text;
begin
 for k in select lower(key) from jsonb_object_keys(coalesce(new.settings,'{}'::jsonb)) key loop
   if k in ('password','senha','secret','api_key','apikey','token','access_token','refresh_token','client_secret','authorization') then
     raise exception 'integration binding settings cannot contain credentials or tokens';
   end if;
 end loop;
 return new;
end $$;


--
-- Name: guard_integration_run_consistency(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_integration_run_consistency() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare b_org uuid; b_adapter uuid; b_enabled boolean; a_status text; a_caps jsonb;
begin
 select organization_id,adapter_id,enabled into b_org,b_adapter,b_enabled from public.integration_source_bindings where id=new.binding_id;
 if b_org is null or b_org<>new.organization_id or b_adapter<>new.adapter_id or not b_enabled then
   raise exception 'invalid or disabled integration binding';
 end if;
 select status,capabilities into a_status,a_caps from public.integration_adapters where id=new.adapter_id;
 if a_status='disabled' or not (a_caps ? new.capability) then raise exception 'adapter capability unavailable'; end if;
 if new.status='running' and new.started_at is null then new.started_at:=now(); end if;
 if new.status in ('succeeded','failed','cancelled') and new.finished_at is null then new.finished_at:=now(); end if;
 if new.status='succeeded' and new.error_code is not null then raise exception 'successful run cannot have error_code'; end if;
 return new;
end $$;


--
-- Name: guard_integration_run_state(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_integration_run_state() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare ok boolean; p_org uuid;
begin
 if tg_op='DELETE' then raise exception 'integration_run_cannot_be_deleted'; end if;
 if current_setting('corban.integration_run_rpc',true) is distinct from 'on' then raise exception 'integration_run_requires_governed_rpc'; end if;
 if public.integration_content_has_secret(new.metadata::text) or public.integration_content_has_secret(new.error_message) or public.integration_content_has_secret(new.reexecution_reason) then raise exception 'integration_run_secret_like_content'; end if;
 if tg_op='INSERT' then
  if new.status<>'queued' or new.attempt_count<>0 or new.terminal or new.claim_token is not null then raise exception 'integration_run_must_start_queued'; end if;
  if new.parent_run_id is not null then
   select organization_id into p_org from public.integration_runs where id=new.parent_run_id;
   if p_org is null or p_org<>new.organization_id then raise exception 'integration_run_parent_tenant_mismatch'; end if;
  end if;
  return new;
 end if;
 if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id or new.binding_id is distinct from old.binding_id
    or new.adapter_id is distinct from old.adapter_id or new.capability is distinct from old.capability or new.request_fingerprint is distinct from old.request_fingerprint
    or new.max_attempts is distinct from old.max_attempts or new.created_at is distinct from old.created_at or new.created_by is distinct from old.created_by
    or new.parent_run_id is distinct from old.parent_run_id or new.reexecution_reason is distinct from old.reexecution_reason then
  raise exception 'integration_run_identity_is_immutable';
 end if;
 ok:=(old.status='queued' and new.status in ('running','cancelled'))
  or (old.status='running' and new.status in ('running','succeeded','failed'))
  or (old.status='failed' and new.status in ('running','cancelled') and not old.terminal and old.attempt_count<old.max_attempts);
 if not ok then raise exception 'illegal_integration_run_transition: % -> %',old.status,new.status; end if;
 if new.status='running' and new.attempt_count<>old.attempt_count+1 then raise exception 'integration_run_attempt_must_increment'; end if;
 if new.status<>'running' and new.attempt_count<>old.attempt_count then raise exception 'integration_run_attempt_is_derived'; end if;
 if new.status='succeeded' then
  if new.error_code is not null or new.terminal then raise exception 'successful run cannot carry an error'; end if;
  if not exists(select 1 from public.integration_run_artifacts a where a.run_id=new.id and a.organization_id=new.organization_id and a.artifact_kind='response_metadata') then raise exception 'success_requires_response_evidence'; end if;
 end if;
 if new.status='failed' and nullif(btrim(new.error_code),'') is null then raise exception 'failed_run_requires_error_code'; end if;
 if new.status in ('succeeded','failed','cancelled') then new.claim_token:=null; new.lease_expires_at:=null; new.finished_at:=coalesce(new.finished_at,now()); end if;
 if new.status='running' then new.finished_at:=null; end if;
 new.updated_at:=now();
 return new;
end $$;


--
-- Name: guard_invitation_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_invitation_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if tg_op='DELETE' then raise exception 'invitation_delete_forbidden'; end if;
 if current_user in ('authenticated','anon') and current_setting('corban.membership_rpc',true) is distinct from 'on' then raise exception 'invitation_write_requires_governed_rpc'; end if;
 if tg_op='UPDATE' then
  if new.organization_id is distinct from old.organization_id or new.email is distinct from old.email or new.role is distinct from old.role
     or new.invited_by is distinct from old.invited_by or new.created_at is distinct from old.created_at or new.expires_at is distinct from old.expires_at then
   raise exception 'invitation_identity_immutable'; end if;
  if old.status<>'pending' then raise exception 'invitation_already_resolved'; end if;
 end if;
 return new;
end $$;


--
-- Name: guard_membership_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_membership_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if current_user in ('authenticated','anon') then
  if tg_op='DELETE' then raise exception 'membership_delete_forbidden'; end if;
  if current_setting('corban.membership_rpc',true) is distinct from 'on' then raise exception 'membership_write_requires_governed_rpc'; end if;
 end if;
 if tg_op='UPDATE' and (new.organization_id is distinct from old.organization_id or new.user_id is distinct from old.user_id) then raise exception 'membership_identity_immutable'; end if;
 if tg_op='DELETE' then return old; end if;
 return new;
end $$;


--
-- Name: guard_operational_pipeline_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_operational_pipeline_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if tg_table_name='operational_events' and tg_op<>'INSERT' then raise exception 'operational_events_are_append_only'; end if;
 if current_setting('corban.operational_rpc',true) is distinct from 'on' then raise exception 'operational_write_requires_governed_rpc'; end if;
 return new;
end $$;


--
-- Name: guard_org_catalog_row(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_org_catalog_row() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if tg_op='INSERT' then
  if current_user in ('authenticated','anon') then new.created_by:=auth.uid(); end if;
 else
  if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id or new.tech_key is distinct from old.tech_key or new.created_at is distinct from old.created_at then raise exception 'catalog_identity_is_immutable'; end if;
  if (to_jsonb(new)->>'template_id') is distinct from (to_jsonb(old)->>'template_id') then raise exception 'catalog_identity_is_immutable'; end if;
  new.updated_at:=now();
 end if;
 if tg_table_name='organization_agreements' and (to_jsonb(new)->>'template_id') is not null then
  -- an agreement enabled from the national list carries the template's official name (the tenant may not relabel it into something else)
  select t.name into new.name from public.national_agreement_templates t where t.id=new.template_id and t.is_active;
  if new.name is null then raise exception 'national_template_not_available'; end if;
 end if;
 return new;
end $$;


--
-- Name: guard_payout_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_payout_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if tg_op in ('UPDATE','DELETE') and tg_table_name in ('payout_policy_versions','payout_policy_items') then raise exception 'payout_policy_versions_are_immutable'; end if;
 if tg_op='INSERT' and current_user in ('authenticated','anon') and current_setting('corban.payout_rpc',true) is distinct from 'on' then raise exception 'payout_write_requires_governed_rpc'; end if;
 if tg_op='DELETE' then return old; end if;
 return new;
end $$;


--
-- Name: guard_product_table_version_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_product_table_version_immutable() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_catalog_governed boolean:=coalesce(current_setting('corban.catalog_rpc',true),'')='on';
begin
  if old.status='draft' and new.status not in ('draft','published') then
    raise exception 'invalid_product_table_version_transition';
  end if;
  if old.status='published' and new.status not in ('published','superseded','expired') then
    raise exception 'invalid_product_table_version_transition';
  end if;
  if old.status in ('superseded','expired') and new.status is distinct from old.status then
    raise exception 'terminal_product_table_version_status';
  end if;

  if old.status<>'draft' then
    if new.organization_id is distinct from old.organization_id
       or new.product_table_id is distinct from old.product_table_id
       or new.version is distinct from old.version
       or new.effective_from is distinct from old.effective_from
       or new.term_min is distinct from old.term_min
       or new.term_max is distinct from old.term_max
       or new.rate is distinct from old.rate
       or new.coefficient is distinct from old.coefficient
       or new.metadata is distinct from old.metadata
       or new.created_at is distinct from old.created_at
    then
      raise exception 'published_product_table_version_is_immutable';
    end if;

    if new.effective_until is distinct from old.effective_until and not v_catalog_governed then
      raise exception 'published_product_table_version_is_immutable';
    end if;
  end if;
  return new;
end
$$;


--
-- Name: guard_proposal_commercial_route_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_proposal_commercial_route_insert() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
 if current_setting('corban.commercial_route_rpc',true) is distinct from 'on' then raise exception 'commercial_snapshot_requires_freeze_rpc'; end if;
 return new;
end $$;


--
-- Name: guard_proposal_commercial_snapshot(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_proposal_commercial_snapshot() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if tg_op='INSERT'
     or (tg_op='UPDATE' and old.status='draft'
         and new.product_table_version_id is distinct from old.product_table_version_id) then
    if not exists(
      select 1 from public.product_table_versions v
      where v.organization_id=new.organization_id
        and v.id=new.product_table_version_id
        and v.status='published'
    ) then
      raise exception 'proposal_requires_published_product_table_version';
    end if;
  end if;

  if tg_op='UPDATE' and old.status<>'draft' then
    if new.status='draft' then raise exception 'proposal_cannot_return_to_draft'; end if;
    if new.organization_id is distinct from old.organization_id
       or new.customer_id is distinct from old.customer_id
       or new.simulation_id is distinct from old.simulation_id
       or new.product_table_version_id is distinct from old.product_table_version_id
       or new.seller_id is distinct from old.seller_id
       or new.requested_amount is distinct from old.requested_amount
       or new.released_amount is distinct from old.released_amount
       or new.installment_amount is distinct from old.installment_amount
       or new.term is distinct from old.term
       or new.rate is distinct from old.rate
       or new.coefficient is distinct from old.coefficient
       or new.expected_commission_amount is distinct from old.expected_commission_amount
       or new.customer_snapshot is distinct from old.customer_snapshot
       or new.commercial_snapshot is distinct from old.commercial_snapshot
       or new.attribution_snapshot is distinct from old.attribution_snapshot
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'proposal_commercial_snapshot_is_immutable_after_draft';
    end if;
  end if;
  return new;
end
$$;


--
-- Name: guard_proposal_document_requirement_snapshot(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_proposal_document_requirement_snapshot() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if new.organization_id is distinct from old.organization_id
     or new.proposal_id is distinct from old.proposal_id
     or new.checklist_item_id is distinct from old.checklist_item_id
     or new.document_type_id is distinct from old.document_type_id
     or new.label_snapshot is distinct from old.label_snapshot
     or new.required_snapshot is distinct from old.required_snapshot
     or new.created_at is distinct from old.created_at then
    raise exception 'proposal_document_requirement_snapshot_is_immutable';
  end if;
  return new;
end;
$$;


--
-- Name: guard_proposal_document_requirement_workflow(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_proposal_document_requirement_workflow() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_role text;
begin
  if new.status is distinct from old.status then
    select m.role into v_role
    from public.organization_memberships m
    where m.organization_id=new.organization_id and m.user_id=auth.uid() and m.status='active';

    if old.status='missing' and new.status not in ('attached','waived') then
      raise exception 'invalid_document_requirement_transition';
    elsif old.status='attached' and new.status not in ('validated','rejected','waived') then
      raise exception 'invalid_document_requirement_transition';
    elsif old.status='rejected' and new.status not in ('attached','waived') then
      raise exception 'invalid_document_requirement_transition';
    elsif old.status in ('validated','waived') then
      raise exception 'terminal_document_requirement_status';
    end if;

    if new.status in ('validated','rejected','waived')
       and v_role not in ('admin','manager','supervisor') then
      raise exception 'document_decision_requires_privileged_role';
    end if;
  end if;

  if new.status='validated' and old.status is distinct from 'validated' then
    if not exists (
      select 1 from public.proposal_document_links l
      join public.customer_documents d
        on d.organization_id=l.organization_id and d.id=l.customer_document_id
      where l.organization_id=new.organization_id
        and l.requirement_id=new.id
        and d.document_type_id=new.document_type_id
        and d.status='active'
    ) then raise exception 'validated_requirement_requires_active_matching_document'; end if;
  end if;

  if new.status='waived' and old.status is distinct from 'waived' then
    if auth.uid() is null or new.exception_approved_by is distinct from auth.uid() then
      raise exception 'waiver_approver_must_be_current_user';
    end if;
    if v_role not in ('admin','manager','supervisor') then
      raise exception 'waiver_requires_privileged_role';
    end if;
  end if;
  return new;
end;
$$;


--
-- Name: guard_proposal_status_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_proposal_status_transition() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if new.status is not distinct from old.status then return new; end if;
 if old.status='draft' and new.status not in ('documents_pending','ready_for_digitization','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status='documents_pending' and new.status not in ('ready_for_digitization','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status='ready_for_digitization' and new.status not in ('documents_pending','digitization','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status='digitization' and new.status not in ('submitted','rejected','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status='submitted' and new.status not in ('approved','rejected','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status='approved' and new.status not in ('paid','cancelled') then raise exception 'invalid_proposal_status_transition';
 elsif old.status in ('paid','rejected','cancelled') then raise exception 'terminal_proposal_status'; end if;
 if new.status='paid' and current_setting('corban.paid_evidence_rpc',true) is distinct from 'on' then raise exception 'paid_requires_confirmed_operational_evidence'; end if;
 return new;
end $$;


--
-- Name: guard_proposal_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_proposal_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if current_user in ('authenticated','anon','service_role')
    and current_setting('corban.proposal_rpc',true) is distinct from 'on'
    and current_setting('corban.paid_evidence_rpc',true) is distinct from 'on'
    and current_setting('corban.proposal_seller_rpc',true) is distinct from 'on' then
  raise exception 'proposal_write_requires_governed_rpc';
 end if;

 if tg_op='UPDATE' and new.seller_id is distinct from old.seller_id then
  if current_setting('corban.proposal_seller_rpc',true) is distinct from 'on' then
    raise exception 'proposal_seller_change_requires_governed_rpc';
  end if;
  if old.status<>'draft' or exists(
    select 1 from public.proposal_commercial_snapshots s
    where s.proposal_id=old.id and s.organization_id=old.organization_id
  ) then
    raise exception 'proposal_seller_is_frozen';
  end if;
 end if;

 if tg_op='UPDATE' and (
    new.id is distinct from old.id
    or new.organization_id is distinct from old.organization_id
    or new.customer_id is distinct from old.customer_id
    or new.simulation_id is distinct from old.simulation_id
    or new.product_table_version_id is distinct from old.product_table_version_id
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
 ) then
  raise exception 'proposal_identity_is_immutable';
 end if;
 return new;
end
$$;


--
-- Name: guard_reconciliation_case_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_reconciliation_case_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
 if current_setting('corban.reconciliation_rpc',true)='on' then return new; end if;
 if tg_op='INSERT' then raise exception 'reconciliation_case_requires_governed_rpc'; end if;
 if new.organization_id is distinct from old.organization_id or new.proposal_id is distinct from old.proposal_id or new.channel_id is distinct from old.channel_id or new.component_type is distinct from old.component_type or new.expected_amount is distinct from old.expected_amount or new.reported_amount is distinct from old.reported_amount or new.settled_amount is distinct from old.settled_amount then raise exception 'reconciliation_amounts_are_derived'; end if;
 if old.status='resolved' and (new.status is distinct from old.status or new.resolution_note is distinct from old.resolution_note or new.resolved_by is distinct from old.resolved_by or new.resolved_at is distinct from old.resolved_at) then
  raise exception 'reconciliation_resolution_is_immutable';
 end if;
 if new.status is distinct from old.status then
  if new.status<>'resolved' then raise exception 'reconciliation_status_is_derived'; end if;
  if nullif(btrim(new.resolution_note),'') is null then raise exception 'resolution_note_required'; end if;
  if length(btrim(new.resolution_note))<10 or length(btrim(new.resolution_note))>2000 then raise exception 'resolution_note_length_invalid'; end if;
  new.resolved_by:=(select auth.uid()); new.resolved_at:=now();
 elsif new.resolution_note is distinct from old.resolution_note or new.resolved_by is distinct from old.resolved_by or new.resolved_at is distinct from old.resolved_at then
  raise exception 'resolution_only_via_resolve';
 end if;
 return new;
end $$;


--
-- Name: guard_seller_bank_alias(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_seller_bank_alias() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if tg_op='DELETE' then raise exception 'seller_bank_alias_delete_forbidden'; end if;

  new.source_key:=lower(btrim(new.source_key));
  new.external_user:=btrim(new.external_user);
  new.external_user_normalized:=public.normalize_external_user(new.external_user);

  if new.source_key='' or new.external_user_normalized is null then
    raise exception 'seller_bank_alias_values_required';
  end if;

  if tg_op='UPDATE' then
    if new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.seller_id is distinct from old.seller_id
       or new.created_at is distinct from old.created_at
       or new.created_by is distinct from old.created_by
    then raise exception 'seller_bank_alias_identity_immutable'; end if;
    new.updated_at:=now();
    if current_user in ('authenticated','anon') then new.updated_by:=auth.uid(); end if;
  elsif current_user in ('authenticated','anon') then
    new.created_by:=auth.uid();
    new.updated_by:=auth.uid();
  end if;

  if not exists(
    select 1 from public.commercial_sellers s
    where s.organization_id=new.organization_id
      and s.id=new.seller_id
      and s.is_active
  ) then raise exception 'active_seller_required'; end if;

  return new;
end
$$;


--
-- Name: guard_seller_catalog_row(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_seller_catalog_row() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_matrix uuid;
begin
  if tg_op='INSERT' then
    if tg_table_name='commercial_sellers'
       and (to_jsonb(new)->>'branch_id') is null then
      select b.id into v_matrix
      from public.organization_branches b
      where b.organization_id=new.organization_id
        and b.branch_type='matrix'
        and b.is_active
      limit 1;
      if v_matrix is null then raise exception 'active_matrix_required'; end if;
      new.branch_id:=v_matrix;
    end if;

    if current_user in ('authenticated','anon') then
      new.created_by:=auth.uid();

      if tg_table_name='commercial_sellers'
         and nullif(to_jsonb(new)->>'user_id','') is not null
         and current_setting('corban.seller_access_rpc',true) is distinct from 'on' then
        raise exception 'seller_user_binding_requires_governed_rpc';
      end if;
    end if;
  else
    if new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.tech_key is distinct from old.tech_key
       or new.created_at is distinct from old.created_at
       or new.created_by is distinct from old.created_by
    then raise exception 'seller_identity_is_immutable'; end if;

    if tg_table_name='commercial_sellers'
       and (to_jsonb(new)->>'user_id') is distinct from (to_jsonb(old)->>'user_id')
       and current_user in ('authenticated','anon')
       and current_setting('corban.seller_access_rpc',true) is distinct from 'on' then
      raise exception 'seller_user_binding_requires_governed_rpc';
    end if;

    new.updated_at:=now();
  end if;
  return new;
end
$$;


--
-- Name: guard_seller_commission_snapshot(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_seller_commission_snapshot() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if tg_op in ('UPDATE','DELETE') then
    raise exception 'seller_commission_snapshot_is_immutable';
  end if;
  if current_user in ('authenticated','anon')
     and current_setting('corban.seller_commission_snapshot',true) is distinct from 'on' then
    raise exception 'seller_commission_snapshot_write_requires_governed_path';
  end if;
  return new;
end
$$;


--
-- Name: guard_seller_profile_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_seller_profile_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if current_user in ('authenticated','anon')
     and current_setting('corban.seller_profile_rpc',true) is distinct from 'on'
  then raise exception 'seller_profile_write_requires_governed_rpc'; end if;
  if tg_op='DELETE' then raise exception 'seller_profile_delete_forbidden'; end if;
  return new;
end
$$;


--
-- Name: guard_seller_sub_rule(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_seller_sub_rule() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_category text;
begin
  if tg_op='DELETE' then
    if old.status='published' then raise exception 'published_sub_rule_is_immutable'; end if;
    return old;
  end if;

  select s.seller_category into v_category
  from public.commercial_sellers s
  where s.id=new.seller_id and s.organization_id=new.organization_id;

  if v_category is distinct from 'sub' then raise exception 'sub_rule_requires_sub_seller'; end if;

  if tg_op='UPDATE' then
    if old.status='published' then raise exception 'published_sub_rule_is_immutable'; end if;
    if new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.seller_id is distinct from old.seller_id
       or new.version is distinct from old.version
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at
    then raise exception 'sub_rule_identity_is_immutable'; end if;
    if old.status='draft' and new.status='published' then
      if current_user in ('authenticated','anon') and current_setting('corban.seller_sub_publish',true) is distinct from 'on' then
        raise exception 'sub_rule_publish_requires_governed_rpc';
      end if;
      new.published_at:=coalesce(new.published_at,now());
    elsif new.status is distinct from old.status then
      raise exception 'invalid_sub_rule_transition';
    end if;
  elsif current_user in ('authenticated','anon') then
    if new.status<>'draft' then raise exception 'sub_rule_must_start_draft'; end if;
    new.created_by:=auth.uid();
  end if;
  return new;
end $$;


--
-- Name: guard_seller_supervision(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_seller_supervision() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_role text;
  v_status text;
begin
  if tg_op='DELETE' then raise exception 'seller_supervision_delete_forbidden'; end if;

  if current_user in ('authenticated','anon')
     and current_setting('corban.seller_access_rpc',true) is distinct from 'on' then
    raise exception 'seller_supervision_write_requires_governed_rpc';
  end if;

  select m.role,m.status into v_role,v_status
  from public.organization_memberships m
  where m.organization_id=new.organization_id
    and m.user_id=new.supervisor_user_id;

  if v_role is distinct from 'supervisor' or v_status is distinct from 'active' then
    raise exception 'active_supervisor_membership_required';
  end if;

  if not exists(
    select 1 from public.commercial_sellers s
    where s.organization_id=new.organization_id
      and s.id=new.seller_id
      and s.is_active
  ) then
    raise exception 'active_seller_required';
  end if;

  if tg_op='INSERT' then
    if current_user in ('authenticated','anon') then new.created_by:=auth.uid(); end if;
    new.updated_by:=new.created_by;
  else
    if new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.supervisor_user_id is distinct from old.supervisor_user_id
       or new.seller_id is distinct from old.seller_id
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at
    then raise exception 'seller_supervision_identity_is_immutable'; end if;
    if current_user in ('authenticated','anon') then new.updated_by:=auth.uid(); end if;
    new.updated_at:=now();
  end if;

  return new;
end
$$;


--
-- Name: guard_simulation_selected_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_simulation_selected_immutable() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if old.status in ('selected','expired','cancelled') then
    if new.organization_id is distinct from old.organization_id
       or new.customer_id is distinct from old.customer_id
       or new.product_table_version_id is distinct from old.product_table_version_id
       or new.requested_amount is distinct from old.requested_amount
       or new.released_amount is distinct from old.released_amount
       or new.installment_amount is distinct from old.installment_amount
       or new.term is distinct from old.term
       or new.rate is distinct from old.rate
       or new.coefficient is distinct from old.coefficient
       or new.expected_commission_amount is distinct from old.expected_commission_amount
       or new.input_snapshot is distinct from old.input_snapshot
       or new.result_snapshot is distinct from old.result_snapshot
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'selected_simulation_snapshot_is_immutable';
    end if;
  end if;

  if old.status='selected' and new.status is distinct from old.status then
    raise exception 'selected_simulation_is_terminal';
  end if;
  if old.status in ('expired','cancelled') and new.status is distinct from old.status then
    raise exception 'terminal_simulation_status';
  end if;
  return new;
end
$$;


--
-- Name: guard_simulation_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_simulation_write() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if current_user in ('authenticated','anon') then
  if tg_op='DELETE' then raise exception 'simulation_delete_forbidden'; end if;
  if current_setting('corban.simulation_rpc',true) is distinct from 'on' then raise exception 'simulation_write_requires_governed_rpc'; end if;
 end if;
 if tg_op='DELETE' then return old; end if;
 return new;
end $$;


--
-- Name: has_active_organization_role(uuid, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.has_active_organization_role(p_organization_id uuid, p_roles text[]) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
 select exists(select 1 from public.organization_memberships m where m.organization_id=p_organization_id and m.user_id=(select auth.uid()) and m.status='active' and m.role=any(p_roles));
$$;


--
-- Name: import_commercial_conditions(uuid, jsonb, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.import_commercial_conditions(p_version uuid, p_rows jsonb, p_policy_version uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
declare
 v public.product_table_versions%rowtype;
 e jsonb;
 i integer:=0;
 v_line integer;
 v_ct uuid;
 v_term_min integer;
 v_term_max integer;
 v_amount_min numeric;
 v_amount_max numeric;
 v_existing uuid;
 v_id uuid;
 v_msg text;
 v_errors jsonb:='[]'::jsonb;
 v_lines jsonb:='[]'::jsonb;
 v_seen text[]:='{}';
 v_key text;
 v_created integer:=0;
 v_updated integer:=0;
 v_known text[]:=array[
  'condition_range_conflict','invalid_term_range','invalid_amount_range','invalid_shares','duplicate_group_share','commission_group_not_found',
  'production_shares_exceed_received_commission','policy_not_found','policy_group_inactive',
  'coefficient_or_rate_required','invalid_received_commission','contract_type_not_found','condition_not_found','version_not_draft'
 ];
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into v from public.product_table_versions x where x.id=p_version;
 if not found then raise exception 'version_not_found'; end if;
 if not public.has_active_organization_role(v.organization_id,array['admin','manager']) then raise exception 'not_authorized'; end if;
 if v.status<>'draft' then raise exception 'version_not_draft'; end if;
 if p_rows is null or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)=0 then raise exception 'invalid_rows'; end if;
 if jsonb_array_length(p_rows)>500 then raise exception 'too_many_rows'; end if;

 perform 1 from public.product_table_versions x where x.id=p_version for update;

 for e in select * from jsonb_array_elements(p_rows) loop
  i:=i+1; v_line:=i+1; v_id:=null; v_existing:=null; v_amount_min:=null; v_amount_max:=null;
  begin
   if jsonb_typeof(e)<>'object' then raise exception 'invalid_row'; end if;
   if e->>'line' ~ '^[0-9]{1,6}$' then v_line:=(e->>'line')::integer; end if;
   begin
    v_ct:=(e->>'contract_type_id')::uuid;
    v_term_min:=coalesce(nullif(e->>'term_min',''),nullif(e->>'term',''))::integer;
    v_term_max:=coalesce(nullif(e->>'term_max',''),nullif(e->>'term_min',''),nullif(e->>'term',''))::integer;
    v_amount_min:=nullif(e->>'amount_min','')::numeric;
    v_amount_max:=nullif(e->>'amount_max','')::numeric;
   exception when others then raise exception 'invalid_row'; end;

   if v_ct is null or v_term_min is null or v_term_max is null or v_term_min<1 or v_term_max>600 or v_term_min>v_term_max
   then raise exception 'invalid_term_range'; end if;
   if (v_amount_min is null) <> (v_amount_max is null)
      or (v_amount_min is not null and (v_amount_min<0 or v_amount_max<v_amount_min or v_amount_max>999999999.99))
   then raise exception 'invalid_amount_range'; end if;

   v_key:=v_ct::text||'|'||v_term_min||'|'||v_term_max||'|'||
          coalesce(v_amount_min::text,'*')||'|'||coalesce(v_amount_max::text,'*');
   if v_key=any(v_seen) then raise exception 'duplicate_row'; end if;
   v_seen:=v_seen||v_key;

   select c.id into v_existing
   from public.commercial_conditions c
   where c.product_table_version_id=v.id
     and c.contract_type_id=v_ct
     and c.term_min=v_term_min
     and c.term_max=v_term_max
     and c.amount_min is not distinct from v_amount_min
     and c.amount_max is not distinct from v_amount_max;

   v_id:=public.save_commercial_condition_range(
     p_version,v_ct,v_term_min,v_term_max,
     nullif(e->>'coefficient','')::numeric,
     nullif(e->>'rate','')::numeric,
     nullif(e->>'received','')::numeric,
     coalesce(e->'shares','[]'::jsonb),
     v_existing,p_policy_version,v_amount_min,v_amount_max
   );

   if v_existing is null then v_created:=v_created+1; else v_updated:=v_updated+1; end if;
   v_lines:=v_lines||jsonb_build_object('line',v_line,'status',case when v_existing is null then 'created' else 'updated' end,'condition_id',v_id);
  exception when others then
   v_msg:=sqlerrm;
   if v_msg in ('not_authorized','version_not_found') then raise exception '%',v_msg; end if;
   v_errors:=v_errors||jsonb_build_object(
     'line',v_line,
     'code',case when v_msg=any(v_known) or v_msg in ('invalid_row','duplicate_row') then v_msg
                 when sqlstate in ('22P02','22003','22023') then 'invalid_number'
                 else 'unexpected' end
   );
  end;
 end loop;

 if jsonb_array_length(v_errors)>0 then
  raise exception 'bulk_import_rejected' using detail=v_errors::text;
 end if;

 return jsonb_build_object('created',v_created,'updated',v_updated,'lines',v_lines);
end
$_$;


--
-- Name: import_smart_commercial_rows(uuid, text, uuid, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.import_smart_commercial_rows(p_organization uuid, p_production_origin text, p_provider uuid, p_policy_version uuid, p_rows jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  rowj jsonb;
  comp jsonb;
  v_bank public.organization_banks%rowtype;
  v_agreement public.organization_agreements%rowtype;
  v_route public.organization_product_routes%rowtype;
  v_table public.product_tables%rowtype;
  v_version public.product_table_versions%rowtype;
  v_condition public.commercial_conditions%rowtype;
  v_contract public.contract_types%rowtype;
  v_policy public.component_payout_policy_versions%rowtype;
  v_factor_profile public.commercial_factor_profiles%rowtype;
  v_factor_batch public.commercial_factor_batches%rowtype;
  v_bank_name text;
  v_agreement_name text;
  v_table_name text;
  v_external_code text;
  v_contract_name text;
  v_contract_id uuid;
  v_term_min integer;
  v_term_max integer;
  v_coefficient numeric;
  v_rate numeric;
  v_effective_from timestamptz;
  v_effective_until timestamptz;
  v_factor_mode text;
  v_factor_value numeric;
  v_factor_date date;
  v_component_type uuid;
  v_value_kind text;
  v_received numeric;
  v_created_banks integer:=0;
  v_created_agreements integer:=0;
  v_created_tables integer:=0;
  v_created_versions integer:=0;
  v_upserted_conditions integer:=0;
  v_component_count integer:=0;
  v_factor_count integer:=0;
  v_token text:='smart-import:'||replace(gen_random_uuid()::text,'-','');
  v_batch_ids uuid[]:='{}';
begin
  if auth.uid() is null or p_organization is null or not public.has_active_organization_role(p_organization,array['admin','manager']) then
    raise exception 'not_authorized';
  end if;
  if p_production_origin not in ('own','third_party') then raise exception 'invalid_production_origin'; end if;
  if p_production_origin='own' and p_provider is not null then raise exception 'invalid_production_origin'; end if;
  if p_production_origin='third_party' then
    if p_provider is null or not exists(select 1 from public.organization_providers x where x.organization_id=p_organization and x.id=p_provider and x.is_active)
    then raise exception 'invalid_provider'; end if;
  end if;
  if p_policy_version is not null then
    select * into v_policy from public.component_payout_policy_versions x where x.id=p_policy_version and x.organization_id=p_organization;
    if not found then raise exception 'component_policy_not_found'; end if;
  end if;
  if p_rows is null or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)<1 or jsonb_array_length(p_rows)>1000 then
    raise exception 'invalid_smart_import_rows';
  end if;

  for rowj in select * from jsonb_array_elements(p_rows) loop
    v_bank_name:=nullif(btrim(rowj->>'bank_name'),'');
    v_agreement_name:=nullif(btrim(rowj->>'agreement_name'),'');
    v_table_name:=nullif(btrim(rowj->>'table_name'),'');
    v_external_code:=nullif(btrim(rowj->>'external_table_code'),'');
    v_contract_name:=nullif(btrim(rowj->>'contract_type_name'),'');
    begin
      v_contract_id:=nullif(rowj->>'contract_type_id','')::uuid;
      v_term_min:=coalesce(nullif(rowj->>'term_min',''),nullif(rowj->>'term',''))::integer;
      v_term_max:=coalesce(nullif(rowj->>'term_max',''),nullif(rowj->>'term_min',''),nullif(rowj->>'term',''))::integer;
      v_coefficient:=case when nullif(rowj->>'coefficient','') is null then null else (rowj->>'coefficient')::numeric end;
      v_rate:=case when nullif(rowj->>'rate','') is null then null else (rowj->>'rate')::numeric end;
      v_effective_from:=case when nullif(rowj->>'effective_from','') is null then null else (rowj->>'effective_from')::timestamptz end;
      v_effective_until:=case when nullif(rowj->>'effective_until','') is null then null else (rowj->>'effective_until')::timestamptz end;
      v_factor_mode:=nullif(rowj->>'factor_mode','');
      v_factor_value:=case when nullif(rowj->>'factor_value','') is null then null else (rowj->>'factor_value')::numeric end;
      v_factor_date:=case when nullif(rowj->>'factor_date','') is null then coalesce(v_effective_from::date,current_date) else (rowj->>'factor_date')::date end;
    exception when others then raise exception 'invalid_smart_import_row'; end;

    if v_bank_name is null or length(v_bank_name)>120
       or v_agreement_name is null or length(v_agreement_name)>120
       or v_table_name is null or length(v_table_name)>120
       or v_term_min not between 1 and 600
       or v_term_max not between 1 and 600
       or v_term_min>v_term_max
       or (v_coefficient is null and v_rate is null)
       or (v_coefficient is not null and v_coefficient<0)
       or (v_rate is not null and v_rate<0)
       or (v_effective_from is not null and v_effective_until is not null and v_effective_until<v_effective_from)
    then raise exception 'invalid_smart_import_row'; end if;

    -- Contract type can be supplied by id or exact name; tenant-enabled/visible constraints still apply.
    if v_contract_id is not null then
      select * into v_contract from public.contract_types x
      where x.id=v_contract_id and x.is_active and (x.organization_id is null or x.organization_id=p_organization);
    else
      select * into v_contract from public.contract_types x
      where lower(btrim(x.name))=lower(v_contract_name) and x.is_active and (x.organization_id is null or x.organization_id=p_organization)
      order by (x.organization_id=p_organization) desc nulls last limit 1;
    end if;
    if v_contract.id is null then raise exception 'contract_type_not_found'; end if;
    if exists(select 1 from public.organization_contract_type_settings s where s.organization_id=p_organization and s.contract_type_id=v_contract.id and (not s.is_enabled or not s.use_in_commission))
    then raise exception 'contract_type_disabled'; end if;

    -- Exact tenant catalog match first; create only when absent.
    select * into v_bank from public.organization_banks x where x.organization_id=p_organization and lower(btrim(x.name))=lower(v_bank_name) limit 1;
    if v_bank.id is null then
      insert into public.organization_banks(organization_id,name) values(p_organization,v_bank_name) returning * into v_bank;
      v_created_banks:=v_created_banks+1;
    elsif not v_bank.is_active then raise exception 'bank_inactive'; end if;

    select * into v_agreement from public.organization_agreements x where x.organization_id=p_organization and lower(btrim(x.name))=lower(v_agreement_name) limit 1;
    if v_agreement.id is null then
      insert into public.organization_agreements(organization_id,name) values(p_organization,v_agreement_name) returning * into v_agreement;
      v_created_agreements:=v_created_agreements+1;
    elsif not v_agreement.is_active then raise exception 'agreement_inactive'; end if;

    select * into v_route from public.organization_product_routes x
    where x.organization_id=p_organization and x.org_bank_id=v_bank.id and x.org_agreement_id=v_agreement.id
      and ((p_provider is null and x.org_provider_id is null) or x.org_provider_id=p_provider)
      and x.production_origin=p_production_origin
    limit 1;
    if v_route.id is null then
      insert into public.organization_product_routes(organization_id,org_bank_id,org_provider_id,org_agreement_id,production_origin,status)
      values(p_organization,v_bank.id,p_provider,v_agreement.id,p_production_origin,'active') returning * into v_route;
    end if;

    select * into v_table from public.product_tables x
    where x.organization_id=p_organization and x.route_id=v_route.id and lower(btrim(x.name))=lower(v_table_name)
    order by x.created_at desc limit 1;
    if v_table.id is null then
      insert into public.product_tables(organization_id,route_id,code,name,status)
      values(p_organization,v_route.id,'t-'||substr(replace(gen_random_uuid()::text,'-',''),1,12),v_table_name,'active')
      returning * into v_table;
      v_created_tables:=v_created_tables+1;
    elsif v_table.status<>'active' then raise exception 'product_table_inactive'; end if;

    select * into v_version from public.product_table_versions x
    where x.organization_id=p_organization and x.product_table_id=v_table.id and x.status='draft'
    order by x.version desc limit 1;
    if v_version.id is null then
      insert into public.product_table_versions(organization_id,product_table_id,version,status,effective_from,effective_until,metadata)
      select p_organization,v_table.id,coalesce(max(x.version),0)+1,'draft',v_effective_from,v_effective_until,
        jsonb_strip_nulls(jsonb_build_object('external_table_code',v_external_code,'smart_import',true))
      from public.product_table_versions x where x.product_table_id=v_table.id
      returning * into v_version;
      v_created_versions:=v_created_versions+1;
    else
      update public.product_table_versions
      set effective_from=coalesce(v_effective_from,effective_from),
          effective_until=coalesce(v_effective_until,effective_until),
          metadata=metadata||jsonb_strip_nulls(jsonb_build_object('external_table_code',v_external_code,'smart_import',true))
      where id=v_version.id returning * into v_version;
    end if;

    select * into v_condition from public.commercial_conditions x
    where x.organization_id=p_organization and x.product_table_version_id=v_version.id and x.contract_type_id=v_contract.id
      and x.term_min=v_term_min and x.term_max=v_term_max
    limit 1;

    perform set_config('corban.condition_rpc','on',true);
    if v_condition.id is null then
      insert into public.commercial_conditions(organization_id,product_table_version_id,contract_type_id,term,term_min,term_max,coefficient,rate,created_by)
      values(p_organization,v_version.id,v_contract.id,v_term_min,v_term_min,v_term_max,v_coefficient,v_rate,auth.uid())
      returning * into v_condition;
    else
      update public.commercial_conditions
      set term=v_term_min,term_min=v_term_min,term_max=v_term_max,coefficient=v_coefficient,rate=v_rate,updated_at=now()
      where id=v_condition.id returning * into v_condition;
    end if;
    perform set_config('corban.condition_rpc','off',true);
    v_upserted_conditions:=v_upserted_conditions+1;

    -- Replace all received components for the condition only after the row has been fully validated.
    perform public.replace_commercial_condition_components(
      v_condition.id,
      coalesce(rowj->'components','[]'::jsonb)
    );
    v_component_count:=v_component_count+jsonb_array_length(coalesce(rowj->'components','[]'::jsonb));

    if p_policy_version is not null then
      perform set_config('corban.smart_import_rpc','on',true);
      insert into public.commercial_condition_component_policy(condition_id,organization_id,policy_version_id,attached_by)
      values(v_condition.id,p_organization,p_policy_version,auth.uid())
      on conflict(condition_id) do update set policy_version_id=excluded.policy_version_id,attached_by=auth.uid();
      perform set_config('corban.smart_import_rpc','off',true);
    end if;

    -- Factor is its own versioned domain. When present, import a revision for the same commercial scope.
    if v_factor_value is not null then
      if v_factor_value<=0 or v_factor_mode not in ('daily','fixed') then raise exception 'invalid_factor'; end if;
      select * into v_factor_profile from public.commercial_factor_profiles x
      where x.organization_id=p_organization and x.org_bank_id=v_bank.id and x.org_agreement_id=v_agreement.id
        and x.product_table_id=v_table.id and x.contract_type_id=v_contract.id and x.factor_mode=v_factor_mode
      limit 1;
      if v_factor_profile.id is null then
        insert into public.commercial_factor_profiles(
          organization_id,name,org_bank_id,org_agreement_id,product_table_id,contract_type_id,factor_mode,created_by
        ) values(
          p_organization,left(v_bank.name||' · '||v_agreement.name||' · '||v_table.name||' · '||v_contract.name,120),
          v_bank.id,v_agreement.id,v_table.id,v_contract.id,v_factor_mode,auth.uid()
        ) returning * into v_factor_profile;
      end if;

      select * into v_factor_batch from public.commercial_factor_batches x
      where x.organization_id=p_organization and x.profile_id=v_factor_profile.id and x.effective_date=v_factor_date
        and x.status='draft' and x.source_note=v_token
      limit 1;
      if v_factor_batch.id is null then
        insert into public.commercial_factor_batches(organization_id,profile_id,effective_date,revision,status,source_kind,source_note,created_by)
        select p_organization,v_factor_profile.id,v_factor_date,coalesce(max(x.revision),0)+1,'draft','file',v_token,auth.uid()
        from public.commercial_factor_batches x where x.profile_id=v_factor_profile.id and x.effective_date=v_factor_date
        returning * into v_factor_batch;
        v_batch_ids:=v_batch_ids||v_factor_batch.id;
      end if;

      insert into public.commercial_factor_entries(organization_id,batch_id,term_min,term_max,factor_value,metadata)
      values(p_organization,v_factor_batch.id,v_term_min,v_term_max,v_factor_value,jsonb_build_object('smart_import',true))
      on conflict(batch_id,term_min,term_max) do update set factor_value=excluded.factor_value,metadata=excluded.metadata;
      v_factor_count:=v_factor_count+1;
    end if;
  end loop;

  if array_length(v_batch_ids,1) is not null then
    foreach v_contract_id in array v_batch_ids loop
      perform public.publish_commercial_factor_batch(v_contract_id);
    end loop;
  end if;

  return jsonb_build_object(
    'created_banks',v_created_banks,
    'created_agreements',v_created_agreements,
    'created_tables',v_created_tables,
    'created_versions',v_created_versions,
    'upserted_conditions',v_upserted_conditions,
    'components',v_component_count,
    'factors',v_factor_count
  );
exception when others then
  perform set_config('corban.condition_rpc','off',true);
  perform set_config('corban.smart_import_rpc','off',true);
  raise;
end $$;


--
-- Name: ingest_normalized_import_batch(uuid, text, text, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ingest_normalized_import_batch(p_source_id uuid, p_original_filename text, p_content_sha256 text, p_mime_type text, p_parser_key text, p_parser_version text, p_rows jsonb) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $_$
declare
  v_user uuid:=auth.uid();
  v_org uuid;
  v_batch uuid;
  v_item jsonb;
  v_raw uuid;
  v_n jsonb;
  v_row_no int;
  v_external_user text;
  v_seller uuid;
begin
  select s.organization_id into v_org
  from public.import_sources s
  where s.id=p_source_id and s.is_active;

  if v_org is null or not public.is_active_organization_member(v_org) then raise exception 'source_not_found'; end if;
  if p_content_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'invalid_sha256'; end if;
  if jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)=0 then raise exception 'rows_required'; end if;

  select id into v_batch
  from public.import_batches
  where organization_id=v_org and content_sha256=p_content_sha256;
  if v_batch is not null then return v_batch; end if;

  insert into public.import_batches(
    organization_id,source_id,original_filename,content_sha256,mime_type,
    parser_key,parser_version,status,row_count,received_by,completed_at
  ) values(
    v_org,p_source_id,p_original_filename,p_content_sha256,p_mime_type,
    p_parser_key,p_parser_version,'ready_for_review',jsonb_array_length(p_rows),v_user,now()
  ) returning id into v_batch;

  for v_item in select value from jsonb_array_elements(p_rows) loop
    v_row_no:=(v_item->>'rowNumber')::int;
    v_n:=v_item->'normalized';
    if v_row_no<1 or jsonb_typeof(v_item->'rawPayload')<>'object' or jsonb_typeof(v_n)<>'object'
    then raise exception 'invalid_row_payload'; end if;

    v_external_user:=nullif(v_n->>'producerExternalUser','');
    v_seller:=public.resolve_seller_bank_alias(v_org,v_n->>'bankKey',v_external_user);

    insert into public.import_raw_rows(
      organization_id,batch_id,row_number,raw_payload,raw_hash
    ) values(
      v_org,v_batch,v_row_no,v_item->'rawPayload',
      encode(extensions.digest((v_item->'rawPayload')::text,'sha256'),'hex')
    ) returning id into v_raw;

    insert into public.import_normalized_rows(
      organization_id,raw_row_id,record_kind,bank_key,external_proposal_number,
      producer_tax_id,producer_external_user,resolved_seller_id,
      external_table_code,external_table_name,operation_type,term,rate,
      commission_upfront,commission_deferred,amount,normalized_payload,normalization_version
    ) values(
      v_org,v_raw,v_n->>'recordKind',nullif(v_n->>'bankKey',''),
      nullif(v_n->>'externalProposalNumber',''),nullif(v_n->>'producerTaxId',''),
      v_external_user,v_seller,nullif(v_n->>'externalTableCode',''),
      nullif(v_n->>'externalTableName',''),nullif(v_n->>'operationType',''),
      nullif(v_n->>'term','')::int,nullif(v_n->>'rate','')::numeric,
      nullif(v_n->>'commissionUpfront','')::numeric,
      nullif(v_n->>'commissionDeferred','')::numeric,
      nullif(v_n->>'amount','')::numeric,
      coalesce(v_n->'normalizedPayload','{}'::jsonb),p_parser_version
    );
  end loop;

  return v_batch;
end
$_$;


--
-- Name: integration_content_has_secret(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.integration_content_has_secret(p_value text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
 select coalesce(p_value,'') ~* '"(password|senha|secret|api_?key|token|access_token|refresh_token|client_secret|authorization)"\s*:\s*(?!\s|"\[redacted\]"|null)'
     or coalesce(p_value,'') ~* '(bearer\s+[a-z0-9._~+/=-]{12,}|(authorization|api[_-]?key|password|senha|secret|token)\s*[:=]\s*[^\s"\[]{6,}|://[^/\s:@]+:(?!\[redacted\])[^/\s@]+@)'
$$;


--
-- Name: is_active_organization_member(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_active_organization_member(target_organization_id uuid) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$select exists (select 1 from public.organization_memberships m where m.organization_id = target_organization_id and m.user_id = auth.uid() and m.status = 'active')$$;


--
-- Name: list_dispatchable_integration_runs(integer, timestamp with time zone, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_dispatchable_integration_runs(p_limit integer, p_now timestamp with time zone DEFAULT now(), p_adapter_keys text[] DEFAULT NULL::text[]) RETURNS TABLE(run_id uuid, organization_id uuid, binding_id uuid, adapter_key text, capability text, fingerprint text, correlation_id text, status text, attempt_count integer, max_attempts integer, request jsonb, actor_user_id uuid)
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
 select r.id,r.organization_id,r.binding_id,a.adapter_key,r.capability,r.request_fingerprint,r.correlation_id,r.status,r.attempt_count,r.max_attempts,r.metadata->'request',r.created_by
 from public.integration_runs r
 join public.integration_source_bindings b on b.id=r.binding_id and b.organization_id=r.organization_id and b.enabled
 join public.integration_adapters a on a.id=r.adapter_id and a.status<>'disabled'
 where (p_adapter_keys is null or a.adapter_key=any(p_adapter_keys))
   and r.created_by is not null
   and exists(select 1 from public.organization_memberships m where m.organization_id=r.organization_id and m.user_id=r.created_by and m.status='active' and m.role in ('admin','manager','supervisor'))
   and (r.status='queued'
    or (r.status='failed' and not r.terminal and r.attempt_count<r.max_attempts and r.next_attempt_at<=p_now)
    or (r.status='running' and r.lease_expires_at<=p_now))
 order by coalesce(r.next_attempt_at,r.lease_expires_at,r.created_at),r.created_at
 limit least(greatest(coalesce(p_limit,10),1),50)
$$;


--
-- Name: list_import_rows(uuid, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_import_rows(p_batch_id uuid, p_numbers text[] DEFAULT NULL::text[]) RETURNS TABLE(id uuid, organization_id uuid, raw_row_id uuid, batch_id uuid, source_id uuid, row_number integer, record_kind text, bank_key text, external_proposal_number text, producer_tax_id text, external_table_code text, external_table_name text, operation_type text, term integer, rate numeric, normalization_version text, commission_upfront numeric, commission_deferred numeric, amount numeric, normalized_payload jsonb)
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$ select * from private.list_import_rows(p_batch_id,p_numbers) $$;


--
-- Name: normalize_external_user(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.normalize_external_user(p_value text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select nullif(lower(regexp_replace(btrim(coalesce(p_value,'')),'[[:space:]]+',' ','g')),'')
$$;


--
-- Name: platform_grant_ai_credits(uuid, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.platform_grant_ai_credits(p_organization uuid, p_credits numeric, p_idempotency_key text, p_note text) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_id uuid;
begin
 if p_organization is null or p_credits is null or p_credits<=0 or p_credits>100000000 or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 140 then raise exception 'invalid_grant'; end if;
 if not exists(select 1 from public.organizations o where o.id=p_organization) then raise exception 'invalid_grant'; end if;
 insert into public.ai_credit_ledger(organization_id,kind,credits,idempotency_key,note) values(p_organization,'grant',p_credits,p_idempotency_key,left(p_note,300))
  on conflict (organization_id,idempotency_key) do nothing returning id into v_id;
 if v_id is null then select l.id into v_id from public.ai_credit_ledger l where l.organization_id=p_organization and l.idempotency_key=p_idempotency_key; end if;
 return v_id;
end $$;


--
-- Name: platform_set_ai_limits(uuid, boolean, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.platform_set_ai_limits(p_organization uuid, p_enabled boolean, p_monthly_limit numeric) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if p_organization is null or p_enabled is null or p_monthly_limit is null or p_monthly_limit<0 or p_monthly_limit>100000000 then raise exception 'invalid_limit'; end if;
 if not exists(select 1 from public.organizations o where o.id=p_organization) then raise exception 'invalid_limit'; end if;
 insert into public.organization_ai_limits(organization_id,enabled,monthly_credit_limit) values(p_organization,p_enabled,p_monthly_limit)
  on conflict (organization_id) do update set enabled=excluded.enabled,monthly_credit_limit=excluded.monthly_credit_limit,updated_at=now();
end $$;


--
-- Name: prepare_proposal_documents(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prepare_proposal_documents(p_proposal_id uuid) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_org uuid; v_status text; v_template uuid; v_count integer := 0; v_requirement_count integer := 0;
begin
  select p.organization_id, p.status into v_org, v_status from public.proposals_v2 p
  where p.id = p_proposal_id and public.is_active_organization_member(p.organization_id) for update;
  if v_org is null then raise exception 'proposal_not_found_or_forbidden'; end if;
  if v_status not in ('draft','documents_pending') then raise exception 'proposal_not_preparable'; end if;
  select t.id into v_template
  from public.proposals_v2 p
  join public.product_table_versions v on v.organization_id=p.organization_id and v.id=p.product_table_version_id
  join public.product_tables pt on pt.organization_id=v.organization_id and pt.id=v.product_table_id
  join public.document_checklist_templates t on t.organization_id=pt.organization_id and t.route_id=pt.route_id
  where p.organization_id=v_org and p.id=p_proposal_id and t.status='published'
  order by t.version desc limit 1;
  if v_template is null then raise exception 'published_checklist_required'; end if;
  if not exists (select 1 from public.document_checklist_items i where i.organization_id=v_org and i.template_id=v_template) then
    raise exception 'published_checklist_requirements_not_instantiated';
  end if;
  insert into public.proposal_document_requirements (organization_id, proposal_id, checklist_item_id, document_type_id, label_snapshot, required_snapshot)
  select v_org, p_proposal_id, i.id, i.document_type_id, i.label, i.is_required
  from public.document_checklist_items i
  where i.organization_id=v_org and i.template_id=v_template
    and not exists (select 1 from public.proposal_document_requirements r where r.organization_id=v_org and r.proposal_id=p_proposal_id and r.checklist_item_id=i.id);
  get diagnostics v_count = row_count;
  select count(*) into v_requirement_count from public.proposal_document_requirements r where r.organization_id=v_org and r.proposal_id=p_proposal_id;
  if v_requirement_count = 0 then raise exception 'proposal_requirements_snapshot_empty'; end if;
  perform set_config('corban.proposal_rpc','on',true);
  if exists (select 1 from public.proposal_document_requirements r where r.organization_id=v_org and r.proposal_id=p_proposal_id and r.required_snapshot=true and r.status not in ('validated','waived')) then
    update public.proposals_v2 set status='documents_pending', updated_at=now() where organization_id=v_org and id=p_proposal_id and status in ('draft','documents_pending');
  else
    update public.proposals_v2 set status='ready_for_digitization', updated_at=now() where organization_id=v_org and id=p_proposal_id and status in ('draft','documents_pending');
  end if;
  perform set_config('corban.proposal_rpc','off',true);
  return v_count;
end;
$$;


--
-- Name: publish_commercial_factor_batch(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.publish_commercial_factor_batch(p_batch uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare b public.commercial_factor_batches%rowtype; v_overlap boolean;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into b from public.commercial_factor_batches x where x.id=p_batch for update;
  if not found then raise exception 'factor_batch_not_found'; end if;
  if not public.has_active_organization_role(b.organization_id,array['admin','manager']) then raise exception 'not_authorized'; end if;
  if b.status<>'draft' then raise exception 'factor_batch_not_draft'; end if;
  if not exists(select 1 from public.commercial_factor_entries e where e.batch_id=b.id) then raise exception 'factor_batch_empty'; end if;

  select exists(
    select 1
    from public.commercial_factor_entries a
    join public.commercial_factor_entries c
      on c.batch_id=a.batch_id and c.id<>a.id
     and int4range(a.term_min,a.term_max,'[]') && int4range(c.term_min,c.term_max,'[]')
    where a.batch_id=b.id
  ) into v_overlap;
  if v_overlap then raise exception 'factor_term_ranges_overlap'; end if;

  perform set_config('corban.factor_publish','on',true);
  update public.commercial_factor_batches set status='published',published_at=now() where id=b.id;
  perform set_config('corban.factor_publish','off',true);
  return b.id;
end $$;


--
-- Name: publish_document_checklist_template(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.publish_document_checklist_template(p_template_id uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare t public.document_checklist_templates%rowtype;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into t from public.document_checklist_templates x where x.id=p_template_id for update;
 if not found then raise exception 'template_not_found'; end if;
 if not public.has_active_organization_role(t.organization_id,array['admin','manager','supervisor']) then raise exception 'not_authorized'; end if;
 if t.status<>'draft' then raise exception 'template_not_draft'; end if;
 if not exists(select 1 from public.document_checklist_items i where i.organization_id=t.organization_id and i.template_id=t.id) then raise exception 'template_has_no_items'; end if;
 perform set_config('corban.catalog_rpc','on',true);
 update public.document_checklist_templates set status='superseded' where organization_id=t.organization_id and route_id=t.route_id and status='published';
 update public.document_checklist_templates set status='published',published_at=now() where id=t.id;
 perform set_config('corban.catalog_rpc','off',true);
 return t.id;
end $$;


--
-- Name: publish_expected_commission(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.publish_expected_commission(p_proposal_id uuid) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
 v_user uuid:=auth.uid();
 v_org uuid;
 v_snap record;
 v_cs public.proposal_commercial_component_snapshots%rowtype;
 v_base numeric;
 v_gross numeric;
 v_tenant_before_seller numeric;
 v_company numeric;
 v_count integer:=0;
 v_rows integer;
begin
 select organization_id into v_org
 from public.proposals_v2
 where id=p_proposal_id;

 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then
  raise exception 'forbidden';
 end if;

 select r.* into v_snap from private.commercial_route(p_proposal_id) r;
 if not found or v_snap.commission_rule_version_id is null then
  raise exception 'frozen_commercial_snapshot_required';
 end if;

 v_base:=nullif(v_snap.snapshot->>'calculation_base_amount','')::numeric;
 if v_base is null or v_base<0 then raise exception 'snapshot_calculation_base_required'; end if;

 if not exists(
   select 1 from public.proposal_commercial_component_snapshots
   where proposal_id=p_proposal_id and organization_id=v_org
 ) then
  raise exception 'per_component_snapshot_required';
 end if;

 for v_cs in
   select * from public.proposal_commercial_component_snapshots
   where proposal_id=p_proposal_id and organization_id=v_org
   order by id
 loop
  if v_cs.gross_percentage is null and v_cs.fixed_amount is null then
   raise exception 'component_value_required';
  end if;

  v_gross:=coalesce(v_cs.fixed_amount,v_base*v_cs.gross_percentage/100);

  if v_cs.component_type='deferred_anticipation' then
   if v_cs.anticipation_factor is null then raise exception 'anticipation_factor_required'; end if;
   v_gross:=v_gross*v_cs.anticipation_factor;
  end if;

  v_tenant_before_seller:=v_gross*v_cs.upstream_share;
  v_company:=v_tenant_before_seller*v_cs.seller_company_share_pct/100;

  perform set_config('corban.financial_expected_rpc','on',true);
  insert into public.financial_events(
    organization_id,proposal_id,channel_id,producer_entity_id,payer_entity_id,
    event_type,component_type,amount,currency,occurred_at,idempotency_key,
    source_kind,source_reference,metadata,created_by
  )
  values(
    v_org,p_proposal_id,v_snap.channel_id,v_snap.producer_entity_id,v_snap.payer_entity_id,
    'commission_expected',v_cs.component_type,v_company,'BRL',now(),
    'expected:'||p_proposal_id::text||':'||v_cs.commission_component_id::text||':'||coalesce(v_cs.split_rule_version_id::text,'none'),
    'proposal_snapshot',p_proposal_id::text,
    jsonb_build_object(
      'gross_amount',v_gross,
      'tenant_before_seller_amount',v_tenant_before_seller,
      'tenant_amount',v_company,
      'company_expected_amount',v_company,
      'calculation_base',v_base,
      'upstream_share',v_cs.upstream_share,
      'downstream_share',v_cs.downstream_share,
      'split_rule_version_id',v_cs.split_rule_version_id,
      'seller_id',v_cs.seller_id,
      'seller_sub_rule_version_id',v_cs.seller_sub_rule_version_id,
      'seller_sub_share_pct',v_cs.seller_sub_share_pct,
      'seller_company_share_pct',v_cs.seller_company_share_pct
    ),
    v_user
  )
  on conflict(organization_id,idempotency_key) do nothing;

  get diagnostics v_rows=row_count;
  perform set_config('corban.financial_expected_rpc','off',true);
  v_count:=v_count+v_rows;

  perform public.refresh_financial_reconciliation(p_proposal_id,v_cs.component_type);
 end loop;

 return v_count;
end
$$;


--
-- Name: publish_financial_evidence_event(uuid, text, text, numeric, timestamp with time zone, text, text, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.publish_financial_evidence_event(p_proposal_id uuid, p_event_type text, p_component_type text, p_amount numeric, p_occurred_at timestamp with time zone, p_source_kind text, p_source_reference text, p_import_batch_id uuid DEFAULT NULL::uuid, p_import_raw_row_id uuid DEFAULT NULL::uuid, p_import_decision_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
 v_user uuid:=auth.uid();
 v_org uuid;
 v_event uuid;
 v_channel uuid;
 v_producer uuid;
 v_payer uuid;
 v_key text;
 v_semantic text;
 v_raw_batch uuid;
 v_decision_batch uuid;
begin
 select organization_id into v_org from public.proposals_v2 where id=p_proposal_id;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 if p_event_type not in ('commission_reported','payment_received','downstream_paid') then raise exception 'unsupported_evidence_event'; end if;
 if p_amount is null or p_amount<0 or p_occurred_at is null then raise exception 'invalid_financial_fact'; end if;
 if p_source_kind not in ('import','bank_report','partner_report','payment_evidence') then raise exception 'confirmed_evidence_source_required'; end if;

 select channel_id,producer_entity_id,payer_entity_id
 into v_channel,v_producer,v_payer
 from public.proposal_commercial_snapshots
 where proposal_id=p_proposal_id and organization_id=v_org;
 if not found then raise exception 'frozen_commercial_snapshot_required'; end if;

 if p_source_kind='import' then
  if p_import_batch_id is null then raise exception 'import_batch_required'; end if;
  select s.financial_semantic into v_semantic
  from public.import_batches b
  join public.import_sources s on s.id=b.source_id and s.organization_id=b.organization_id
  where b.id=p_import_batch_id and b.organization_id=v_org;
  if v_semantic is null then raise exception 'batch_not_found'; end if;
  if p_event_type='commission_reported' and v_semantic<>'commission_statement' then raise exception 'source_does_not_prove_reported_commission'; end if;
  if p_event_type='payment_received' and v_semantic<>'payment_statement' then raise exception 'source_does_not_prove_payment'; end if;
  if p_event_type='downstream_paid' and v_semantic<>'network_payment_statement' then raise exception 'source_does_not_prove_network_payment'; end if;
  if p_import_raw_row_id is not null then
   select batch_id into v_raw_batch from public.import_raw_rows where id=p_import_raw_row_id and organization_id=v_org;
   if v_raw_batch is distinct from p_import_batch_id then raise exception 'raw_row_batch_mismatch'; end if;
  end if;
  if p_import_decision_id is not null then
   select batch_id into v_decision_batch from public.import_decisions where id=p_import_decision_id and organization_id=v_org;
   if v_decision_batch is distinct from p_import_batch_id then raise exception 'decision_batch_mismatch'; end if;
  end if;
 elsif nullif(trim(p_source_reference),'') is null then
  raise exception 'external_evidence_reference_required';
 end if;

 v_key:='evidence:'||p_event_type||':'||p_proposal_id::text||':'||coalesce(p_component_type,'none')||':'||p_source_kind||':'||
   encode(extensions.digest(concat_ws('|',coalesce(p_source_reference,''),coalesce(p_import_batch_id::text,''),coalesce(p_import_raw_row_id::text,''),coalesce(p_import_decision_id::text,'')),'sha256'),'hex');

 select id into v_event from public.financial_events where organization_id=v_org and idempotency_key=v_key;
 if v_event is null then
  perform set_config('corban.financial_evidence_rpc','on',true);
  insert into public.financial_events(
    organization_id,proposal_id,channel_id,producer_entity_id,payer_entity_id,
    event_type,component_type,amount,currency,occurred_at,idempotency_key,
    source_kind,source_reference,metadata,created_by
  )
  values(
    v_org,p_proposal_id,v_channel,v_producer,v_payer,p_event_type,p_component_type,p_amount,
    'BRL',p_occurred_at,v_key,p_source_kind,p_source_reference,
    jsonb_build_object('evidence_semantic',v_semantic),v_user
  )
  returning id into v_event;
  perform set_config('corban.financial_evidence_rpc','off',true);
 end if;

 insert into public.financial_evidence_links(
   organization_id,financial_event_id,import_batch_id,import_raw_row_id,import_decision_id,
   evidence_kind,evidence_reference
 )
 select v_org,v_event,p_import_batch_id,p_import_raw_row_id,p_import_decision_id,p_source_kind,p_source_reference
 where not exists(
   select 1 from public.financial_evidence_links
   where financial_event_id=v_event
     and coalesce(import_batch_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_batch_id,'00000000-0000-0000-0000-000000000000')
     and coalesce(import_raw_row_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_raw_row_id,'00000000-0000-0000-0000-000000000000')
     and coalesce(import_decision_id,'00000000-0000-0000-0000-000000000000')=coalesce(p_import_decision_id,'00000000-0000-0000-0000-000000000000')
     and coalesce(evidence_reference,'')=coalesce(p_source_reference,'')
 );

 if p_event_type in ('commission_reported','payment_received') then
  perform public.refresh_financial_reconciliation(p_proposal_id,p_component_type);
 end if;

 return v_event;
end
$$;


--
-- Name: publish_financial_fact_from_import_decision(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.publish_financial_fact_from_import_decision(p_decision_id uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare v_org uuid;v_batch uuid;v_raw uuid;v_row uuid;v_proposal uuid;v_semantic text;v_event_type text;v_amount numeric;v_payload jsonb;v_component text;v_occurred timestamptz;v_ref text;v_candidate uuid;v_event uuid;
begin
 select d.organization_id,d.batch_id,d.candidate_id into v_org,v_batch,v_candidate from public.import_decisions d where d.id=p_decision_id and d.decision='approve';
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'approved_decision_not_found_or_forbidden'; end if;
 if exists(select 1 from public.import_decisions newer where newer.candidate_id=v_candidate and newer.organization_id=v_org and newer.decided_at>(select decided_at from public.import_decisions where id=p_decision_id)) then raise exception 'superseded_decision'; end if;
 if not exists(select 1 from public.import_applied_decisions a where a.decision_id=p_decision_id and a.organization_id=v_org) then raise exception 'identity_match_must_be_applied_first'; end if;
 select c.proposal_id,c.normalized_row_id into v_proposal,v_row from public.import_match_candidates c where c.id=v_candidate and c.organization_id=v_org and c.match_strength='exact' and c.proposal_id is not null;
 if v_proposal is null then raise exception 'exact_proposal_match_required'; end if;
 select n.raw_row_id into v_raw from public.import_normalized_rows n where n.id=v_row and n.organization_id=v_org;
 select e.amount,e.normalized_payload into v_amount,v_payload from private.import_row_evidence(v_row) e;
 select s.financial_semantic into v_semantic from public.import_batches b join public.import_sources s on s.id=b.source_id and s.organization_id=b.organization_id where b.id=v_batch and b.organization_id=v_org;
 v_event_type:=case v_semantic when 'commission_statement' then 'commission_reported' when 'payment_statement' then 'payment_received' when 'network_payment_statement' then 'downstream_paid' else null end;
 if v_event_type is null then raise exception 'source_does_not_prove_financial_fact'; end if;
 if v_amount is null or v_amount<0 then raise exception 'valid_amount_required'; end if;
 v_component:=coalesce(nullif(v_payload->>'componentType',''),'upfront');v_occurred:=nullif(v_payload->>'occurredAt','')::timestamptz;
 if v_occurred is null then raise exception 'financial_fact_date_required'; end if;
 v_ref:='import-decision:'||p_decision_id::text;
 v_event:=public.publish_financial_evidence_event(v_proposal,v_event_type,v_component,v_amount,v_occurred,'import',v_ref,v_batch,v_raw,p_decision_id);
 perform public.refresh_financial_reconciliation(v_proposal,v_component);
 return v_event;
end $$;


--
-- Name: publish_financial_reversal(uuid, numeric, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.publish_financial_reversal(p_event_id uuid, p_amount numeric, p_reason text, p_source_kind text, p_source_reference text) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare v_user uuid:=auth.uid();o public.financial_events%rowtype;v_key text;v_event uuid;v_already numeric;
begin
 if v_user is null then raise exception 'forbidden'; end if;
 perform pg_advisory_xact_lock(hashtextextended('financial_reversal:'||p_event_id::text,0));
 select * into o from public.financial_events where id=p_event_id;
 if not found then raise exception 'event_not_found'; end if;
 if not public.has_active_organization_role(o.organization_id,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 if nullif(trim(p_reason),'') is null then raise exception 'reversal_reason_required'; end if;
 if p_source_kind is null or p_source_kind not in ('bank_report','partner_report','payment_evidence','manual_review') then raise exception 'reversal_source_required'; end if;
 if nullif(trim(p_source_reference),'') is null then raise exception 'reversal_reference_required'; end if;
 if o.event_type in ('reversal','adjustment') then raise exception 'cannot_reverse_a_reversal_or_adjustment'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'invalid_reversal_amount'; end if;
 v_key:='reversal:'||o.id::text||':'||encode(extensions.digest(concat_ws('|',p_amount::text,p_source_kind,p_source_reference),'sha256'),'hex');
 select id into v_event from public.financial_events where organization_id=o.organization_id and idempotency_key=v_key;
 if v_event is not null then return v_event; end if;
 select coalesce(sum(amount),0) into v_already from public.financial_events where reverses_event_id=o.id and event_type='reversal';
 if v_already+p_amount>o.amount then raise exception 'reversal_exceeds_original'; end if;
 perform set_config('corban.financial_reversal_rpc','on',true);
 insert into public.financial_events(organization_id,proposal_id,channel_id,producer_entity_id,payer_entity_id,event_type,component_type,amount,currency,occurred_at,idempotency_key,source_kind,source_reference,reverses_event_id,metadata,created_by)
 values(o.organization_id,o.proposal_id,o.channel_id,o.producer_entity_id,o.payer_entity_id,'reversal',o.component_type,p_amount,o.currency,now(),v_key,p_source_kind,p_source_reference,o.id,jsonb_build_object('reason',p_reason,'reversed_event_type',o.event_type),v_user) returning id into v_event;
 perform set_config('corban.financial_reversal_rpc','off',true);
 if o.proposal_id is not null then perform public.refresh_financial_reconciliation(o.proposal_id,o.component_type); end if; return v_event;
end $$;


--
-- Name: publish_product_table_version(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.publish_product_table_version(p_version_id uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v public.product_table_versions%rowtype;
  v_start timestamptz;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;

  select * into v
  from public.product_table_versions x
  where x.id=p_version_id
  for update;

  if not found then raise exception 'version_not_found'; end if;
  if not public.has_active_organization_role(v.organization_id,array['admin','manager']) then raise exception 'not_authorized'; end if;
  if v.status<>'draft' then raise exception 'version_not_draft'; end if;
  if v.rate is null and v.coefficient is null
     and not exists(
       select 1 from public.commercial_conditions c
       where c.organization_id=v.organization_id
         and c.product_table_version_id=v.id
     )
  then raise exception 'rate_or_coefficient_required'; end if;

  v_start:=coalesce(v.effective_from,now());

  perform set_config('corban.catalog_rpc','on',true);

  -- Same-start scheduled revisions are historical replacements, not concurrent prices.
  update public.product_table_versions x
  set status='superseded',
      effective_until=v_start
  where x.organization_id=v.organization_id
    and x.product_table_id=v.product_table_id
    and x.id<>v.id
    and x.status='published'
    and coalesce(x.effective_from,x.published_at,x.created_at)=v_start;

  -- Earlier published versions remain immutable history but stop exactly when this one starts.
  update public.product_table_versions x
  set effective_until=v_start
  where x.organization_id=v.organization_id
    and x.product_table_id=v.product_table_id
    and x.id<>v.id
    and x.status='published'
    and coalesce(x.effective_from,x.published_at,x.created_at)<v_start
    and (x.effective_until is null or x.effective_until>v_start);

  -- Publishing out of chronological order would create an ambiguous interval.
  if exists(
    select 1
    from public.product_table_versions x
    where x.organization_id=v.organization_id
      and x.product_table_id=v.product_table_id
      and x.id<>v.id
      and x.status='published'
      and coalesce(x.effective_from,x.published_at,x.created_at)>v_start
  ) then
    perform set_config('corban.catalog_rpc','off',true);
    raise exception 'future_published_version_exists';
  end if;

  update public.product_table_versions
  set status='published',
      published_at=now(),
      effective_from=v_start
  where id=v.id;

  perform set_config('corban.catalog_rpc','off',true);
  return v.id;
exception when others then
  perform set_config('corban.catalog_rpc','off',true);
  raise;
end
$$;


--
-- Name: publish_seller_sub_rule(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.publish_seller_sub_rule(p_rule uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare r public.seller_sub_rule_versions%rowtype;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into r from public.seller_sub_rule_versions x where x.id=p_rule for update;
  if not found then raise exception 'sub_rule_not_found'; end if;
  if not public.has_active_organization_role(r.organization_id,array['admin','manager']) then raise exception 'not_authorized'; end if;
  if r.status<>'draft' then raise exception 'sub_rule_not_draft'; end if;
  perform set_config('corban.seller_sub_publish','on',true);
  update public.seller_sub_rule_versions set status='published',published_at=now() where id=r.id;
  perform set_config('corban.seller_sub_publish','off',true);
  return r.id;
end $$;


--
-- Name: record_import_conflicts(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_import_conflicts(p_batch_id uuid, p_findings jsonb) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare b record;f jsonb;v_fp text;v_id uuid;v_new integer:=0;v_row uuid;v_rows uuid[];
begin
 if jsonb_typeof(p_findings)<>'array' then raise exception 'findings_must_be_array'; end if;
 if jsonb_array_length(p_findings)>500 then raise exception 'too_many_findings'; end if;
 select id,organization_id into b from public.import_batches where id=p_batch_id;
 if not found or not public.has_active_organization_role(b.organization_id,array['admin','manager','supervisor']) then raise exception 'batch_not_found_or_forbidden'; end if;
 perform set_config('corban.import_conflict_rpc','on',true);
 for f in select value from jsonb_array_elements(p_findings) loop
  select coalesce(array_agg(distinct x::uuid order by x::uuid),'{}') into v_rows from jsonb_array_elements_text(coalesce(f->'rawRowIds','[]'::jsonb)) x;
  -- a conflict without preserved raw evidence is not a conflict record
  if cardinality(v_rows)=0 then raise exception 'conflict_evidence_required'; end if;
  if exists(select 1 from unnest(v_rows) rid where not exists(select 1 from public.import_raw_rows r where r.id=rid and r.batch_id=p_batch_id and r.organization_id=b.organization_id)) then
   perform set_config('corban.import_conflict_rpc','off',true);
   raise exception 'conflict_row_not_in_batch';
  end if;
  v_fp:=encode(extensions.digest(concat_ws('|',p_batch_id::text,f->>'kind',coalesce(f->>'identityKey',''),array_to_string(v_rows,',')),'sha256'),'hex');
  insert into public.import_conflicts(organization_id,batch_id,kind,severity,identity_key,detail,fingerprint)
  values(b.organization_id,p_batch_id,f->>'kind',f->>'severity',nullif(f->>'identityKey',''),coalesce(f->'detail','{}'::jsonb),v_fp)
  on conflict(organization_id,fingerprint) do nothing returning id into v_id;
  if v_id is not null then
   v_new:=v_new+1;
   foreach v_row in array v_rows loop insert into public.import_conflict_rows(conflict_id,organization_id,raw_row_id) values(v_id,b.organization_id,v_row); end loop;
  end if;
  v_id:=null;
 end loop;
 perform set_config('corban.import_conflict_rpc','off',true);
 return v_new;
end $$;


--
-- Name: refresh_financial_reconciliation(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_financial_reconciliation(p_proposal_id uuid, p_component_type text) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare v_org uuid;v_channel uuid;v_expected numeric;v_reported numeric;v_settled numeric;v_case uuid;v_status text;
begin
 select organization_id into v_org from public.proposals_v2 where id=p_proposal_id;
 if v_org is null then raise exception 'proposal_not_found'; end if;
 if not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'forbidden'; end if;
 perform pg_advisory_xact_lock(hashtextextended('financial_refresh:'||p_proposal_id::text||':'||coalesce(p_component_type,'__none__'),0));
 select channel_id into v_channel from public.proposal_commercial_snapshots where proposal_id=p_proposal_id and organization_id=v_org;
 select coalesce(sum(case when e.event_type='commission_expected' then e.amount
                          when e.event_type='reversal' and r.event_type='commission_expected' then -e.amount else 0 end),0),
        coalesce(sum(case when e.event_type='commission_reported' then e.amount
                          when e.event_type='reversal' and r.event_type='commission_reported' then -e.amount else 0 end),0),
        coalesce(sum(case when e.event_type='payment_received' then e.amount
                          when e.event_type='reversal' and r.event_type='payment_received' then -e.amount else 0 end),0)
 into v_expected,v_reported,v_settled
 from public.financial_events e left join public.financial_events r on r.id=e.reverses_event_id
 where e.organization_id=v_org and e.proposal_id=p_proposal_id and e.component_type is not distinct from p_component_type;
 if v_expected<0 or v_reported<0 or v_settled<0 then raise exception 'reconciliation_negative_balance'; end if;
 v_status:=case when v_expected=0 and (v_reported>0 or v_settled>0) then 'human_required'
  when v_settled=v_expected and v_expected>0 then 'matched'
  when v_reported=0 and v_settled=0 then 'open'
  when v_reported<>v_expected or v_settled<>v_expected then 'divergent' else 'open' end;
 perform set_config('corban.reconciliation_rpc','on',true);
 insert into public.financial_reconciliation_cases(organization_id,proposal_id,channel_id,component_type,expected_amount,reported_amount,settled_amount,status)
 values(v_org,p_proposal_id,v_channel,p_component_type,v_expected,v_reported,v_settled,v_status)
 on conflict(organization_id,proposal_id,(coalesce(component_type,'__none__'))) do update set expected_amount=excluded.expected_amount,reported_amount=excluded.reported_amount,settled_amount=excluded.settled_amount,
   status=case when public.financial_reconciliation_cases.status='resolved' then 'resolved' else excluded.status end,updated_at=now()
 returning id into v_case;
 perform set_config('corban.reconciliation_rpc','off',true);
 return v_case;
end $$;


--
-- Name: replace_commercial_condition_components(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.replace_commercial_condition_components(p_condition uuid, p_components jsonb) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare c public.commercial_conditions%rowtype; it jsonb; v_type uuid; v_kind text; v_value numeric; v_source text; v_seen uuid[]:='{}';
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  select * into c from public.commercial_conditions x where x.id=p_condition;
  if not found then raise exception 'condition_not_found'; end if;
  if not public.has_active_organization_role(c.organization_id,array['admin','manager']) then raise exception 'not_authorized'; end if;
  if not exists(select 1 from public.product_table_versions v where v.id=c.product_table_version_id and v.organization_id=c.organization_id and v.status='draft') then raise exception 'version_not_draft'; end if;
  if p_components is null or jsonb_typeof(p_components)<>'array' or jsonb_array_length(p_components)>50 then raise exception 'invalid_components'; end if;

  perform set_config('corban.component_condition_rpc','on',true);
  delete from public.commercial_condition_components where condition_id=c.id;
  for it in select * from jsonb_array_elements(p_components) loop
    begin
      v_type:=(it->>'component_type_id')::uuid;
      v_kind:=it->>'value_kind';
      v_value:=(it->>'received_value')::numeric;
      v_source:=coalesce(nullif(it->>'source',''),'manual');
    exception when others then
      perform set_config('corban.component_condition_rpc','off',true);
      raise exception 'invalid_components';
    end;
    if v_type is null or v_type=any(v_seen) or v_kind not in ('percentage','fixed_brl') or v_value<0 or v_source not in ('manual','import','upstream','adjustment') or not exists(select 1 from public.commission_component_types t where t.id=v_type and t.is_active) then
      perform set_config('corban.component_condition_rpc','off',true);
      raise exception 'invalid_components';
    end if;
    v_seen:=v_seen||v_type;
    insert into public.commercial_condition_components(organization_id,condition_id,component_type_id,value_kind,received_value,calculation_base,source,created_by)
    values(c.organization_id,c.id,v_type,v_kind,v_value,nullif(it->>'calculation_base',''),v_source,auth.uid());
  end loop;
  perform set_config('corban.component_condition_rpc','off',true);
end $$;


--
-- Name: replace_seller_address(uuid, text, text, text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.replace_seller_address(p_seller_id uuid, p_postal_code text, p_street text, p_number text, p_complement text, p_neighborhood text, p_city text, p_state text) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_org uuid; v_id uuid;
begin
  select organization_id into v_org from public.commercial_sellers where id=p_seller_id;
  if v_org is null then raise exception 'seller_not_found'; end if;
  if not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'forbidden'; end if;

  perform set_config('corban.seller_profile_rpc','on',true);
  update public.seller_addresses
     set is_current=false,valid_until=now()
   where organization_id=v_org and seller_id=p_seller_id and is_current;

  insert into public.seller_addresses(
    organization_id,seller_id,postal_code,street,number,complement,neighborhood,city,state,created_by
  ) values(
    v_org,p_seller_id,nullif(regexp_replace(coalesce(p_postal_code,''),'[^0-9]','','g'),''),
    nullif(btrim(p_street),''),nullif(btrim(p_number),''),nullif(btrim(p_complement),''),
    nullif(btrim(p_neighborhood),''),nullif(btrim(p_city),''),upper(nullif(btrim(p_state),'')),auth.uid()
  ) returning id into v_id;
  perform set_config('corban.seller_profile_rpc','off',true);
  return v_id;
end
$$;


--
-- Name: reserve_ai_job(uuid, text, text, text, numeric, numeric, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reserve_ai_job(p_organization uuid, p_capability text, p_provider text, p_model text, p_estimated_credits numeric, p_estimated_cost numeric, p_source_ref text, p_idempotency_key text) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare l public.organization_ai_limits%rowtype; j public.ai_usage_jobs%rowtype; v_bal numeric; v_month numeric; v_id uuid; v_has_limits boolean;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 if p_organization is null or not public.has_active_organization_role(p_organization,array['admin','manager','supervisor']) then raise exception 'not_authorized'; end if;
 if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 120 then raise exception 'invalid_ai_job'; end if;
 if p_capability is null or p_capability not in ('import_mapping','import_pdf_extraction','operational_summary') then raise exception 'invalid_ai_job'; end if;
 if p_provider is null or length(p_provider) not between 1 and 40 or p_model is null or length(p_model) not between 1 and 80 then raise exception 'invalid_ai_job'; end if;
 if p_estimated_credits is null or p_estimated_credits<=0 or p_estimated_credits>1000000 then raise exception 'invalid_ai_job'; end if;
 if p_estimated_cost is not null and p_estimated_cost<0 then raise exception 'invalid_ai_job'; end if;
 -- serialise reservations per tenant (balance and ceiling checks must not race); an advisory lock needs no table privilege
 perform pg_advisory_xact_lock(hashtextextended(p_organization::text,0));
 select * into l from public.organization_ai_limits x where x.organization_id=p_organization;
 v_has_limits:=found;
 select * into j from public.ai_usage_jobs x where x.organization_id=p_organization and x.idempotency_key=p_idempotency_key;
 if found then
  if j.capability<>p_capability or j.estimated_credits<>p_estimated_credits then raise exception 'idempotency_conflict'; end if;
  return j.id;
 end if;
 if not v_has_limits or not l.enabled then raise exception 'ai_disabled'; end if;
 v_bal:=coalesce((select sum(x.credits) from public.ai_credit_ledger x where x.organization_id=p_organization),0);
 if v_bal<p_estimated_credits then raise exception 'insufficient_credits'; end if;
 v_month:=coalesce((select sum(coalesce(x.credits_charged,x.estimated_credits)) from public.ai_usage_jobs x where x.organization_id=p_organization and x.status in ('reserved','succeeded') and x.created_at>=date_trunc('month',now())),0);
 if v_month+p_estimated_credits>l.monthly_credit_limit then raise exception 'monthly_limit_exceeded'; end if;
 perform set_config('corban.ai_rpc','on',true);
 insert into public.ai_usage_jobs(organization_id,capability,provider,model,source_ref,estimated_credits,estimated_provider_cost,idempotency_key,created_by)
  values(p_organization,p_capability,p_provider,p_model,p_source_ref,p_estimated_credits,p_estimated_cost,p_idempotency_key,auth.uid()) returning id into v_id;
 insert into public.ai_credit_ledger(organization_id,kind,credits,job_id,idempotency_key,created_by) values(p_organization,'reserve',-p_estimated_credits,v_id,'reserve:'||v_id,auth.uid());
 insert into public.ai_usage_events(organization_id,job_id,event,detail) values(p_organization,v_id,'reserved',jsonb_build_object('capability',p_capability));
 perform set_config('corban.ai_rpc','off',true);
 return v_id;
end $$;


--
-- Name: resolve_commercial_factor(uuid, uuid, uuid, uuid, integer, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_commercial_factor(p_org_bank uuid, p_org_agreement uuid, p_product_table uuid, p_contract_type uuid, p_term integer, p_on date DEFAULT CURRENT_DATE) RETURNS TABLE(profile_id uuid, batch_id uuid, factor_mode text, effective_date date, factor_value numeric, term_min integer, term_max integer)
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
with profiles as (
  select p.*,
         (case when p.product_table_id is not null then 8 else 0 end
          + case when p.contract_type_id is not null then 4 else 0 end
          + case when p.org_agreement_id is not null then 2 else 0 end) specificity
  from public.commercial_factor_profiles p
  where p.org_bank_id=p_org_bank
    and p.is_active
    and public.is_active_organization_member(p.organization_id)
    and (p.org_agreement_id is null or p.org_agreement_id=p_org_agreement)
    and (p.product_table_id is null or p.product_table_id=p_product_table)
    and (p.contract_type_id is null or p.contract_type_id=p_contract_type)
), candidates as (
  select p.id profile_id,b.id batch_id,p.factor_mode,b.effective_date,b.revision,p.specificity,
         e.factor_value,e.term_min,e.term_max
  from profiles p
  join lateral (
    select x.*
    from public.commercial_factor_batches x
    where x.profile_id=p.id and x.status='published'
      and ((p.factor_mode='daily' and x.effective_date=p_on)
        or (p.factor_mode='fixed' and x.effective_date<=p_on))
    order by
      case when p.factor_mode='daily' then 1 else 0 end desc,
      x.effective_date desc,x.revision desc
    limit 1
  ) b on true
  join public.commercial_factor_entries e on e.batch_id=b.id
  where p_term between e.term_min and e.term_max
)
select c.profile_id,c.batch_id,c.factor_mode,c.effective_date,c.factor_value,c.term_min,c.term_max
from candidates c
order by c.specificity desc,
         case when c.factor_mode='daily' then 1 else 0 end desc,
         c.effective_date desc,c.revision desc
limit 1
$$;


--
-- Name: resolve_component_payout_policy(uuid, uuid, uuid, uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_component_payout_policy(p_organization uuid, p_bank uuid, p_agreement uuid, p_table uuid, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(policy_id uuid, version_id uuid, discount_pct numeric, effective_from timestamp with time zone)
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
with candidate as (
  select p.id policy_id,v.id version_id,v.discount_pct,v.effective_from,v.version,
    (case when p.product_table_id is not null then 4 else 0 end
     + case when p.org_agreement_id is not null then 2 else 0 end
     + case when p.org_bank_id is not null then 1 else 0 end) specificity
  from public.component_payout_policies p
  join public.component_payout_policy_versions v on v.policy_id=p.id and v.organization_id=p.organization_id
  where p.organization_id=p_organization and p.is_active
    and public.has_active_organization_role(p.organization_id,array['admin','manager','supervisor'])
    and (p.org_bank_id is null or p.org_bank_id=p_bank)
    and (p.org_agreement_id is null or p.org_agreement_id=p_agreement)
    and (p.product_table_id is null or p.product_table_id=p_table)
    and v.effective_from<=p_at
)
select c.policy_id,c.version_id,c.discount_pct,c.effective_from
from candidate c
order by c.specificity desc,c.effective_from desc,c.version desc
limit 1
$$;


--
-- Name: resolve_import_conflict(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_import_conflict(p_conflict_id uuid, p_status text, p_note text) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_org uuid;
begin
 if p_status not in ('resolved','dismissed') then raise exception 'invalid_status'; end if;
 if p_note is null or length(btrim(p_note)) not between 10 and 2000 then raise exception 'resolution_note_length_invalid'; end if;
 select organization_id into v_org from public.import_conflicts where id=p_conflict_id;
 if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager','supervisor']) then raise exception 'conflict_not_found_or_forbidden'; end if;
 update public.import_conflicts set status=p_status,resolution_note=p_note where id=p_conflict_id and organization_id=v_org;
end $$;


--
-- Name: resolve_seller_bank_alias(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_seller_bank_alias(p_org uuid, p_source_key text, p_external_user text) RETURNS uuid
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
  select a.seller_id
  from public.seller_bank_aliases a
  join public.commercial_sellers s
    on s.organization_id=a.organization_id
   and s.id=a.seller_id
   and s.is_active
  where a.organization_id=p_org
    and a.is_active
    and lower(btrim(a.source_key))=lower(btrim(coalesce(p_source_key,'')))
    and a.external_user_normalized=public.normalize_external_user(p_external_user)
  limit 1
$$;


--
-- Name: resolve_seller_sub_rule(uuid, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_seller_sub_rule(p_seller uuid, p_component text DEFAULT 'all'::text, p_at timestamp with time zone DEFAULT now()) RETURNS TABLE(rule_version_id uuid, sub_share_pct numeric, company_share_pct numeric)
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
  select r.id,r.sub_share_pct,r.company_share_pct
  from public.seller_sub_rule_versions r
  join public.commercial_sellers s on s.id=r.seller_id and s.organization_id=r.organization_id
  where r.seller_id=p_seller
    and r.status='published'
    and r.effective_from<=p_at
    and r.component_key in (coalesce(nullif(btrim(p_component),''),'all'),'all')
    and public.is_active_organization_member(r.organization_id)
  order by (r.component_key=coalesce(nullif(btrim(p_component),''),'all')) desc,
           r.effective_from desc,r.version desc
  limit 1
$$;


--
-- Name: revoke_organization_invitation(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.revoke_organization_invitation(p_invitation_id uuid) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v public.organization_invitations%rowtype; v_actor text;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into v from public.organization_invitations i where i.id=p_invitation_id for update;
 if not found then raise exception 'invitation_not_found'; end if;
 v_actor:=private.caller_role_in(v.organization_id);
 if v_actor is null or not public.can_manage_member_role(v_actor,null,v.role) then raise exception 'not_authorized'; end if;
 if v.status<>'pending' then raise exception 'invitation_already_resolved'; end if;
 perform set_config('corban.membership_rpc','on',true);
 update public.organization_invitations set status='revoked',resolved_at=now() where id=p_invitation_id;
 insert into public.organization_admin_events(organization_id,actor_user_id,event_type,target_email,details) values(v.organization_id,auth.uid(),'invite_revoked',v.email,jsonb_build_object('role',v.role,'invitation_id',v.id));
 perform set_config('corban.membership_rpc','off',true);
end $$;


--
-- Name: save_commercial_condition(uuid, uuid, integer, numeric, numeric, numeric, jsonb, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.save_commercial_condition(p_version uuid, p_contract_type uuid, p_term integer, p_coefficient numeric, p_rate numeric, p_received numeric, p_shares jsonb, p_condition uuid DEFAULT NULL::uuid, p_policy_version uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE sql
    SET search_path TO ''
    AS $$
 select public.save_commercial_condition_range(
   p_version,p_contract_type,p_term,p_term,p_coefficient,p_rate,p_received,p_shares,p_condition,p_policy_version
 )
$$;


--
-- Name: save_commercial_condition_range(uuid, uuid, integer, integer, numeric, numeric, numeric, jsonb, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.save_commercial_condition_range(p_version uuid, p_contract_type uuid, p_term_min integer, p_term_max integer, p_coefficient numeric, p_rate numeric, p_received numeric, p_shares jsonb, p_condition uuid DEFAULT NULL::uuid, p_policy_version uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
 if p_coefficient is null and p_rate is null then raise exception 'coefficient_or_rate_required'; end if;
 return public.save_commercial_condition_range(
   p_version,p_contract_type,p_term_min,p_term_max,p_coefficient,p_rate,p_received,p_shares,
   p_condition,p_policy_version,null,null
 );
end
$$;


--
-- Name: save_commercial_condition_range(uuid, uuid, integer, integer, numeric, numeric, numeric, jsonb, uuid, uuid, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.save_commercial_condition_range(p_version uuid, p_contract_type uuid, p_term_min integer, p_term_max integer, p_coefficient numeric, p_rate numeric, p_received numeric, p_shares jsonb, p_condition uuid, p_policy_version uuid, p_amount_min numeric, p_amount_max numeric) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
 v public.product_table_versions%rowtype;
 v_id uuid;
 s jsonb;
 g public.commission_groups%rowtype;
 v_seen uuid[]:='{}';
 v_pct numeric;
 v_gid uuid;
 v_pv public.payout_policy_versions%rowtype;
 v_net numeric;
 v_rows jsonb:='[]'::jsonb;
 v_final jsonb:='[]'::jsonb;
 v_eff numeric;
 r record;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into v from public.product_table_versions x where x.id=p_version;
 if not found then raise exception 'version_not_found'; end if;
 if not public.has_active_organization_role(v.organization_id,array['admin','manager']) then raise exception 'not_authorized'; end if;
 if v.status<>'draft' then raise exception 'version_not_draft'; end if;
 if not exists(select 1 from public.contract_types c where c.id=p_contract_type and c.is_active) then raise exception 'contract_type_not_found'; end if;
 if p_term_min is null or p_term_max is null or p_term_min<1 or p_term_max>600 or p_term_min>p_term_max then raise exception 'invalid_term_range'; end if;
 if (p_amount_min is null) <> (p_amount_max is null)
    or (p_amount_min is not null and (p_amount_min<0 or p_amount_max<p_amount_min or p_amount_max>999999999.99))
 then raise exception 'invalid_amount_range'; end if;
 if coalesce(p_coefficient,0)<0 or coalesce(p_rate,0)<0 then raise exception 'invalid_rate_or_coefficient'; end if;
 if p_received is null or p_received<0 or p_received>100 then raise exception 'invalid_received_commission'; end if;
 if p_shares is null or jsonb_typeof(p_shares)<>'array' or jsonb_array_length(p_shares)>100 then raise exception 'invalid_shares'; end if;

 if p_policy_version is not null then
  select pv.* into v_pv from public.payout_policy_versions pv
  join public.payout_policies pp on pp.id=pv.policy_id and pp.organization_id=pv.organization_id
  where pv.id=p_policy_version and pv.organization_id=v.organization_id and pp.is_active;
  if not found then raise exception 'policy_not_found'; end if;
 end if;

 v_net:=case when p_policy_version is not null and v_pv.base_kind='net'
             then round(p_received*(100-v_pv.discount_pct)/100,6)
             else p_received end;

 for s in select * from jsonb_array_elements(p_shares) loop
  begin v_gid:=(s->>'group_id')::uuid; v_pct:=(s->>'pct')::numeric;
  exception when others then raise exception 'invalid_shares'; end;
  if v_gid is null or v_pct is null or v_pct<0 or v_pct>100 then raise exception 'invalid_shares'; end if;
  if v_gid=any(v_seen) then raise exception 'duplicate_group_share'; end if;
  v_seen:=v_seen||v_gid;
  v_rows:=v_rows||jsonb_build_object(
    'g',v_gid,'pct',v_pct,
    'src',case when p_policy_version is not null and exists(
      select 1 from public.payout_policy_items i where i.version_id=p_policy_version and i.group_id=v_gid
    ) then 'override' else 'manual' end
  );
 end loop;

 if p_policy_version is not null then
  for r in select i.group_id,i.pct from public.payout_policy_items i
           where i.version_id=p_policy_version and not (i.group_id=any(v_seen))
  loop
   v_seen:=v_seen||r.group_id;
   v_rows:=v_rows||jsonb_build_object('g',r.group_id,'pct',r.pct,'src','policy');
  end loop;
 end if;

 for s in select * from jsonb_array_elements(v_rows) loop
  select * into g from public.commission_groups x
   where x.id=(s->>'g')::uuid and x.organization_id=v.organization_id and x.is_active;
  if not found then raise exception '%',case when s->>'src'='policy' then 'policy_group_inactive' else 'commission_group_not_found' end; end if;
  v_pct:=(s->>'pct')::numeric;
  if g.calculation_basis='percent_of_production' then
   if v_pct>p_received then raise exception 'production_shares_exceed_received_commission'; end if;
   v_eff:=v_pct;
  else
   v_eff:=round(v_net*v_pct/100,6);
  end if;
  v_final:=v_final||(s||jsonb_build_object('eff',v_eff));
 end loop;

 perform set_config('corban.condition_rpc','on',true);

 if p_condition is null then
  begin
   insert into public.commercial_conditions(
     organization_id,product_table_version_id,contract_type_id,
     term,term_min,term_max,amount_min,amount_max,coefficient,rate,created_by
   ) values(
     v.organization_id,v.id,p_contract_type,
     p_term_min,p_term_min,p_term_max,p_amount_min,p_amount_max,p_coefficient,p_rate,auth.uid()
   ) returning id into v_id;
  exception
   when unique_violation or exclusion_violation then
    perform set_config('corban.condition_rpc','off',true);
    raise exception 'condition_range_conflict';
  end;
 else
  select c.id into v_id from public.commercial_conditions c
   where c.id=p_condition and c.product_table_version_id=v.id for update;
  if v_id is null then raise exception 'condition_not_found'; end if;
  begin
   update public.commercial_conditions
   set contract_type_id=p_contract_type,
       term=p_term_min,
       term_min=p_term_min,
       term_max=p_term_max,
       amount_min=p_amount_min,
       amount_max=p_amount_max,
       coefficient=p_coefficient,
       rate=p_rate,
       updated_at=now()
   where id=v_id;
  exception
   when unique_violation or exclusion_violation then
    perform set_config('corban.condition_rpc','off',true);
    raise exception 'condition_range_conflict';
  end;
 end if;

 insert into public.commercial_condition_commissions(
   condition_id,organization_id,received_commission_pct,net_base_pct,policy_version_id
 ) values(v_id,v.organization_id,p_received,v_net,p_policy_version)
 on conflict (condition_id) do update
 set received_commission_pct=excluded.received_commission_pct,
     net_base_pct=excluded.net_base_pct,
     policy_version_id=excluded.policy_version_id,
     updated_at=now();

 delete from public.commercial_condition_shares
 where condition_id=v_id and not (group_id=any(v_seen));

 for s in select * from jsonb_array_elements(v_final) loop
  insert into public.commercial_condition_shares(
    organization_id,condition_id,group_id,share_pct,effective_pct,source,policy_version_id
  ) values(
    v.organization_id,v_id,(s->>'g')::uuid,(s->>'pct')::numeric,(s->>'eff')::numeric,s->>'src',
    case when s->>'src' in ('policy','override') then p_policy_version else null end
  )
  on conflict (condition_id,group_id) do update
  set share_pct=excluded.share_pct,
      effective_pct=excluded.effective_pct,
      source=excluded.source,
      policy_version_id=excluded.policy_version_id;
 end loop;

 perform set_config('corban.condition_rpc','off',true);
 return v_id;
exception when others then
 perform set_config('corban.condition_rpc','off',true);
 raise;
end
$$;


--
-- Name: save_commission_group_configuration(uuid, uuid, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.save_commission_group_configuration(p_organization uuid, p_group uuid, p_name text, p_items jsonb) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_group uuid;
  v_item jsonb;
  v_component uuid;
  v_pct numeric;
  v_seen uuid[]:='{}';
  v_active_count integer;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if p_organization is null
     or not public.has_active_organization_role(p_organization,array['admin','manager']) then
    raise exception 'not_authorized';
  end if;
  if p_name is null or length(btrim(p_name)) not between 1 and 80 then
    raise exception 'invalid_commission_group';
  end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' then
    raise exception 'invalid_commission_group_components';
  end if;

  select count(*) into v_active_count
  from public.commission_component_types t
  where t.is_active;

  if jsonb_array_length(p_items)<>v_active_count then
    raise exception 'commission_group_components_incomplete';
  end if;

  if p_group is null then
    insert into public.commission_groups(
      organization_id,name,kind,calculation_basis
    ) values(
      p_organization,btrim(p_name),'other','percent_of_received_commission'
    ) returning id into v_group;
  else
    select g.id into v_group
    from public.commission_groups g
    where g.id=p_group
      and g.organization_id=p_organization
    for update;
    if v_group is null then raise exception 'commission_group_not_found'; end if;

    update public.commission_groups
    set name=btrim(p_name),
        calculation_basis='percent_of_received_commission',
        updated_at=now()
    where id=v_group;
  end if;

  perform set_config('corban.commission_group_config_rpc','on',true);

  for v_item in select * from jsonb_array_elements(p_items) loop
    begin
      v_component:=(v_item->>'component_type_id')::uuid;
      v_pct:=(v_item->>'max_received_share_pct')::numeric;
    exception when others then
      perform set_config('corban.commission_group_config_rpc','off',true);
      raise exception 'invalid_commission_group_components';
    end;

    if v_component is null or v_pct is null or v_pct<0 or v_pct>100 then
      perform set_config('corban.commission_group_config_rpc','off',true);
      raise exception 'invalid_commission_group_components';
    end if;
    if v_component=any(v_seen) then
      perform set_config('corban.commission_group_config_rpc','off',true);
      raise exception 'duplicate_commission_group_component';
    end if;
    if not exists(
      select 1 from public.commission_component_types t
      where t.id=v_component and t.is_active
    ) then
      perform set_config('corban.commission_group_config_rpc','off',true);
      raise exception 'commission_component_not_found';
    end if;

    v_seen:=v_seen||v_component;

    insert into public.commission_group_component_limits(
      organization_id,group_id,component_type_id,max_received_share_pct
    ) values(
      p_organization,v_group,v_component,v_pct
    )
    on conflict(organization_id,group_id,component_type_id)
    do update set
      max_received_share_pct=excluded.max_received_share_pct;
  end loop;

  perform set_config('corban.commission_group_config_rpc','off',true);

  return v_group;
end
$$;


--
-- Name: save_component_payout_policy(uuid, text, uuid, uuid, uuid, numeric, timestamp with time zone, jsonb, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.save_component_payout_policy(p_organization uuid, p_name text, p_bank uuid, p_agreement uuid, p_table uuid, p_discount numeric, p_effective_from timestamp with time zone, p_items jsonb, p_policy uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare pol public.component_payout_policies%rowtype; v_org uuid; v_version integer; v_vid uuid; it jsonb; v_group uuid; v_type uuid; v_mode text; v_share numeric; v_direct numeric; v_kind text;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if p_policy is null then
    v_org:=p_organization;
    if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'not_authorized'; end if;
    if p_name is null or length(btrim(p_name)) not between 1 and 100 then raise exception 'invalid_component_policy'; end if;
    if p_bank is not null and not exists(select 1 from public.organization_banks b where b.id=p_bank and b.organization_id=v_org and b.is_active) then raise exception 'invalid_component_policy_scope'; end if;
    if p_agreement is not null and not exists(select 1 from public.organization_agreements a where a.id=p_agreement and a.organization_id=v_org and a.is_active) then raise exception 'invalid_component_policy_scope'; end if;
    if p_table is not null and not exists(select 1 from public.product_tables t where t.id=p_table and t.organization_id=v_org and t.status='active') then raise exception 'invalid_component_policy_scope'; end if;
    perform set_config('corban.payout_rpc','on',true);
    insert into public.component_payout_policies(organization_id,name,org_bank_id,org_agreement_id,product_table_id,created_by)
    values(v_org,btrim(p_name),p_bank,p_agreement,p_table,auth.uid()) returning * into pol;
    perform set_config('corban.payout_rpc','off',true);
  else
    select * into pol from public.component_payout_policies x where x.id=p_policy and x.is_active for update;
    if not found then raise exception 'component_policy_not_found'; end if;
    v_org:=pol.organization_id;
    if not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'not_authorized'; end if;
  end if;

  if p_discount is null or p_discount<0 or p_discount>100 or p_effective_from is null then raise exception 'invalid_component_policy'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)>500 then raise exception 'invalid_component_policy'; end if;

  perform set_config('corban.component_policy_rpc','on',true);
  select coalesce(max(v.version),0)+1 into v_version from public.component_payout_policy_versions v where v.policy_id=pol.id;
  insert into public.component_payout_policy_versions(organization_id,policy_id,version,discount_pct,effective_from,created_by)
  values(v_org,pol.id,v_version,p_discount,p_effective_from,auth.uid()) returning id into v_vid;

  for it in select * from jsonb_array_elements(p_items) loop
    begin
      v_group:=(it->>'group_id')::uuid;
      v_type:=(it->>'component_type_id')::uuid;
      v_mode:=it->>'mode';
      v_share:=case when nullif(it->>'share_pct','') is null then null else (it->>'share_pct')::numeric end;
      v_kind:=nullif(it->>'direct_value_kind','');
      v_direct:=case when nullif(it->>'direct_value','') is null then null else (it->>'direct_value')::numeric end;
    exception when others then
      perform set_config('corban.component_policy_rpc','off',true);
      raise exception 'invalid_component_policy';
    end;
    if not exists(select 1 from public.commission_groups g where g.id=v_group and g.organization_id=v_org and g.is_active)
       or not exists(select 1 from public.commission_component_types t where t.id=v_type and t.is_active)
       or v_mode not in ('share_of_received','direct','exclude')
       or (v_mode='share_of_received' and (v_share is null or v_share<0 or v_share>100 or v_kind is not null or v_direct is not null))
       or (v_mode='direct' and (v_share is not null or v_kind not in ('percentage','fixed_brl') or v_direct is null or v_direct<0))
       or (v_mode='exclude' and (v_share is not null or v_kind is not null or v_direct is not null))
    then
      perform set_config('corban.component_policy_rpc','off',true);
      raise exception 'invalid_component_policy';
    end if;
    insert into public.component_payout_policy_items(organization_id,version_id,group_id,component_type_id,mode,share_pct,direct_value_kind,direct_value)
    values(v_org,v_vid,v_group,v_type,v_mode,v_share,v_kind,v_direct);
  end loop;
  perform set_config('corban.component_policy_rpc','off',true);
  return v_vid;
exception when unique_violation then
  perform set_config('corban.component_policy_rpc','off',true);
  perform set_config('corban.payout_rpc','off',true);
  raise exception 'component_policy_duplicate';
end $$;


--
-- Name: save_payout_policy(uuid, text, text, numeric, jsonb, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.save_payout_policy(p_organization uuid, p_name text, p_base_kind text, p_discount numeric, p_items jsonb, p_policy uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_pol public.payout_policies%rowtype; v_org uuid; v_ver integer; v_vid uuid; it jsonb; g public.commission_groups%rowtype; v_seen uuid[]:='{}'; v_pct numeric; v_gid uuid; v_disc numeric;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 if p_policy is not null then
  select * into v_pol from public.payout_policies x where x.id=p_policy for update;
  if not found then raise exception 'policy_not_found'; end if;
  v_org:=v_pol.organization_id;
  if not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'not_authorized'; end if;
  if not v_pol.is_active then raise exception 'policy_not_found'; end if;
 else
  v_org:=p_organization;
  if v_org is null or not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'not_authorized'; end if;
  if p_name is null or length(btrim(p_name)) not between 1 and 80 then raise exception 'invalid_policy'; end if;
 end if;
 if p_base_kind is null or p_base_kind not in ('gross','net') then raise exception 'invalid_policy'; end if;
 v_disc:=coalesce(p_discount,0);
 if v_disc<0 or v_disc>100 or (p_base_kind='gross' and v_disc<>0) then raise exception 'invalid_policy'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)>100 then raise exception 'invalid_policy'; end if;
 for it in select * from jsonb_array_elements(p_items) loop
  begin v_gid:=(it->>'group_id')::uuid; v_pct:=(it->>'pct')::numeric; exception when others then raise exception 'invalid_policy'; end;
  if v_gid is null or v_pct is null or v_pct<0 or v_pct>100 then raise exception 'invalid_policy'; end if;
  if v_gid=any(v_seen) then raise exception 'duplicate_group_share'; end if;
  v_seen:=v_seen||v_gid;
  select * into g from public.commission_groups x where x.id=v_gid and x.organization_id=v_org and x.is_active;
  if not found then raise exception 'commission_group_not_found'; end if;
  -- a policy is a percentage of the commission RECEIVED; a production-based group cannot be read that way (no silent mixing)
  if g.calculation_basis<>'percent_of_received_commission' then raise exception 'policy_group_must_use_received_basis'; end if;
 end loop;
 perform set_config('corban.payout_rpc','on',true);
 if p_policy is null then
  begin
   insert into public.payout_policies(organization_id,name,created_by) values(v_org,btrim(p_name),auth.uid()) returning * into v_pol;
  exception when unique_violation then perform set_config('corban.payout_rpc','off',true); raise exception 'policy_already_exists'; end;
 end if;
 select coalesce(max(x.version),0)+1 into v_ver from public.payout_policy_versions x where x.policy_id=v_pol.id;
 insert into public.payout_policy_versions(organization_id,policy_id,version,base_kind,discount_pct,created_by) values(v_org,v_pol.id,v_ver,p_base_kind,v_disc,auth.uid()) returning id into v_vid;
 for it in select * from jsonb_array_elements(p_items) loop
  insert into public.payout_policy_items(organization_id,version_id,group_id,pct) values(v_org,v_vid,(it->>'group_id')::uuid,(it->>'pct')::numeric);
 end loop;
 perform set_config('corban.payout_rpc','off',true);
 return v_vid;
end $$;


--
-- Name: send_proposal_to_digitization(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.send_proposal_to_digitization(p_proposal_id uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_org uuid; v_status text; v_stage_id uuid; v_sla integer; v_job_id uuid; v_case_id uuid;
begin
  select p.organization_id, p.status into v_org, v_status
  from public.proposals_v2 p
  where p.id=p_proposal_id and public.is_active_organization_member(p.organization_id)
  for update;
  if v_org is null then raise exception 'proposal_not_found_or_forbidden'; end if;
  if v_status <> 'ready_for_digitization' then raise exception 'proposal_not_ready_for_digitization'; end if;
  if exists (
    select 1 from public.proposal_document_requirements r
    where r.organization_id=v_org and r.proposal_id=p_proposal_id
      and r.required_snapshot=true and r.status not in ('validated','waived')
  ) then raise exception 'required_documents_not_ready'; end if;
  select s.id, s.sla_minutes into v_stage_id, v_sla
  from public.operational_stages s
  where s.organization_id=v_org and s.canonical_state='digitization_queue' and s.is_active=true
  order by s.sort_order, s.created_at limit 1;
  if v_stage_id is null then raise exception 'digitization_queue_stage_not_configured'; end if;
  perform set_config('corban.operational_rpc','on',true);
  perform set_config('corban.proposal_rpc','on',true);
  insert into public.digitization_jobs (organization_id, proposal_id, status, priority) values (v_org, p_proposal_id, 'queued', 0) returning id into v_job_id;
  insert into public.operational_cases (organization_id, proposal_id, digitization_job_id, current_stage_id, canonical_state, due_at)
  values (v_org, p_proposal_id, v_job_id, v_stage_id, 'digitization_queue', case when v_sla is null then null else now() + make_interval(mins => v_sla) end) returning id into v_case_id;
  insert into public.operational_events (organization_id, operational_case_id, event_type, to_state, source, actor_user_id)
  values (v_org, v_case_id, 'queued_for_digitization', 'digitization_queue', 'corban_os', auth.uid());
  update public.proposals_v2 set status='digitization', updated_at=now() where organization_id=v_org and id=p_proposal_id;
  perform set_config('corban.operational_rpc','off',true);
  perform set_config('corban.proposal_rpc','off',true);
  return v_job_id;
end;
$$;


--
-- Name: set_lead_status(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_lead_status(p_lead_id uuid, p_status text, p_lost_reason text DEFAULT NULL::text) RETURNS uuid
    LANGUAGE sql
    SET search_path TO ''
    AS $$
 select private.lead_write((select l.organization_id from public.leads l where l.id=p_lead_id),p_lead_id,'status',jsonb_build_object('status',p_status,'lost_reason',p_lost_reason))
$$;


--
-- Name: set_member_role(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_member_role(p_membership_id uuid, p_role text) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v public.organization_memberships%rowtype; v_actor text;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into v from public.organization_memberships m where m.id=p_membership_id for update;
 if not found then raise exception 'membership_not_found'; end if;
 v_actor:=private.caller_role_in(v.organization_id);
 if v_actor is null or v_actor not in ('admin','manager') then raise exception 'not_authorized'; end if;
 if v.user_id=auth.uid() then raise exception 'cannot_change_own_membership'; end if;
 if p_role is null or p_role not in ('admin','manager','supervisor','agent') then raise exception 'invalid_role'; end if;
 if not public.can_manage_member_role(v_actor,v.role,p_role) then raise exception 'role_change_not_permitted'; end if;
 if v.role=p_role then raise exception 'no_change'; end if;
 perform set_config('corban.membership_rpc','on',true);
 update public.organization_memberships set role=p_role,updated_at=now() where id=p_membership_id;
 insert into public.organization_admin_events(organization_id,actor_user_id,event_type,target_user_id,details) values(v.organization_id,auth.uid(),'member_role_changed',v.user_id,jsonb_build_object('from',v.role,'to',p_role));
 perform set_config('corban.membership_rpc','off',true);
end $$;


--
-- Name: set_member_status(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_member_status(p_membership_id uuid, p_status text) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v public.organization_memberships%rowtype; v_actor text;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into v from public.organization_memberships m where m.id=p_membership_id for update;
 if not found then raise exception 'membership_not_found'; end if;
 v_actor:=private.caller_role_in(v.organization_id);
 if v_actor is null or v_actor not in ('admin','manager') then raise exception 'not_authorized'; end if;
 if v.user_id=auth.uid() then raise exception 'cannot_change_own_membership'; end if;
 if p_status is null or p_status not in ('active','inactive','revoked') then raise exception 'invalid_status'; end if;
 if not public.can_manage_member_role(v_actor,v.role,v.role) then raise exception 'role_change_not_permitted'; end if;
 if v.status=p_status then raise exception 'no_change'; end if;
 perform set_config('corban.membership_rpc','on',true);
 update public.organization_memberships set status=p_status,updated_at=now() where id=p_membership_id;
 insert into public.organization_admin_events(organization_id,actor_user_id,event_type,target_user_id,details) values(v.organization_id,auth.uid(),case when p_status='active' then 'member_reactivated' else 'member_deactivated' end,v.user_id,jsonb_build_object('from',v.status,'to',p_status,'role',v.role));
 perform set_config('corban.membership_rpc','off',true);
end $$;


--
-- Name: set_seller_payment_account(uuid, uuid, text, text, text, text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_seller_payment_account(p_seller_id uuid, p_bank_id uuid, p_branch text, p_account_number text, p_account_digit text, p_account_type text, p_holder_name text, p_holder_document text, p_pix_key_type text, p_pix_key text) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_org uuid; v_id uuid; v_bank_code text; v_bank_name text;
begin
  select organization_id into v_org from public.commercial_sellers where id=p_seller_id;
  if v_org is null then raise exception 'seller_not_found'; end if;
  if not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'forbidden'; end if;

  if p_bank_id is not null then
    select code,name into v_bank_code,v_bank_name from public.banks where id=p_bank_id and is_active;
    if v_bank_name is null then raise exception 'active_bank_required'; end if;
  else
    v_bank_name:='PIX';
  end if;

  if nullif(btrim(coalesce(p_account_number,'')),'') is null
     and nullif(btrim(coalesce(p_pix_key,'')),'') is null
  then raise exception 'account_or_pix_required'; end if;

  perform set_config('corban.seller_profile_rpc','on',true);
  update public.seller_payment_accounts
     set is_current=false,valid_until=now()
   where organization_id=v_org and seller_id=p_seller_id and is_current;

  insert into public.seller_payment_accounts(
    organization_id,seller_id,bank_id,bank_code_snapshot,bank_name_snapshot,branch,
    account_number,account_digit,account_type,holder_name,holder_document,pix_key_type,pix_key,created_by
  ) values(
    v_org,p_seller_id,p_bank_id,v_bank_code,v_bank_name,
    nullif(btrim(p_branch),''),nullif(btrim(p_account_number),''),nullif(btrim(p_account_digit),''),
    nullif(btrim(p_account_type),''),btrim(p_holder_name),
    regexp_replace(coalesce(p_holder_document,''),'[^0-9]','','g'),
    nullif(btrim(p_pix_key_type),''),nullif(btrim(p_pix_key),''),auth.uid()
  ) returning id into v_id;
  perform set_config('corban.seller_profile_rpc','off',true);
  return v_id;
end
$$;


--
-- Name: set_seller_supervision(uuid, uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_seller_supervision(p_seller_id uuid, p_supervisor_user_id uuid, p_active boolean DEFAULT true) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_org uuid;
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;

  select s.organization_id into v_org
  from public.commercial_sellers s
  where s.id=p_seller_id;

  if v_org is null then raise exception 'seller_not_found'; end if;
  if not public.has_active_organization_role(v_org,array['admin','manager']) then
    raise exception 'forbidden';
  end if;

  if not exists(
    select 1 from public.organization_memberships m
    where m.organization_id=v_org
      and m.user_id=p_supervisor_user_id
      and m.role='supervisor'
      and m.status='active'
  ) then raise exception 'active_supervisor_membership_required'; end if;

  perform set_config('corban.seller_access_rpc','on',true);
  insert into public.seller_supervisions(
    organization_id,supervisor_user_id,seller_id,is_active,created_by,updated_by
  ) values(
    v_org,p_supervisor_user_id,p_seller_id,coalesce(p_active,true),auth.uid(),auth.uid()
  )
  on conflict(organization_id,supervisor_user_id,seller_id)
  do update set is_active=excluded.is_active,updated_by=auth.uid(),updated_at=now()
  returning id into v_id;
  perform set_config('corban.seller_access_rpc','off',true);

  perform set_config('corban.membership_rpc','on',true);
  insert into public.organization_admin_events(
    organization_id,actor_user_id,event_type,target_user_id,details
  ) values(
    v_org,auth.uid(),'seller_supervision_updated',p_supervisor_user_id,
    jsonb_build_object('seller_id',p_seller_id,'active',coalesce(p_active,true))
  );
  perform set_config('corban.membership_rpc','off',true);

  return v_id;
end
$$;


--
-- Name: set_seller_user(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_seller_user(p_seller_id uuid, p_user_id uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_org uuid;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;

  select s.organization_id into v_org
  from public.commercial_sellers s
  where s.id=p_seller_id
  for update;

  if v_org is null then raise exception 'seller_not_found'; end if;
  if not public.has_active_organization_role(v_org,array['admin','manager']) then
    raise exception 'forbidden';
  end if;

  if p_user_id is not null and not exists(
    select 1 from public.organization_memberships m
    where m.organization_id=v_org
      and m.user_id=p_user_id
      and m.role='agent'
      and m.status='active'
  ) then raise exception 'active_agent_membership_required'; end if;

  perform set_config('corban.seller_access_rpc','on',true);
  update public.commercial_sellers
  set user_id=p_user_id,updated_at=now()
  where organization_id=v_org and id=p_seller_id;
  perform set_config('corban.seller_access_rpc','off',true);

  perform set_config('corban.membership_rpc','on',true);
  insert into public.organization_admin_events(
    organization_id,actor_user_id,event_type,target_user_id,details
  ) values(
    v_org,auth.uid(),'seller_user_binding_updated',p_user_id,
    jsonb_build_object('seller_id',p_seller_id,'bound_user_id',p_user_id)
  );
  perform set_config('corban.membership_rpc','off',true);

  return p_seller_id;
end
$$;


--
-- Name: settle_ai_job(uuid, text, numeric, numeric, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.settle_ai_job(p_job uuid, p_outcome text, p_credits_charged numeric, p_actual_cost numeric, p_input_units bigint, p_output_units bigint) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare j public.ai_usage_jobs%rowtype; v_charge numeric;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 select * into j from public.ai_usage_jobs x where x.id=p_job for update;
 if not found then raise exception 'job_not_found'; end if;
 if not public.has_active_organization_role(j.organization_id,array['admin','manager','supervisor']) then raise exception 'not_authorized'; end if;
 if p_outcome is null or p_outcome not in ('succeeded','failed','cancelled') then raise exception 'invalid_ai_job'; end if;
 if j.status<>'reserved' then
  if j.status=p_outcome then return j.id; end if;
  raise exception 'job_already_settled';
 end if;
 v_charge:=case when p_outcome='succeeded' then coalesce(p_credits_charged,j.estimated_credits) else 0 end;
 if v_charge<0 or v_charge>j.estimated_credits then raise exception 'charge_exceeds_reservation'; end if;
 if p_actual_cost is not null and p_actual_cost<0 then raise exception 'invalid_ai_job'; end if;
 perform set_config('corban.ai_rpc','on',true);
 update public.ai_usage_jobs set status=p_outcome,credits_charged=v_charge,actual_provider_cost=p_actual_cost,input_units=p_input_units,output_units=p_output_units,settled_at=now() where id=j.id;
 insert into public.ai_credit_ledger(organization_id,kind,credits,job_id,idempotency_key,created_by) values(j.organization_id,'release',j.estimated_credits,j.id,'release:'||j.id,auth.uid());
 if v_charge>0 then insert into public.ai_credit_ledger(organization_id,kind,credits,job_id,idempotency_key,created_by) values(j.organization_id,'charge',-v_charge,j.id,'charge:'||j.id,auth.uid()); end if;
 insert into public.ai_usage_events(organization_id,job_id,event,detail) values(j.organization_id,j.id,p_outcome,jsonb_build_object('credits_charged',v_charge));
 perform set_config('corban.ai_rpc','off',true);
 return j.id;
end $$;


--
-- Name: snapshot_seller_commission(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.snapshot_seller_commission(p_proposal_id uuid) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_org uuid;
  v_seller_id uuid;
  v_seller public.commercial_sellers%rowtype;
  v_sim public.simulations%rowtype;
  v_condition uuid;
  v_base numeric;
  v_share public.commercial_condition_shares%rowtype;
  v_id uuid;
  v_reason text;
begin
  select p.organization_id,p.seller_id
    into v_org,v_seller_id
  from public.proposals_v2 p
  where p.id=p_proposal_id
    and p.seller_id is not null
    and public.has_active_organization_role(p.organization_id,array['admin','manager','supervisor']);

  if v_org is null or v_seller_id is null then return null; end if;

  select s.* into v_seller
  from public.commercial_sellers s
  where s.organization_id=v_org
    and s.id=v_seller_id
    and s.is_active;

  if v_seller.id is null then return null; end if;

  if exists(
    select 1 from public.proposal_seller_commission_snapshots x
    where x.organization_id=v_org and x.proposal_id=p_proposal_id
  ) then
    select x.id into v_id
    from public.proposal_seller_commission_snapshots x
    where x.organization_id=v_org and x.proposal_id=p_proposal_id;
    return v_id;
  end if;

  select s.* into v_sim
  from public.simulations s
  join public.proposals_v2 p
    on p.simulation_id=s.id and p.organization_id=s.organization_id
  where p.id=p_proposal_id and p.organization_id=v_org;

  v_base:=coalesce(v_sim.released_amount,v_sim.requested_amount);

  begin
    v_condition:=nullif(v_sim.input_snapshot->>'condition_id','')::uuid;
  exception when others then
    v_condition:=null;
  end;

  if v_condition is not null then
    select sh.* into v_share
    from public.commercial_condition_shares sh
    where sh.organization_id=v_org
      and sh.condition_id=v_condition
      and sh.group_id=v_seller.commission_group_id;
  end if;

  perform set_config('corban.seller_commission_snapshot','on',true);

  if v_base is not null and v_share.id is not null then
    insert into public.proposal_seller_commission_snapshots(
      organization_id,proposal_id,seller_id,commission_group_id,
      calculation_status,source_kind,calculation_base,effective_pct,amount,
      condition_id,policy_version_id,snapshot
    ) values(
      v_org,p_proposal_id,v_seller.id,v_seller.commission_group_id,
      'calculated','condition_group_share',round(v_base,2),v_share.effective_pct,
      round(v_base*v_share.effective_pct/100,2),
      v_condition,v_share.policy_version_id,
      jsonb_build_object(
        'seller_category',v_seller.seller_category,
        'seller_group_id',v_seller.seller_group_id,
        'commission_group_id',v_seller.commission_group_id,
        'share_source',v_share.source
      )
    ) returning id into v_id;
  else
    v_reason:=case
      when v_sim.id is null then 'simulation_not_available'
      when v_condition is null then 'condition_not_snapshotted'
      when v_base is null then 'calculation_base_not_available'
      when v_share.id is null then 'seller_commission_share_not_resolved'
      else 'seller_commission_not_available'
    end;

    insert into public.proposal_seller_commission_snapshots(
      organization_id,proposal_id,seller_id,commission_group_id,
      calculation_status,source_kind,condition_id,reason,snapshot
    ) values(
      v_org,p_proposal_id,v_seller.id,v_seller.commission_group_id,
      'unavailable','unavailable',v_condition,v_reason,
      jsonb_build_object(
        'seller_category',v_seller.seller_category,
        'seller_group_id',v_seller.seller_group_id,
        'commission_group_id',v_seller.commission_group_id
      )
    ) returning id into v_id;
  end if;

  perform set_config('corban.seller_commission_snapshot','off',true);
  return v_id;
end
$$;


--
-- Name: snapshot_seller_commission_after_component(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.snapshot_seller_commission_after_component() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  if new.seller_id is not null then
    perform public.snapshot_seller_commission(new.proposal_id);
  end if;
  return new;
end
$$;


--
-- Name: sweep_orphaned_integration_runs(integer, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sweep_orphaned_integration_runs(p_limit integer DEFAULT 50, p_now timestamp with time zone DEFAULT now()) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare r public.integration_runs%rowtype; n integer:=0;
begin
 perform set_config('corban.integration_run_rpc','on',true);
 for r in
  select x.* from public.integration_runs x
  where (x.status='queued' or (x.status='failed' and not x.terminal and x.attempt_count<x.max_attempts) or (x.status='running' and x.lease_expires_at<=p_now))
    and (x.created_by is null or not exists(select 1 from public.organization_memberships m where m.organization_id=x.organization_id and m.user_id=x.created_by and m.status='active' and m.role in ('admin','manager','supervisor')))
  order by x.created_at
  limit least(greatest(coalesce(p_limit,50),1),200)
  for update skip locked
 loop
  if r.status='running' then
   update public.integration_runs set status='failed',terminal=true,error_code='terminal:actor_no_longer_authorized',error_message='the member who created this run no longer has access',next_attempt_at=null where id=r.id;
  else
   update public.integration_runs set status='cancelled',error_code='actor_no_longer_authorized',error_message='the member who created this run no longer has access',next_attempt_at=null where id=r.id;
  end if;
  n:=n+1;
 end loop;
 perform set_config('corban.integration_run_rpc','off',true);
 return n;
end $$;


--
-- Name: sync_attention_items(uuid, text[], jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_attention_items(p_organization uuid, p_rule_keys text[], p_items jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare it jsonb; v_id uuid; v_old public.operational_attention_items%rowtype; v_keys text[]:='{}'; v_opened integer:=0; v_updated integer:=0; v_resolved integer:=0; r record;
begin
 if auth.uid() is null then raise exception 'not_authorized'; end if;
 if p_organization is null or not public.has_active_organization_role(p_organization,array['admin','manager','supervisor']) then raise exception 'not_authorized'; end if;
 if p_rule_keys is null or coalesce(array_length(p_rule_keys,1),0)>50 then raise exception 'invalid_items'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)>200 then raise exception 'invalid_items'; end if;
 perform pg_advisory_xact_lock(hashtextextended('attention:'||p_organization::text,0));
 perform set_config('corban.attention_rpc','on',true);
 for it in select * from jsonb_array_elements(p_items) loop
  if jsonb_typeof(it)<>'object' or not (it->>'rule_key') = any(p_rule_keys) or (it->>'severity') not in ('critical','high','medium','low') or coalesce(it->>'dedupe_key','')='' then raise exception 'invalid_items'; end if;
  if jsonb_typeof(coalesce(it->'evidence','{}'::jsonb))<>'object' then raise exception 'invalid_items'; end if;
  v_keys:=v_keys||(it->>'dedupe_key');
  select * into v_old from public.operational_attention_items x where x.organization_id=p_organization and x.dedupe_key=it->>'dedupe_key' and x.status in ('open','snoozed','dismissed');
  if not found then
   insert into public.operational_attention_items(organization_id,rule_key,dedupe_key,severity,title,reason,evidence,impact,recommendation,href)
    values(p_organization,it->>'rule_key',it->>'dedupe_key',it->>'severity',it->>'title',coalesce(it->>'reason',''),coalesce(it->'evidence','{}'::jsonb),coalesce(it->>'impact',''),coalesce(it->>'recommendation',''),it->>'href') returning id into v_id;
   insert into public.operational_attention_events(organization_id,item_id,event,actor,detail) values(p_organization,v_id,'detected',auth.uid(),jsonb_build_object('severity',it->>'severity'));
   v_opened:=v_opened+1;
  else
   update public.operational_attention_items set last_detected_at=now(),severity=it->>'severity',title=it->>'title',reason=coalesce(it->>'reason',''),evidence=coalesce(it->'evidence','{}'::jsonb),impact=coalesce(it->>'impact',''),recommendation=coalesce(it->>'recommendation',''),href=it->>'href',
     status=case when v_old.status='snoozed' and v_old.snoozed_until<=now() then 'open' else v_old.status end,
     snoozed_until=case when v_old.status='snoozed' and v_old.snoozed_until<=now() then null else v_old.snoozed_until end
    where id=v_old.id;
   if v_old.severity<>it->>'severity' then insert into public.operational_attention_events(organization_id,item_id,event,actor,detail) values(p_organization,v_old.id,'severity_changed',auth.uid(),jsonb_build_object('from',v_old.severity,'to',it->>'severity')); end if;
   if v_old.status='snoozed' and v_old.snoozed_until<=now() then insert into public.operational_attention_events(organization_id,item_id,event,actor) values(p_organization,v_old.id,'reopened',auth.uid()); end if;
   v_updated:=v_updated+1;
  end if;
 end loop;
 for r in select x.id from public.operational_attention_items x where x.organization_id=p_organization and x.rule_key=any(p_rule_keys) and x.status in ('open','snoozed','dismissed') and not (x.dedupe_key=any(v_keys)) loop
  update public.operational_attention_items set status='resolved',resolved_at=now(),decided_by=null where id=r.id;
  insert into public.operational_attention_events(organization_id,item_id,event,actor) values(p_organization,r.id,'auto_resolved',auth.uid());
  v_resolved:=v_resolved+1;
 end loop;
 perform set_config('corban.attention_rpc','off',true);
 return jsonb_build_object('opened',v_opened,'updated',v_updated,'resolved',v_resolved);
end $$;


--
-- Name: transition_operational_case(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.transition_operational_case(p_case_id uuid, p_to_state text, p_raw_external_status text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_org uuid;
  v_from text;
  v_proposal uuid;
  v_job uuid;
  v_stage uuid;
  v_sla integer;
  v_role text;
  v_proposal_status text;
begin
  select c.organization_id,c.canonical_state,c.proposal_id,c.digitization_job_id
    into v_org,v_from,v_proposal,v_job
  from public.operational_cases c
  where c.id=p_case_id and public.is_active_organization_member(c.organization_id)
  for update;

  if v_org is null then raise exception 'operational_case_not_found_or_forbidden'; end if;

  select m.role into v_role from public.organization_memberships m
  where m.organization_id=v_org and m.user_id=auth.uid() and m.status='active';
  if v_role is null then raise exception 'active_membership_required'; end if;

  if p_to_state='paid' then
    raise exception 'paid_requires_confirmed_financial_source';
  end if;

  if not (
    (v_from='digitization_queue' and p_to_state in ('digitizing','cancelled')) or
    (v_from='digitizing' and p_to_state in ('submitted','cancelled')) or
    (v_from='submitted' and p_to_state in ('pending_external','approved','rejected','cancelled')) or
    (v_from='pending_external' and p_to_state in ('approved','rejected','cancelled'))
  ) then raise exception 'invalid_operational_state_transition'; end if;

  if p_to_state in ('approved','rejected','cancelled') and v_role not in ('admin','manager','supervisor') then
    raise exception 'operational_decision_requires_privileged_role';
  end if;

  select s.id,s.sla_minutes into v_stage,v_sla
  from public.operational_stages s
  where s.organization_id=v_org and s.canonical_state=p_to_state and s.is_active=true
  order by s.sort_order,s.created_at limit 1;
  if v_stage is null then raise exception 'target_operational_stage_not_configured'; end if;

  perform set_config('corban.operational_rpc','on',true);
  perform set_config('corban.proposal_rpc','on',true);
  update public.operational_cases
  set current_stage_id=v_stage,
      canonical_state=p_to_state,
      entered_stage_at=now(),
      due_at=case when v_sla is null then null else now()+make_interval(mins=>v_sla) end,
      external_status_raw=coalesce(p_raw_external_status,external_status_raw),
      external_status_source=case when p_raw_external_status is null then external_status_source else 'manual' end,
      updated_at=now()
  where organization_id=v_org and id=p_case_id;

  if v_job is not null then
    update public.digitization_jobs
    set status=case
          when p_to_state='digitizing' then 'in_progress'
          when p_to_state in ('submitted','pending_external') then 'submitted'
          when p_to_state='approved' then 'completed'
          when p_to_state in ('rejected','cancelled') then 'cancelled'
          else status end,
        started_at=case when p_to_state='digitizing' then coalesce(started_at,now()) else started_at end,
        submitted_at=case when p_to_state in ('submitted','pending_external','approved') then coalesce(submitted_at,now()) else submitted_at end,
        completed_at=case when p_to_state='approved' then coalesce(completed_at,now()) else completed_at end,
        updated_at=now()
    where organization_id=v_org and id=v_job;
  end if;

  v_proposal_status := case
    when p_to_state='digitizing' then 'digitization'
    when p_to_state in ('submitted','pending_external') then 'submitted'
    when p_to_state='approved' then 'approved'
    when p_to_state='rejected' then 'rejected'
    when p_to_state='cancelled' then 'cancelled'
    else null end;

  if v_proposal_status is not null then
    update public.proposals_v2 set status=v_proposal_status,updated_at=now()
    where organization_id=v_org and id=v_proposal;
  end if;

  insert into public.operational_events(
    organization_id,operational_case_id,event_type,from_state,to_state,
    raw_external_status,source,actor_user_id
  ) values (
    v_org,p_case_id,'state_transition',v_from,p_to_state,
    p_raw_external_status,'corban_os',auth.uid()
  );
  perform set_config('corban.operational_rpc','off',true);
  perform set_config('corban.proposal_rpc','off',true);

  return p_to_state;
end;
$$;


--
-- Name: upsert_seller_certification(uuid, uuid, text, text, text, date, date, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_seller_certification(p_id uuid, p_seller_id uuid, p_name text, p_issuer text, p_certificate_number text, p_issued_at date, p_expires_at date, p_status text, p_notes text) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_org uuid; v_id uuid;
begin
  select organization_id into v_org from public.commercial_sellers where id=p_seller_id;
  if v_org is null then raise exception 'seller_not_found'; end if;
  if not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'forbidden'; end if;
  if p_status not in ('active','expired','revoked','pending') then raise exception 'invalid_certification_status'; end if;

  perform set_config('corban.seller_profile_rpc','on',true);
  if p_id is null then
    insert into public.seller_certifications(
      organization_id,seller_id,name,issuer,certificate_number,issued_at,expires_at,status,notes,created_by,updated_by
    ) values(
      v_org,p_seller_id,btrim(p_name),nullif(btrim(p_issuer),''),nullif(btrim(p_certificate_number),''),
      p_issued_at,p_expires_at,p_status,nullif(btrim(p_notes),''),auth.uid(),auth.uid()
    ) returning id into v_id;
  else
    update public.seller_certifications
       set name=btrim(p_name),issuer=nullif(btrim(p_issuer),''),
           certificate_number=nullif(btrim(p_certificate_number),''),
           issued_at=p_issued_at,expires_at=p_expires_at,status=p_status,
           notes=nullif(btrim(p_notes),''),updated_by=auth.uid(),updated_at=now()
     where organization_id=v_org and id=p_id and seller_id=p_seller_id
     returning id into v_id;
    if v_id is null then raise exception 'certification_not_found'; end if;
  end if;
  perform set_config('corban.seller_profile_rpc','off',true);
  return v_id;
end
$$;


--
-- Name: upsert_seller_profile(uuid, text, text, text, text, text, date, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_seller_profile(p_seller_id uuid, p_legal_name text, p_trade_name text, p_email text, p_phone text, p_whatsapp text, p_birth_or_opening_date date, p_identity_or_registration_number text, p_identity_issuer text, p_occupation text, p_notes text) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_org uuid; v_id uuid;
begin
  select s.organization_id into v_org
  from public.commercial_sellers s
  where s.id=p_seller_id;
  if v_org is null then raise exception 'seller_not_found'; end if;
  if not public.has_active_organization_role(v_org,array['admin','manager']) then raise exception 'forbidden'; end if;

  perform set_config('corban.seller_profile_rpc','on',true);
  insert into public.seller_profiles(
    organization_id,seller_id,legal_name,trade_name,email,phone,whatsapp,birth_or_opening_date,
    identity_or_registration_number,identity_issuer,occupation,notes,created_by,updated_by
  ) values(
    v_org,p_seller_id,nullif(btrim(p_legal_name),''),nullif(btrim(p_trade_name),''),
    nullif(lower(btrim(p_email)),''),nullif(btrim(p_phone),''),nullif(btrim(p_whatsapp),''),
    p_birth_or_opening_date,nullif(btrim(p_identity_or_registration_number),''),
    nullif(btrim(p_identity_issuer),''),nullif(btrim(p_occupation),''),nullif(btrim(p_notes),''),
    auth.uid(),auth.uid()
  )
  on conflict(organization_id,seller_id) do update set
    legal_name=excluded.legal_name,
    trade_name=excluded.trade_name,
    email=excluded.email,
    phone=excluded.phone,
    whatsapp=excluded.whatsapp,
    birth_or_opening_date=excluded.birth_or_opening_date,
    identity_or_registration_number=excluded.identity_or_registration_number,
    identity_issuer=excluded.identity_issuer,
    occupation=excluded.occupation,
    notes=excluded.notes,
    updated_by=auth.uid(),
    updated_at=now()
  returning id into v_id;
  perform set_config('corban.seller_profile_rpc','off',true);
  return v_id;
end
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: agreements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.agreements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    bank_id uuid NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ai_credit_ledger; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_credit_ledger (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    kind text NOT NULL,
    credits numeric(18,4) NOT NULL,
    job_id uuid,
    idempotency_key text NOT NULL,
    note text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ai_credit_ledger_check CHECK ((((kind = ANY (ARRAY['grant'::text, 'release'::text])) AND (credits > (0)::numeric)) OR ((kind = ANY (ARRAY['reserve'::text, 'charge'::text])) AND (credits < (0)::numeric)) OR (kind = 'adjustment'::text))),
    CONSTRAINT ai_credit_ledger_credits_check CHECK ((credits <> (0)::numeric)),
    CONSTRAINT ai_credit_ledger_idempotency_key_check CHECK (((length(idempotency_key) >= 8) AND (length(idempotency_key) <= 140))),
    CONSTRAINT ai_credit_ledger_kind_check CHECK ((kind = ANY (ARRAY['grant'::text, 'reserve'::text, 'release'::text, 'charge'::text, 'adjustment'::text]))),
    CONSTRAINT ai_credit_ledger_note_check CHECK (((note IS NULL) OR (length(note) <= 300)))
);


--
-- Name: ai_usage_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_usage_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    job_id uuid NOT NULL,
    event text NOT NULL,
    detail jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ai_usage_events_detail_check CHECK ((jsonb_typeof(detail) = 'object'::text)),
    CONSTRAINT ai_usage_events_event_check CHECK (((length(event) >= 1) AND (length(event) <= 60)))
);


--
-- Name: ai_usage_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ai_usage_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    capability text NOT NULL,
    provider text NOT NULL,
    model text NOT NULL,
    status text DEFAULT 'reserved'::text NOT NULL,
    source_ref text,
    estimated_credits numeric(18,4) NOT NULL,
    credits_charged numeric(18,4),
    estimated_provider_cost numeric(18,6),
    actual_provider_cost numeric(18,6),
    cost_currency character(3) DEFAULT 'USD'::bpchar NOT NULL,
    input_units bigint,
    output_units bigint,
    idempotency_key text NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    settled_at timestamp with time zone,
    CONSTRAINT ai_usage_jobs_actual_provider_cost_check CHECK (((actual_provider_cost IS NULL) OR (actual_provider_cost >= (0)::numeric))),
    CONSTRAINT ai_usage_jobs_capability_check CHECK ((capability = ANY (ARRAY['import_mapping'::text, 'import_pdf_extraction'::text, 'operational_summary'::text]))),
    CONSTRAINT ai_usage_jobs_credits_charged_check CHECK (((credits_charged IS NULL) OR (credits_charged >= (0)::numeric))),
    CONSTRAINT ai_usage_jobs_estimated_credits_check CHECK ((estimated_credits > (0)::numeric)),
    CONSTRAINT ai_usage_jobs_estimated_provider_cost_check CHECK (((estimated_provider_cost IS NULL) OR (estimated_provider_cost >= (0)::numeric))),
    CONSTRAINT ai_usage_jobs_idempotency_key_check CHECK (((length(idempotency_key) >= 8) AND (length(idempotency_key) <= 120))),
    CONSTRAINT ai_usage_jobs_input_units_check CHECK (((input_units IS NULL) OR (input_units >= 0))),
    CONSTRAINT ai_usage_jobs_model_check CHECK (((length(model) >= 1) AND (length(model) <= 80))),
    CONSTRAINT ai_usage_jobs_output_units_check CHECK (((output_units IS NULL) OR (output_units >= 0))),
    CONSTRAINT ai_usage_jobs_provider_check CHECK (((length(provider) >= 1) AND (length(provider) <= 40))),
    CONSTRAINT ai_usage_jobs_source_ref_check CHECK (((source_ref IS NULL) OR ((length(source_ref) >= 1) AND (length(source_ref) <= 200)))),
    CONSTRAINT ai_usage_jobs_status_check CHECK ((status = ANY (ARRAY['reserved'::text, 'succeeded'::text, 'failed'::text, 'cancelled'::text])))
);


--
-- Name: banks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.banks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text,
    name text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: channel_commission_rule_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.channel_commission_rule_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    channel_id uuid NOT NULL,
    product_table_id uuid NOT NULL,
    version integer NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    operation_type text,
    term_min integer,
    term_max integer,
    rate numeric,
    effective_from timestamp with time zone,
    effective_until timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT channel_commission_rule_versions_check CHECK (((term_max IS NULL) OR (term_max >= term_min))),
    CONSTRAINT channel_commission_rule_versions_check1 CHECK (((effective_until IS NULL) OR (effective_from IS NULL) OR (effective_until > effective_from))),
    CONSTRAINT channel_commission_rule_versions_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'published'::text, 'retired'::text]))),
    CONSTRAINT channel_commission_rule_versions_term_min_check CHECK (((term_min IS NULL) OR (term_min > 0))),
    CONSTRAINT channel_commission_rule_versions_version_check CHECK ((version > 0))
);


--
-- Name: clients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clients (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    organization_id uuid NOT NULL,
    full_name text NOT NULL,
    cpf text NOT NULL,
    phone text,
    email text,
    birth_date date,
    created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    preferred_name text,
    secondary_phone text,
    original_source text,
    notes text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone
);


--
-- Name: commercial_channels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_channels (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    bank_id uuid NOT NULL,
    relationship_id uuid,
    name text NOT NULL,
    external_partner_code text,
    payer_entity_id uuid,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: commercial_condition_commissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_condition_commissions (
    condition_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    received_commission_pct numeric(9,6) NOT NULL,
    net_base_pct numeric(9,6) NOT NULL,
    policy_version_id uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT commercial_condition_commissions_net_base_pct_check CHECK (((net_base_pct >= (0)::numeric) AND (net_base_pct <= (100)::numeric))),
    CONSTRAINT commercial_condition_commissions_received_commission_pct_check CHECK (((received_commission_pct >= (0)::numeric) AND (received_commission_pct <= (100)::numeric)))
);


--
-- Name: commercial_condition_component_policy; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_condition_component_policy (
    condition_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    policy_version_id uuid NOT NULL,
    attached_at timestamp with time zone DEFAULT now() NOT NULL,
    attached_by uuid
);


--
-- Name: commercial_condition_components; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_condition_components (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    condition_id uuid NOT NULL,
    component_type_id uuid NOT NULL,
    value_kind text NOT NULL,
    received_value numeric(18,8) NOT NULL,
    calculation_base text,
    source text DEFAULT 'manual'::text NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT commercial_condition_components_received_value_check CHECK ((received_value >= (0)::numeric)),
    CONSTRAINT commercial_condition_components_source_check CHECK ((source = ANY (ARRAY['manual'::text, 'import'::text, 'upstream'::text, 'adjustment'::text]))),
    CONSTRAINT commercial_condition_components_value_kind_check CHECK ((value_kind = ANY (ARRAY['percentage'::text, 'fixed_brl'::text])))
);


--
-- Name: commercial_condition_shares; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_condition_shares (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    condition_id uuid NOT NULL,
    group_id uuid NOT NULL,
    share_pct numeric(9,6) NOT NULL,
    effective_pct numeric(9,6) NOT NULL,
    source text DEFAULT 'manual'::text NOT NULL,
    policy_version_id uuid,
    CONSTRAINT commercial_condition_shares_effective_pct_check CHECK (((effective_pct >= (0)::numeric) AND (effective_pct <= (100)::numeric))),
    CONSTRAINT commercial_condition_shares_share_pct_check CHECK (((share_pct >= (0)::numeric) AND (share_pct <= (100)::numeric))),
    CONSTRAINT commercial_condition_shares_source_check CHECK ((source = ANY (ARRAY['manual'::text, 'policy'::text, 'override'::text])))
);


--
-- Name: commercial_conditions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_conditions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    product_table_version_id uuid NOT NULL,
    contract_type_id uuid NOT NULL,
    term integer NOT NULL,
    coefficient numeric(14,8),
    rate numeric(9,6),
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    term_min integer NOT NULL,
    term_max integer NOT NULL,
    amount_min numeric(15,2),
    amount_max numeric(15,2),
    CONSTRAINT commercial_conditions_amount_range_check CHECK ((((amount_min IS NULL) AND (amount_max IS NULL)) OR ((amount_min IS NOT NULL) AND (amount_max IS NOT NULL) AND (amount_min >= (0)::numeric) AND (amount_max >= amount_min) AND (amount_max <= 999999999.99)))),
    CONSTRAINT commercial_conditions_coefficient_check CHECK (((coefficient IS NULL) OR (coefficient >= (0)::numeric))),
    CONSTRAINT commercial_conditions_rate_check CHECK (((rate IS NULL) OR (rate >= (0)::numeric))),
    CONSTRAINT commercial_conditions_term_check CHECK (((term >= 1) AND (term <= 600))),
    CONSTRAINT commercial_conditions_term_range_check CHECK ((((term_min >= 1) AND (term_min <= 600)) AND ((term_max >= 1) AND (term_max <= 600)) AND (term_min <= term_max)))
);


--
-- Name: commercial_entities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_entities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    legal_name text NOT NULL,
    trade_name text,
    tax_id text,
    entity_kind text NOT NULL,
    is_internal boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT commercial_entities_entity_kind_check CHECK ((entity_kind = ANY (ARRAY['bank'::text, 'correspondent'::text, 'promotora'::text, 'partner'::text, 'broker'::text, 'indicator'::text, 'association'::text, 'other'::text])))
);


--
-- Name: commercial_factor_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_factor_batches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    profile_id uuid NOT NULL,
    effective_date date NOT NULL,
    revision integer DEFAULT 1 NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    source_kind text NOT NULL,
    import_batch_id uuid,
    source_note text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    published_at timestamp with time zone,
    CONSTRAINT commercial_factor_batches_revision_check CHECK ((revision > 0)),
    CONSTRAINT commercial_factor_batches_source_kind_check CHECK ((source_kind = ANY (ARRAY['manual'::text, 'file'::text, 'api'::text]))),
    CONSTRAINT commercial_factor_batches_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'published'::text])))
);


--
-- Name: commercial_factor_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_factor_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    batch_id uuid NOT NULL,
    term_min integer NOT NULL,
    term_max integer NOT NULL,
    factor_value numeric(18,12) NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT commercial_factor_entries_check CHECK ((((term_max >= 1) AND (term_max <= 600)) AND (term_max >= term_min))),
    CONSTRAINT commercial_factor_entries_factor_value_check CHECK ((factor_value > (0)::numeric)),
    CONSTRAINT commercial_factor_entries_term_min_check CHECK (((term_min >= 1) AND (term_min <= 600)))
);


--
-- Name: commercial_factor_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_factor_profiles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    tech_key text DEFAULT replace((gen_random_uuid())::text, '-'::text, ''::text) NOT NULL,
    name text NOT NULL,
    org_bank_id uuid NOT NULL,
    org_agreement_id uuid,
    product_table_id uuid,
    contract_type_id uuid,
    factor_mode text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT commercial_factor_profiles_factor_mode_check CHECK ((factor_mode = ANY (ARRAY['daily'::text, 'fixed'::text]))),
    CONSTRAINT commercial_factor_profiles_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 120)))
);


--
-- Name: commercial_relationships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_relationships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    upstream_entity_id uuid NOT NULL,
    downstream_entity_id uuid NOT NULL,
    bank_id uuid,
    relationship_role text NOT NULL,
    effective_from timestamp with time zone NOT NULL,
    effective_until timestamp with time zone,
    is_active boolean DEFAULT true NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT commercial_relationships_check CHECK ((upstream_entity_id <> downstream_entity_id)),
    CONSTRAINT commercial_relationships_check1 CHECK (((effective_until IS NULL) OR (effective_until > effective_from))),
    CONSTRAINT commercial_relationships_relationship_role_check CHECK ((relationship_role = ANY (ARRAY['master'::text, 'subestablished'::text, 'partner'::text, 'broker'::text, 'indicator'::text, 'other'::text])))
);


--
-- Name: commercial_sellers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_sellers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    tech_key text DEFAULT replace((gen_random_uuid())::text, '-'::text, ''::text) NOT NULL,
    name text NOT NULL,
    seller_category text NOT NULL,
    tax_id text,
    seller_group_id uuid NOT NULL,
    commission_group_id uuid NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id uuid,
    branch_id uuid NOT NULL,
    commission_payment_frequency text DEFAULT 'monthly'::text NOT NULL,
    CONSTRAINT commercial_sellers_commission_payment_frequency_check CHECK ((commission_payment_frequency = ANY (ARRAY['daily'::text, 'weekly'::text, 'monthly'::text]))),
    CONSTRAINT commercial_sellers_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 160))),
    CONSTRAINT commercial_sellers_seller_category_check CHECK ((seller_category = ANY (ARRAY['pf'::text, 'pj'::text, 'sub'::text]))),
    CONSTRAINT commercial_sellers_tax_id_check CHECK (((tax_id IS NULL) OR ((length(regexp_replace(tax_id, '[^0-9]'::text, ''::text, 'g'::text)) >= 11) AND (length(regexp_replace(tax_id, '[^0-9]'::text, ''::text, 'g'::text)) <= 14))))
);


--
-- Name: commission_component_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commission_component_types (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tech_key text NOT NULL,
    name text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT commission_component_types_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 80)))
);


--
-- Name: commission_group_component_limits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commission_group_component_limits (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    group_id uuid NOT NULL,
    component_type_id uuid NOT NULL,
    max_received_share_pct numeric(9,6) NOT NULL,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT commission_group_component_limits_max_received_share_pct_check CHECK (((max_received_share_pct >= (0)::numeric) AND (max_received_share_pct <= (100)::numeric)))
);


--
-- Name: commission_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commission_groups (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    tech_key text DEFAULT replace((gen_random_uuid())::text, '-'::text, ''::text) NOT NULL,
    name text NOT NULL,
    kind text DEFAULT 'other'::text NOT NULL,
    calculation_basis text DEFAULT 'percent_of_received_commission'::text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT commission_groups_calculation_basis_check CHECK ((calculation_basis = ANY (ARRAY['percent_of_production'::text, 'percent_of_received_commission'::text]))),
    CONSTRAINT commission_groups_kind_check CHECK ((kind = ANY (ARRAY['broker'::text, 'partner'::text, 'referrer'::text, 'employee'::text, 'sales_team'::text, 'counter'::text, 'supervisor'::text, 'manager'::text, 'other'::text]))),
    CONSTRAINT commission_groups_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 80)))
);


--
-- Name: commission_rule_components; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commission_rule_components (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    rule_version_id uuid NOT NULL,
    component_type text NOT NULL,
    percentage numeric,
    fixed_amount numeric,
    anticipation_factor numeric,
    calculation_base text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT commission_rule_components_anticipation_factor_check CHECK (((anticipation_factor IS NULL) OR (anticipation_factor >= (0)::numeric))),
    CONSTRAINT commission_rule_components_component_type_check CHECK ((component_type = ANY (ARRAY['upfront'::text, 'deferred'::text, 'deferred_anticipation'::text, 'campaign_bonus'::text, 'volume_bonus'::text, 'fixed'::text, 'other'::text]))),
    CONSTRAINT commission_rule_components_fixed_amount_check CHECK (((fixed_amount IS NULL) OR (fixed_amount >= (0)::numeric))),
    CONSTRAINT commission_rule_components_percentage_check CHECK (((percentage IS NULL) OR (percentage >= (0)::numeric)))
);


--
-- Name: component_payout_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.component_payout_policies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    tech_key text DEFAULT replace((gen_random_uuid())::text, '-'::text, ''::text) NOT NULL,
    name text NOT NULL,
    org_bank_id uuid,
    org_agreement_id uuid,
    product_table_id uuid,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT component_payout_policies_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 100)))
);


--
-- Name: component_payout_policy_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.component_payout_policy_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    version_id uuid NOT NULL,
    group_id uuid NOT NULL,
    component_type_id uuid NOT NULL,
    mode text NOT NULL,
    share_pct numeric(9,6),
    direct_value_kind text,
    direct_value numeric(18,8),
    CONSTRAINT component_payout_policy_items_check CHECK ((((mode = 'share_of_received'::text) AND (share_pct IS NOT NULL) AND (direct_value_kind IS NULL) AND (direct_value IS NULL)) OR ((mode = 'direct'::text) AND (share_pct IS NULL) AND (direct_value_kind IS NOT NULL) AND (direct_value IS NOT NULL)) OR ((mode = 'exclude'::text) AND (share_pct IS NULL) AND (direct_value_kind IS NULL) AND (direct_value IS NULL)))),
    CONSTRAINT component_payout_policy_items_direct_value_check CHECK ((direct_value >= (0)::numeric)),
    CONSTRAINT component_payout_policy_items_direct_value_kind_check CHECK ((direct_value_kind = ANY (ARRAY['percentage'::text, 'fixed_brl'::text]))),
    CONSTRAINT component_payout_policy_items_mode_check CHECK ((mode = ANY (ARRAY['share_of_received'::text, 'direct'::text, 'exclude'::text]))),
    CONSTRAINT component_payout_policy_items_share_pct_check CHECK (((share_pct >= (0)::numeric) AND (share_pct <= (100)::numeric)))
);


--
-- Name: component_payout_policy_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.component_payout_policy_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    policy_id uuid NOT NULL,
    version integer NOT NULL,
    discount_pct numeric(9,6) DEFAULT 0 NOT NULL,
    effective_from timestamp with time zone NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT component_payout_policy_versions_discount_pct_check CHECK (((discount_pct >= (0)::numeric) AND (discount_pct <= (100)::numeric))),
    CONSTRAINT component_payout_policy_versions_version_check CHECK ((version > 0))
);


--
-- Name: contract_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contract_types (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tech_key text NOT NULL,
    name text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    organization_id uuid,
    created_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT contract_types_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 80)))
);


--
-- Name: contracts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contracts (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    organization_id uuid NOT NULL,
    client_id uuid NOT NULL,
    user_id uuid,
    bank_name text NOT NULL,
    operation_type text NOT NULL,
    contract_value numeric(12,2) NOT NULL,
    commission_percentage numeric(5,2) NOT NULL,
    status text DEFAULT 'pendente'::text,
    created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    CONSTRAINT contracts_status_check CHECK ((status = ANY (ARRAY['pendente'::text, 'em_analise'::text, 'aprovado'::text, 'pago'::text, 'cancelado'::text])))
);


--
-- Name: customer_addresses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_addresses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    label text,
    postal_code text,
    street text,
    number text,
    complement text,
    neighborhood text,
    city text,
    state text,
    country_code text DEFAULT 'BR'::text NOT NULL,
    is_primary boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: customer_bank_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_bank_accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    bank_code text,
    bank_name text NOT NULL,
    branch text,
    account_number text,
    account_digit text,
    account_type text,
    holder_name text,
    holder_document text,
    is_primary boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: customer_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_documents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    document_type_id uuid NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    storage_bucket text NOT NULL,
    storage_path text NOT NULL,
    original_file_name text NOT NULL,
    mime_type text,
    file_size_bytes bigint,
    sha256 text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    issued_at date,
    expires_at date,
    uploaded_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT customer_documents_size_check CHECK (((file_size_bytes IS NULL) OR (file_size_bytes >= 0))),
    CONSTRAINT customer_documents_status_check CHECK ((status = ANY (ARRAY['active'::text, 'superseded'::text, 'invalid'::text]))),
    CONSTRAINT customer_documents_version_check CHECK ((version > 0))
);


--
-- Name: customer_pix_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_pix_keys (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    bank_account_id uuid,
    key_type text NOT NULL,
    key_value text NOT NULL,
    is_primary boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT customer_pix_keys_type_check CHECK ((key_type = ANY (ARRAY['cpf'::text, 'cnpj'::text, 'phone'::text, 'email'::text, 'random'::text])))
);


--
-- Name: customer_timeline_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_timeline_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    event_type text NOT NULL,
    source text NOT NULL,
    actor_user_id uuid,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: digitization_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.digitization_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    proposal_id uuid NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    assigned_to uuid,
    external_reference text,
    attempt_count integer DEFAULT 0 NOT NULL,
    queued_at timestamp with time zone DEFAULT now() NOT NULL,
    started_at timestamp with time zone,
    submitted_at timestamp with time zone,
    completed_at timestamp with time zone,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT digitization_jobs_attempt_check CHECK ((attempt_count >= 0)),
    CONSTRAINT digitization_jobs_priority_check CHECK ((priority >= 0)),
    CONSTRAINT digitization_jobs_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'assigned'::text, 'in_progress'::text, 'blocked'::text, 'submitted'::text, 'completed'::text, 'cancelled'::text])))
);


--
-- Name: document_checklist_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_checklist_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    template_id uuid NOT NULL,
    document_type_id uuid NOT NULL,
    label text NOT NULL,
    is_required boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT document_checklist_items_sort_check CHECK ((sort_order >= 0))
);


--
-- Name: document_checklist_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_checklist_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    route_id uuid NOT NULL,
    version integer NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    name text NOT NULL,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT document_checklist_templates_publication_check CHECK (((status = 'draft'::text) OR (published_at IS NOT NULL))),
    CONSTRAINT document_checklist_templates_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'published'::text, 'superseded'::text]))),
    CONSTRAINT document_checklist_templates_version_check CHECK ((version > 0))
);


--
-- Name: document_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_types (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: financial_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.financial_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    proposal_id uuid,
    channel_id uuid,
    producer_entity_id uuid,
    payer_entity_id uuid,
    event_type text NOT NULL,
    component_type text,
    amount numeric NOT NULL,
    currency text DEFAULT 'BRL'::text NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    idempotency_key text NOT NULL,
    source_kind text NOT NULL,
    source_reference text,
    reverses_event_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT financial_events_amount_check CHECK ((amount >= (0)::numeric)),
    CONSTRAINT financial_events_check CHECK (((event_type = 'reversal'::text) = (reverses_event_id IS NOT NULL))),
    CONSTRAINT financial_events_component_type_check CHECK ((component_type = ANY (ARRAY['upfront'::text, 'deferred'::text, 'deferred_anticipation'::text, 'campaign_bonus'::text, 'volume_bonus'::text, 'fixed'::text, 'other'::text]))),
    CONSTRAINT financial_events_event_type_check CHECK ((event_type = ANY (ARRAY['commission_expected'::text, 'network_share_expected'::text, 'bonus_expected'::text, 'commission_reported'::text, 'payment_received'::text, 'downstream_payable'::text, 'downstream_paid'::text, 'reversal'::text, 'adjustment'::text]))),
    CONSTRAINT financial_events_source_kind_check CHECK ((source_kind = ANY (ARRAY['proposal_snapshot'::text, 'import'::text, 'bank_report'::text, 'partner_report'::text, 'payment_evidence'::text, 'manual_review'::text, 'system'::text])))
);


--
-- Name: financial_evidence_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.financial_evidence_links (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    financial_event_id uuid NOT NULL,
    import_batch_id uuid,
    import_raw_row_id uuid,
    import_decision_id uuid,
    evidence_kind text NOT NULL,
    evidence_reference text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT financial_evidence_links_check CHECK (((import_batch_id IS NOT NULL) OR (import_raw_row_id IS NOT NULL) OR (import_decision_id IS NOT NULL) OR (evidence_reference IS NOT NULL)))
);


--
-- Name: financial_reconciliation_cases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.financial_reconciliation_cases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    proposal_id uuid,
    channel_id uuid,
    component_type text,
    expected_amount numeric,
    reported_amount numeric,
    settled_amount numeric,
    divergence_amount numeric GENERATED ALWAYS AS ((COALESCE(settled_amount, reported_amount, (0)::numeric) - COALESCE(expected_amount, (0)::numeric))) STORED,
    status text DEFAULT 'open'::text NOT NULL,
    resolution_note text,
    resolved_by uuid,
    resolved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT financial_reconciliation_cases_expected_amount_check CHECK (((expected_amount IS NULL) OR (expected_amount >= (0)::numeric))),
    CONSTRAINT financial_reconciliation_cases_reported_amount_check CHECK (((reported_amount IS NULL) OR (reported_amount >= (0)::numeric))),
    CONSTRAINT financial_reconciliation_cases_settled_amount_check CHECK (((settled_amount IS NULL) OR (settled_amount >= (0)::numeric))),
    CONSTRAINT financial_reconciliation_cases_status_check CHECK ((status = ANY (ARRAY['open'::text, 'matched'::text, 'divergent'::text, 'human_required'::text, 'resolved'::text])))
);


--
-- Name: import_applied_decisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.import_applied_decisions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    decision_id uuid NOT NULL,
    proposal_external_identity_id uuid,
    table_external_identity_id uuid,
    applied_by uuid NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: import_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.import_batches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    source_id uuid NOT NULL,
    original_filename text NOT NULL,
    content_sha256 text NOT NULL,
    storage_path text,
    mime_type text,
    parser_key text,
    parser_version text,
    status text DEFAULT 'received'::text NOT NULL,
    row_count integer,
    received_by uuid,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    adapter_id uuid,
    adapter_contract_version text,
    external_batch_id text,
    occurred_at timestamp with time zone,
    CONSTRAINT import_batches_status_check CHECK ((status = ANY (ARRAY['received'::text, 'parsed'::text, 'normalized'::text, 'matching'::text, 'ready_for_review'::text, 'approved'::text, 'applied'::text, 'failed'::text, 'rejected'::text])))
);


--
-- Name: import_conflict_rows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.import_conflict_rows (
    conflict_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    raw_row_id uuid NOT NULL
);


--
-- Name: import_conflicts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.import_conflicts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    batch_id uuid NOT NULL,
    kind text NOT NULL,
    severity text NOT NULL,
    identity_key text,
    detail jsonb DEFAULT '{}'::jsonb NOT NULL,
    fingerprint text NOT NULL,
    auto_publish_allowed boolean DEFAULT false NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    resolution_note text,
    resolved_by uuid,
    resolved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT import_conflicts_auto_publish_allowed_check CHECK ((auto_publish_allowed = false)),
    CONSTRAINT import_conflicts_detail_check CHECK (((jsonb_typeof(detail) = 'object'::text) AND (octet_length((detail)::text) <= 8000))),
    CONSTRAINT import_conflicts_kind_check CHECK ((kind = ANY (ARRAY['duplicate_row'::text, 'duplicate_file'::text, 'multi_source_same_proposal'::text, 'contradictory_status'::text, 'ambiguous_identity'::text, 'correction_replay'::text, 'cross_tenant_attempt'::text, 'unknown_schema'::text, 'unresolved_matching'::text, 'missing_identity'::text]))),
    CONSTRAINT import_conflicts_severity_check CHECK ((severity = ANY (ARRAY['info'::text, 'review'::text, 'block'::text]))),
    CONSTRAINT import_conflicts_status_check CHECK ((status = ANY (ARRAY['open'::text, 'resolved'::text, 'dismissed'::text])))
);


--
-- Name: import_decisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.import_decisions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    batch_id uuid NOT NULL,
    normalized_row_id uuid,
    candidate_id uuid,
    decision text NOT NULL,
    reason text,
    decided_by uuid,
    decided_at timestamp with time zone DEFAULT now() NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT import_decisions_decision_check CHECK ((decision = ANY (ARRAY['approve'::text, 'reject'::text, 'map'::text, 'ignore'::text, 'human_required'::text])))
);


--
-- Name: import_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.import_jobs (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    organization_id uuid NOT NULL,
    file_name text NOT NULL,
    status text DEFAULT 'processando'::text,
    total_records integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    CONSTRAINT import_jobs_status_check CHECK ((status = ANY (ARRAY['processando'::text, 'concluido'::text, 'erro'::text])))
);


--
-- Name: import_layout_mappings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.import_layout_mappings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    source_label text NOT NULL,
    layout_fingerprint text NOT NULL,
    version integer NOT NULL,
    mapping jsonb NOT NULL,
    unknown_columns jsonb DEFAULT '[]'::jsonb NOT NULL,
    confidence numeric(5,4),
    provider text,
    model text,
    status text DEFAULT 'confirmed'::text NOT NULL,
    confirmed_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT import_layout_mappings_confidence_check CHECK (((confidence IS NULL) OR ((confidence >= (0)::numeric) AND (confidence <= (1)::numeric)))),
    CONSTRAINT import_layout_mappings_layout_fingerprint_check CHECK ((layout_fingerprint ~ '^[0-9a-f]{64}$'::text)),
    CONSTRAINT import_layout_mappings_mapping_check CHECK ((jsonb_typeof(mapping) = 'object'::text)),
    CONSTRAINT import_layout_mappings_model_check CHECK (((model IS NULL) OR ((length(model) >= 1) AND (length(model) <= 80)))),
    CONSTRAINT import_layout_mappings_provider_check CHECK (((provider IS NULL) OR ((length(provider) >= 1) AND (length(provider) <= 40)))),
    CONSTRAINT import_layout_mappings_source_label_check CHECK (((length(btrim(source_label)) >= 1) AND (length(btrim(source_label)) <= 120))),
    CONSTRAINT import_layout_mappings_status_check CHECK ((status = ANY (ARRAY['confirmed'::text, 'superseded'::text]))),
    CONSTRAINT import_layout_mappings_unknown_columns_check CHECK ((jsonb_typeof(unknown_columns) = 'array'::text)),
    CONSTRAINT import_layout_mappings_version_check CHECK ((version > 0))
);


--
-- Name: import_match_candidates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.import_match_candidates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    normalized_row_id uuid NOT NULL,
    proposal_id uuid,
    product_table_id uuid,
    channel_id uuid,
    producer_entity_id uuid,
    match_strength text NOT NULL,
    match_basis jsonb NOT NULL,
    status text DEFAULT 'suggested'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    seller_id uuid,
    CONSTRAINT import_match_candidates_match_strength_check CHECK ((match_strength = ANY (ARRAY['exact'::text, 'strong'::text, 'probable'::text, 'ambiguous'::text, 'none'::text]))),
    CONSTRAINT import_match_candidates_status_check CHECK ((status = ANY (ARRAY['suggested'::text, 'accepted'::text, 'rejected'::text, 'human_required'::text])))
);


--
-- Name: import_normalized_rows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.import_normalized_rows (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    raw_row_id uuid NOT NULL,
    record_kind text NOT NULL,
    bank_key text,
    external_proposal_number text,
    producer_tax_id text,
    external_table_code text,
    external_table_name text,
    operation_type text,
    term integer,
    rate numeric,
    commission_upfront numeric,
    commission_deferred numeric,
    amount numeric,
    normalized_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    normalization_version text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    producer_external_user text,
    resolved_seller_id uuid,
    CONSTRAINT import_normalized_rows_record_kind_check CHECK ((record_kind = ANY (ARRAY['table_offer'::text, 'proposal'::text, 'commission'::text, 'payment'::text, 'status'::text, 'network_production'::text, 'other'::text])))
);


--
-- Name: import_raw_rows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.import_raw_rows (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    batch_id uuid NOT NULL,
    row_number integer NOT NULL,
    raw_payload jsonb NOT NULL,
    raw_hash text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT import_raw_rows_row_number_check CHECK ((row_number > 0))
);


--
-- Name: import_sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.import_sources (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    source_kind text NOT NULL,
    source_entity_id uuid,
    name text NOT NULL,
    external_code text,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    financial_semantic text DEFAULT 'commercial_offer'::text NOT NULL,
    financial_semantic_reviewed_by uuid,
    financial_semantic_reviewed_at timestamp with time zone,
    CONSTRAINT import_sources_financial_semantic_check CHECK ((financial_semantic = ANY (ARRAY['commercial_offer'::text, 'production_report'::text, 'commission_statement'::text, 'payment_statement'::text, 'network_payment_statement'::text]))),
    CONSTRAINT import_sources_source_kind_check CHECK ((source_kind = ANY (ARRAY['bank'::text, 'correspondent'::text, 'promotora'::text, 'partner'::text, 'legacy_system'::text, 'manual'::text, 'other'::text])))
);


--
-- Name: integration_adapters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.integration_adapters (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    adapter_key text NOT NULL,
    provider_key text NOT NULL,
    transport text NOT NULL,
    name text NOT NULL,
    contract_version text NOT NULL,
    capabilities jsonb DEFAULT '[]'::jsonb NOT NULL,
    config_schema jsonb DEFAULT '{}'::jsonb NOT NULL,
    credential_strategy text DEFAULT 'none'::text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT integration_adapters_capabilities_check CHECK ((jsonb_typeof(capabilities) = 'array'::text)),
    CONSTRAINT integration_adapters_config_schema_check CHECK ((jsonb_typeof(config_schema) = 'object'::text)),
    CONSTRAINT integration_adapters_credential_strategy_check CHECK ((credential_strategy = ANY (ARRAY['none'::text, 'runtime_secret'::text, 'oauth'::text, 'external_vault'::text]))),
    CONSTRAINT integration_adapters_status_check CHECK ((status = ANY (ARRAY['active'::text, 'experimental'::text, 'disabled'::text]))),
    CONSTRAINT integration_adapters_transport_check CHECK ((transport = ANY (ARRAY['file'::text, 'api'::text, 'webhook'::text, 'sftp'::text, 'manual'::text])))
);


--
-- Name: TABLE integration_adapters; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.integration_adapters IS 'Provider-agnostic adapter catalog. Never store credentials here.';


--
-- Name: integration_field_mappings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.integration_field_mappings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    adapter_id uuid NOT NULL,
    contract_version text NOT NULL,
    source_field text NOT NULL,
    canonical_field text NOT NULL,
    transform_key text DEFAULT 'identity'::text NOT NULL,
    semantic_class text DEFAULT 'descriptive'::text NOT NULL,
    required boolean DEFAULT false NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT integration_field_mappings_semantic_class_check CHECK ((semantic_class = ANY (ARRAY['identity'::text, 'descriptive'::text, 'status'::text, 'commercial'::text, 'financial'::text, 'sensitive'::text])))
);


--
-- Name: TABLE integration_field_mappings; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.integration_field_mappings IS 'Versioned adapter-to-canonical mapping contract. Source-specific semantics remain explicit and do not become financial truth automatically.';


--
-- Name: integration_run_artifacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.integration_run_artifacts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    run_id uuid NOT NULL,
    artifact_kind text NOT NULL,
    import_batch_id uuid,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    content_sha256 text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT integration_run_artifacts_artifact_kind_check CHECK ((artifact_kind = ANY (ARRAY['request_metadata'::text, 'response_metadata'::text, 'raw_payload'::text, 'import_batch'::text, 'diagnostic'::text]))),
    CONSTRAINT integration_run_artifacts_payload_check CHECK ((jsonb_typeof(payload) = 'object'::text))
);


--
-- Name: TABLE integration_run_artifacts; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.integration_run_artifacts IS 'Non-secret execution evidence and lineage; raw provider payload may be recorded here only after adapter-side redaction.';


--
-- Name: integration_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.integration_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    binding_id uuid NOT NULL,
    adapter_id uuid NOT NULL,
    capability text NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    request_fingerprint text NOT NULL,
    external_request_id text,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    attempt_count integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 3 NOT NULL,
    error_code text,
    error_message text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    next_attempt_at timestamp with time zone,
    lease_expires_at timestamp with time zone,
    claim_token uuid,
    terminal boolean DEFAULT false NOT NULL,
    correlation_id text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    parent_run_id uuid,
    reexecution_reason text,
    CONSTRAINT integration_runs_attempt_count_check CHECK ((attempt_count >= 0)),
    CONSTRAINT integration_runs_attempts_le_max CHECK ((attempt_count <= max_attempts)),
    CONSTRAINT integration_runs_correlation_len CHECK (((correlation_id IS NULL) OR (length(correlation_id) <= 128))),
    CONSTRAINT integration_runs_error_len CHECK (((error_message IS NULL) OR (length(error_message) <= 500))),
    CONSTRAINT integration_runs_max_attempts_check CHECK (((max_attempts >= 1) AND (max_attempts <= 10))),
    CONSTRAINT integration_runs_metadata_check CHECK ((jsonb_typeof(metadata) = 'object'::text)),
    CONSTRAINT integration_runs_not_own_parent CHECK ((parent_run_id IS DISTINCT FROM id)),
    CONSTRAINT integration_runs_reexec_pair CHECK (((parent_run_id IS NULL) = (reexecution_reason IS NULL))),
    CONSTRAINT integration_runs_reexec_reason_len CHECK (((reexecution_reason IS NULL) OR ((length(reexecution_reason) >= 10) AND (length(reexecution_reason) <= 500)))),
    CONSTRAINT integration_runs_running_has_lease CHECK (((status <> 'running'::text) OR ((claim_token IS NOT NULL) AND (lease_expires_at IS NOT NULL) AND (started_at IS NOT NULL)))),
    CONSTRAINT integration_runs_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'running'::text, 'succeeded'::text, 'failed'::text, 'cancelled'::text])))
);


--
-- Name: TABLE integration_runs; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.integration_runs IS 'Auditable idempotent execution envelope for provider adapters. No credentials or access tokens.';


--
-- Name: integration_source_bindings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.integration_source_bindings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    source_id uuid NOT NULL,
    adapter_id uuid NOT NULL,
    external_account_code text,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT integration_source_bindings_settings_check CHECK ((jsonb_typeof(settings) = 'object'::text))
);


--
-- Name: TABLE integration_source_bindings; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.integration_source_bindings IS 'Tenant/source adapter binding. settings must contain non-secret configuration only.';


--
-- Name: lead_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lead_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    lead_id uuid NOT NULL,
    event_type text NOT NULL,
    from_status text,
    to_status text,
    actor_user_id uuid,
    detail jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT lead_events_detail_check CHECK (((jsonb_typeof(detail) = 'object'::text) AND (octet_length((detail)::text) <= 4000))),
    CONSTRAINT lead_events_event_type_check CHECK ((event_type = ANY (ARRAY['created'::text, 'status_changed'::text, 'owner_changed'::text, 'converted'::text, 'note'::text, 'reactivated'::text])))
);


--
-- Name: leads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.leads (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    status text DEFAULT 'new'::text NOT NULL,
    channel text NOT NULL,
    campaign text,
    external_ref text,
    full_name text NOT NULL,
    phone text,
    email text,
    owner_user_id uuid,
    customer_id uuid,
    converted_at timestamp with time zone,
    lost_reason text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT leads_channel_check CHECK ((channel = ANY (ARRAY['whatsapp'::text, 'meta_ads'::text, 'api'::text, 'import'::text, 'manual'::text, 'referral'::text, 'other'::text]))),
    CONSTRAINT leads_converted_consistency CHECK (((status = 'converted'::text) = ((customer_id IS NOT NULL) AND (converted_at IS NOT NULL)))),
    CONSTRAINT leads_full_name_check CHECK (((length(btrim(full_name)) >= 2) AND (length(btrim(full_name)) <= 200))),
    CONSTRAINT leads_lost_needs_reason CHECK (((status <> 'lost'::text) OR (NULLIF(btrim(lost_reason), ''::text) IS NOT NULL))),
    CONSTRAINT leads_metadata_check CHECK (((jsonb_typeof(metadata) = 'object'::text) AND (octet_length((metadata)::text) <= 8000))),
    CONSTRAINT leads_status_check CHECK ((status = ANY (ARRAY['new'::text, 'contacted'::text, 'qualified'::text, 'converted'::text, 'lost'::text])))
);


--
-- Name: modalities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.modalities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_id uuid NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: national_agreement_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.national_agreement_templates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    tech_key text NOT NULL,
    kind text NOT NULL,
    name text NOT NULL,
    uf character(2) NOT NULL,
    city text,
    sort_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT national_agreement_templates_check CHECK ((((kind = 'capital_city_hall'::text) AND (city IS NOT NULL)) OR ((kind = 'state_government'::text) AND (city IS NULL)))),
    CONSTRAINT national_agreement_templates_kind_check CHECK ((kind = ANY (ARRAY['state_government'::text, 'capital_city_hall'::text]))),
    CONSTRAINT national_agreement_templates_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 120)))
);


--
-- Name: network_split_rule_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.network_split_rule_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    relationship_id uuid NOT NULL,
    bank_id uuid,
    product_table_id uuid,
    component_type text,
    version integer NOT NULL,
    downstream_share numeric NOT NULL,
    upstream_share numeric NOT NULL,
    payment_flow text NOT NULL,
    effective_from timestamp with time zone NOT NULL,
    effective_until timestamp with time zone,
    status text DEFAULT 'draft'::text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT network_split_rule_versions_check CHECK (((downstream_share + upstream_share) = (1)::numeric)),
    CONSTRAINT network_split_rule_versions_check1 CHECK (((effective_until IS NULL) OR (effective_until > effective_from))),
    CONSTRAINT network_split_rule_versions_downstream_share_check CHECK (((downstream_share >= (0)::numeric) AND (downstream_share <= (1)::numeric))),
    CONSTRAINT network_split_rule_versions_payment_flow_check CHECK ((payment_flow = ANY (ARRAY['direct_by_payer'::text, 'through_upstream'::text, 'through_downstream'::text, 'other'::text]))),
    CONSTRAINT network_split_rule_versions_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'published'::text, 'retired'::text]))),
    CONSTRAINT network_split_rule_versions_upstream_share_check CHECK (((upstream_share >= (0)::numeric) AND (upstream_share <= (1)::numeric))),
    CONSTRAINT network_split_rule_versions_version_check CHECK ((version > 0))
);


--
-- Name: operational_attention_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.operational_attention_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    item_id uuid NOT NULL,
    event text NOT NULL,
    actor uuid,
    note text,
    detail jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT operational_attention_events_detail_check CHECK ((jsonb_typeof(detail) = 'object'::text)),
    CONSTRAINT operational_attention_events_event_check CHECK ((event = ANY (ARRAY['detected'::text, 'severity_changed'::text, 'resolved'::text, 'auto_resolved'::text, 'dismissed'::text, 'snoozed'::text, 'reopened'::text, 'assigned'::text]))),
    CONSTRAINT operational_attention_events_note_check CHECK (((note IS NULL) OR (length(note) <= 500)))
);


--
-- Name: operational_attention_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.operational_attention_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    rule_key text NOT NULL,
    dedupe_key text NOT NULL,
    severity text NOT NULL,
    title text NOT NULL,
    reason text DEFAULT ''::text NOT NULL,
    evidence jsonb DEFAULT '{}'::jsonb NOT NULL,
    impact text DEFAULT ''::text NOT NULL,
    recommendation text DEFAULT ''::text NOT NULL,
    href text NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    snoozed_until timestamp with time zone,
    assigned_to uuid,
    first_detected_at timestamp with time zone DEFAULT now() NOT NULL,
    last_detected_at timestamp with time zone DEFAULT now() NOT NULL,
    resolved_at timestamp with time zone,
    decided_by uuid,
    CONSTRAINT operational_attention_items_check CHECK (((status <> 'snoozed'::text) OR (snoozed_until IS NOT NULL))),
    CONSTRAINT operational_attention_items_dedupe_key_check CHECK (((length(dedupe_key) >= 3) AND (length(dedupe_key) <= 160))),
    CONSTRAINT operational_attention_items_evidence_check CHECK (((jsonb_typeof(evidence) = 'object'::text) AND (pg_column_size(evidence) <= 8192))),
    CONSTRAINT operational_attention_items_href_check CHECK ((href ~ '^/app(/[a-z0-9_-]+)*$'::text)),
    CONSTRAINT operational_attention_items_impact_check CHECK ((length(impact) <= 300)),
    CONSTRAINT operational_attention_items_reason_check CHECK ((length(reason) <= 500)),
    CONSTRAINT operational_attention_items_recommendation_check CHECK ((length(recommendation) <= 300)),
    CONSTRAINT operational_attention_items_rule_key_check CHECK ((rule_key ~ '^[a-z][a-z0-9_]{2,59}$'::text)),
    CONSTRAINT operational_attention_items_severity_check CHECK ((severity = ANY (ARRAY['critical'::text, 'high'::text, 'medium'::text, 'low'::text]))),
    CONSTRAINT operational_attention_items_status_check CHECK ((status = ANY (ARRAY['open'::text, 'resolved'::text, 'dismissed'::text, 'snoozed'::text]))),
    CONSTRAINT operational_attention_items_title_check CHECK (((length(btrim(title)) >= 1) AND (length(btrim(title)) <= 160)))
);


--
-- Name: operational_cases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.operational_cases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    proposal_id uuid NOT NULL,
    digitization_job_id uuid,
    current_stage_id uuid NOT NULL,
    canonical_state text NOT NULL,
    owner_user_id uuid,
    entered_stage_at timestamp with time zone DEFAULT now() NOT NULL,
    due_at timestamp with time zone,
    external_status_raw text,
    external_status_source text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT operational_cases_state_check CHECK ((canonical_state = ANY (ARRAY['digitization_queue'::text, 'digitizing'::text, 'submitted'::text, 'pending_external'::text, 'approved'::text, 'paid'::text, 'cancelled'::text, 'rejected'::text])))
);


--
-- Name: operational_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.operational_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    operational_case_id uuid NOT NULL,
    event_type text NOT NULL,
    from_state text,
    to_state text,
    raw_external_status text,
    source text NOT NULL,
    actor_user_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: operational_stages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.operational_stages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    canonical_state text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    sla_minutes integer,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT operational_stages_canonical_check CHECK ((canonical_state = ANY (ARRAY['digitization_queue'::text, 'digitizing'::text, 'submitted'::text, 'pending_external'::text, 'approved'::text, 'paid'::text, 'cancelled'::text, 'rejected'::text]))),
    CONSTRAINT operational_stages_sla_check CHECK (((sla_minutes IS NULL) OR (sla_minutes >= 0))),
    CONSTRAINT operational_stages_sort_check CHECK ((sort_order >= 0))
);


--
-- Name: organization_admin_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_admin_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    actor_user_id uuid,
    event_type text NOT NULL,
    target_user_id uuid,
    target_email text,
    details jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT organization_admin_events_event_type_check CHECK ((event_type = ANY (ARRAY['invite_created'::text, 'invite_revoked'::text, 'invite_accepted'::text, 'member_role_changed'::text, 'member_deactivated'::text, 'member_reactivated'::text, 'seller_created'::text, 'seller_user_binding_updated'::text, 'seller_supervision_updated'::text])))
);


--
-- Name: organization_agreements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_agreements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    tech_key text DEFAULT replace((gen_random_uuid())::text, '-'::text, ''::text) NOT NULL,
    template_id uuid,
    name text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT organization_agreements_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 120)))
);


--
-- Name: organization_ai_limits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_ai_limits (
    organization_id uuid NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    monthly_credit_limit numeric(18,4) DEFAULT 0 NOT NULL,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT organization_ai_limits_monthly_credit_limit_check CHECK ((monthly_credit_limit >= (0)::numeric))
);


--
-- Name: organization_banks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_banks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    tech_key text DEFAULT replace((gen_random_uuid())::text, '-'::text, ''::text) NOT NULL,
    name text NOT NULL,
    official_code text,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT organization_banks_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 120))),
    CONSTRAINT organization_banks_official_code_check CHECK (((official_code IS NULL) OR ((length(btrim(official_code)) >= 1) AND (length(btrim(official_code)) <= 20))))
);


--
-- Name: organization_branches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_branches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    branch_type text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT organization_branches_branch_type_check CHECK ((branch_type = ANY (ARRAY['matrix'::text, 'branch'::text])))
);


--
-- Name: organization_contract_type_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_contract_type_settings (
    organization_id uuid NOT NULL,
    contract_type_id uuid NOT NULL,
    is_enabled boolean DEFAULT true NOT NULL,
    use_in_pipeline boolean DEFAULT true NOT NULL,
    use_in_commission boolean DEFAULT true NOT NULL,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: organization_invitations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_invitations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    email text NOT NULL,
    role text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    invited_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone DEFAULT (now() + '7 days'::interval) NOT NULL,
    resolved_at timestamp with time zone,
    accepted_user_id uuid,
    seller_id uuid,
    CONSTRAINT organization_invitations_email_check CHECK (((email = lower(btrim(email))) AND ((length(email) >= 3) AND (length(email) <= 254)) AND (email ~ '^[^@[:space:]]+@[^@[:space:]]+$'::text))),
    CONSTRAINT organization_invitations_role_check CHECK ((role = ANY (ARRAY['admin'::text, 'manager'::text, 'supervisor'::text, 'agent'::text]))),
    CONSTRAINT organization_invitations_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'accepted'::text, 'revoked'::text, 'expired'::text])))
);


--
-- Name: organization_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_memberships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT organization_memberships_role_check CHECK ((role = ANY (ARRAY['admin'::text, 'manager'::text, 'supervisor'::text, 'agent'::text]))),
    CONSTRAINT organization_memberships_status_check CHECK ((status = ANY (ARRAY['active'::text, 'inactive'::text, 'revoked'::text])))
);


--
-- Name: TABLE organization_memberships; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.organization_memberships IS 'Explicit tenant memberships for Corban OS V2. Mutations are backend/service controlled; authenticated users only read their active memberships.';


--
-- Name: organization_product_routes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_product_routes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    bank_id uuid,
    provider_id uuid,
    agreement_id uuid,
    product_id uuid,
    modality_id uuid,
    status text DEFAULT 'active'::text NOT NULL,
    external_code text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    org_bank_id uuid,
    org_provider_id uuid,
    org_agreement_id uuid,
    production_origin text,
    CONSTRAINT organization_product_routes_production_origin_check CHECK ((production_origin = ANY (ARRAY['own'::text, 'third_party'::text]))),
    CONSTRAINT organization_product_routes_shape CHECK ((((bank_id IS NOT NULL) AND (provider_id IS NOT NULL) AND (agreement_id IS NOT NULL) AND (product_id IS NOT NULL) AND (modality_id IS NOT NULL) AND (org_bank_id IS NULL) AND (org_provider_id IS NULL) AND (org_agreement_id IS NULL) AND (production_origin IS NULL)) OR ((org_bank_id IS NOT NULL) AND (org_agreement_id IS NOT NULL) AND (bank_id IS NULL) AND (provider_id IS NULL) AND (agreement_id IS NULL) AND (product_id IS NULL) AND (modality_id IS NULL) AND (production_origin IS NOT NULL) AND (((production_origin = 'own'::text) AND (org_provider_id IS NULL)) OR ((production_origin = 'third_party'::text) AND (org_provider_id IS NOT NULL)))))),
    CONSTRAINT organization_product_routes_status_check CHECK ((status = ANY (ARRAY['active'::text, 'inactive'::text])))
);


--
-- Name: organization_providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organization_providers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    tech_key text DEFAULT replace((gen_random_uuid())::text, '-'::text, ''::text) NOT NULL,
    name text NOT NULL,
    provider_type text DEFAULT 'other'::text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT organization_providers_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 120))),
    CONSTRAINT organization_providers_provider_type_check CHECK ((provider_type = ANY (ARRAY['bank_direct'::text, 'master'::text, 'promotora'::text, 'correspondent'::text, 'partner'::text, 'other'::text])))
);


--
-- Name: organizations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.organizations (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    name text NOT NULL,
    document text NOT NULL,
    plan_type text DEFAULT 'standard'::text,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL
);


--
-- Name: payout_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payout_policies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    tech_key text DEFAULT replace((gen_random_uuid())::text, '-'::text, ''::text) NOT NULL,
    name text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT payout_policies_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 80)))
);


--
-- Name: payout_policy_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payout_policy_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    version_id uuid NOT NULL,
    group_id uuid NOT NULL,
    pct numeric(9,6) NOT NULL,
    CONSTRAINT payout_policy_items_pct_check CHECK (((pct >= (0)::numeric) AND (pct <= (100)::numeric)))
);


--
-- Name: payout_policy_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payout_policy_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    policy_id uuid NOT NULL,
    version integer NOT NULL,
    base_kind text NOT NULL,
    discount_pct numeric(9,6) DEFAULT 0 NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT payout_policy_versions_base_kind_check CHECK ((base_kind = ANY (ARRAY['gross'::text, 'net'::text]))),
    CONSTRAINT payout_policy_versions_check CHECK (((base_kind = 'net'::text) OR (discount_pct = (0)::numeric))),
    CONSTRAINT payout_policy_versions_discount_pct_check CHECK (((discount_pct >= (0)::numeric) AND (discount_pct <= (100)::numeric))),
    CONSTRAINT payout_policy_versions_version_check CHECK ((version > 0))
);


--
-- Name: platform_admin_audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_admin_audit_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    actor_user_id uuid NOT NULL,
    action text NOT NULL,
    target_user_id uuid,
    organization_id uuid,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: platform_administrators; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_administrators (
    user_id uuid NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT platform_administrators_status_check CHECK ((status = ANY (ARRAY['active'::text, 'inactive'::text, 'revoked'::text])))
);


--
-- Name: product_table_external_identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_table_external_identities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    product_table_id uuid NOT NULL,
    channel_id uuid NOT NULL,
    external_code text NOT NULL,
    external_name text,
    effective_from timestamp with time zone NOT NULL,
    effective_until timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT product_table_external_identities_check CHECK (((effective_until IS NULL) OR (effective_until > effective_from)))
);


--
-- Name: product_table_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_table_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    product_table_id uuid NOT NULL,
    version integer NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    effective_from timestamp with time zone,
    effective_until timestamp with time zone,
    term_min integer,
    term_max integer,
    rate numeric(12,8),
    coefficient numeric(18,10),
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    published_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT product_table_versions_coefficient_check CHECK (((coefficient IS NULL) OR (coefficient >= (0)::numeric))),
    CONSTRAINT product_table_versions_publication_check CHECK (((status = 'draft'::text) OR (published_at IS NOT NULL))),
    CONSTRAINT product_table_versions_rate_check CHECK (((rate IS NULL) OR (rate >= (0)::numeric))),
    CONSTRAINT product_table_versions_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'published'::text, 'superseded'::text, 'expired'::text]))),
    CONSTRAINT product_table_versions_term_check CHECK (((term_min IS NULL) OR (term_max IS NULL) OR (term_min <= term_max))),
    CONSTRAINT product_table_versions_version_check CHECK ((version > 0))
);


--
-- Name: product_tables; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_tables (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    route_id uuid NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT product_tables_status_check CHECK ((status = ANY (ARRAY['active'::text, 'archived'::text])))
);


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    organization_id uuid NOT NULL,
    full_name text NOT NULL,
    role text DEFAULT 'agent'::text,
    created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    CONSTRAINT profiles_role_check CHECK ((role = ANY (ARRAY['admin'::text, 'manager'::text, 'supervisor'::text, 'agent'::text])))
);


--
-- Name: proposal_commercial_component_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.proposal_commercial_component_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    proposal_id uuid NOT NULL,
    component_type text NOT NULL,
    commission_component_id uuid NOT NULL,
    split_rule_version_id uuid,
    gross_percentage numeric,
    fixed_amount numeric,
    anticipation_factor numeric,
    upstream_share numeric DEFAULT 1 NOT NULL,
    downstream_share numeric DEFAULT 0 NOT NULL,
    snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    seller_id uuid,
    seller_sub_rule_version_id uuid,
    seller_sub_share_pct numeric(9,6) DEFAULT 0 NOT NULL,
    seller_company_share_pct numeric(9,6) DEFAULT 100 NOT NULL,
    CONSTRAINT proposal_commercial_component_snapshots_check CHECK (((upstream_share + downstream_share) = (1)::numeric)),
    CONSTRAINT proposal_commercial_component_snapshots_downstream_share_check CHECK (((downstream_share >= (0)::numeric) AND (downstream_share <= (1)::numeric))),
    CONSTRAINT proposal_commercial_component_snapshots_upstream_share_check CHECK (((upstream_share >= (0)::numeric) AND (upstream_share <= (1)::numeric))),
    CONSTRAINT proposal_component_snapshot_seller_share_range_check CHECK ((((seller_sub_share_pct >= (0)::numeric) AND (seller_sub_share_pct <= (100)::numeric)) AND ((seller_company_share_pct >= (0)::numeric) AND (seller_company_share_pct <= (100)::numeric)) AND ((seller_sub_share_pct + seller_company_share_pct) = (100)::numeric))),
    CONSTRAINT proposal_component_snapshot_sub_rule_semantics_check CHECK (((seller_sub_rule_version_id IS NOT NULL) OR ((seller_sub_share_pct = (0)::numeric) AND (seller_company_share_pct = (100)::numeric))))
);


--
-- Name: proposal_commercial_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.proposal_commercial_snapshots (
    proposal_id uuid NOT NULL,
    organization_id uuid NOT NULL,
    channel_id uuid NOT NULL,
    commission_rule_version_id uuid,
    producer_entity_id uuid,
    payer_entity_id uuid,
    split_rule_version_id uuid,
    snapshot jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: proposal_document_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.proposal_document_links (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    requirement_id uuid NOT NULL,
    customer_document_id uuid NOT NULL,
    linked_by uuid,
    linked_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: proposal_document_requirements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.proposal_document_requirements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    proposal_id uuid NOT NULL,
    checklist_item_id uuid,
    document_type_id uuid NOT NULL,
    label_snapshot text NOT NULL,
    required_snapshot boolean NOT NULL,
    status text DEFAULT 'missing'::text NOT NULL,
    exception_reason text,
    exception_approved_by uuid,
    exception_approved_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT proposal_document_requirements_exception_check CHECK (((status <> 'waived'::text) OR ((exception_reason IS NOT NULL) AND (exception_approved_by IS NOT NULL) AND (exception_approved_at IS NOT NULL)))),
    CONSTRAINT proposal_document_requirements_exception_scope_check CHECK (((status = 'waived'::text) OR ((exception_reason IS NULL) AND (exception_approved_by IS NULL) AND (exception_approved_at IS NULL)))),
    CONSTRAINT proposal_document_requirements_status_check CHECK ((status = ANY (ARRAY['missing'::text, 'attached'::text, 'validated'::text, 'rejected'::text, 'waived'::text])))
);


--
-- Name: proposal_external_identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.proposal_external_identities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    proposal_id uuid NOT NULL,
    institution_key text NOT NULL,
    external_proposal_number text NOT NULL,
    channel_id uuid,
    source text,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: proposal_seller_commission_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.proposal_seller_commission_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    proposal_id uuid NOT NULL,
    seller_id uuid NOT NULL,
    commission_group_id uuid NOT NULL,
    calculation_status text NOT NULL,
    source_kind text NOT NULL,
    calculation_base numeric(18,2),
    effective_pct numeric(18,8),
    amount numeric(18,2),
    currency text DEFAULT 'BRL'::text NOT NULL,
    condition_id uuid,
    policy_version_id uuid,
    reason text,
    snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    frozen_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT proposal_seller_commission_snapshots_calculation_status_check CHECK ((calculation_status = ANY (ARRAY['calculated'::text, 'unavailable'::text]))),
    CONSTRAINT proposal_seller_commission_snapshots_check CHECK ((((calculation_status = 'calculated'::text) AND (amount IS NOT NULL) AND (amount >= (0)::numeric) AND (effective_pct IS NOT NULL) AND (calculation_base IS NOT NULL) AND (reason IS NULL)) OR ((calculation_status = 'unavailable'::text) AND (amount IS NULL) AND (reason IS NOT NULL)))),
    CONSTRAINT proposal_seller_commission_snapshots_currency_check CHECK ((currency = 'BRL'::text)),
    CONSTRAINT proposal_seller_commission_snapshots_source_kind_check CHECK ((source_kind = ANY (ARRAY['condition_group_share'::text, 'unavailable'::text])))
);


--
-- Name: proposal_status_evidence; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.proposal_status_evidence (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    proposal_id uuid NOT NULL,
    import_decision_id uuid NOT NULL,
    canonical_status text NOT NULL,
    raw_status text NOT NULL,
    evidenced_at timestamp with time zone NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT proposal_status_evidence_canonical_status_check CHECK ((canonical_status = 'paid'::text))
);


--
-- Name: proposals_v2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.proposals_v2 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    simulation_id uuid,
    product_table_version_id uuid NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    external_proposal_id text,
    requested_amount numeric(14,2),
    released_amount numeric(14,2),
    installment_amount numeric(14,2),
    term integer,
    rate numeric(12,8),
    coefficient numeric(18,10),
    expected_commission_amount numeric(14,2),
    customer_snapshot jsonb NOT NULL,
    commercial_snapshot jsonb NOT NULL,
    attribution_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    seller_id uuid,
    CONSTRAINT proposals_v2_amounts_check CHECK ((((requested_amount IS NULL) OR (requested_amount >= (0)::numeric)) AND ((released_amount IS NULL) OR (released_amount >= (0)::numeric)) AND ((installment_amount IS NULL) OR (installment_amount >= (0)::numeric)) AND ((expected_commission_amount IS NULL) OR (expected_commission_amount >= (0)::numeric)))),
    CONSTRAINT proposals_v2_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'documents_pending'::text, 'ready_for_digitization'::text, 'digitization'::text, 'submitted'::text, 'approved'::text, 'paid'::text, 'rejected'::text, 'cancelled'::text]))),
    CONSTRAINT proposals_v2_term_check CHECK (((term IS NULL) OR (term > 0)))
);


--
-- Name: providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.providers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    provider_type text DEFAULT 'master'::text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT providers_type_check CHECK ((provider_type = ANY (ARRAY['bank_direct'::text, 'master'::text, 'promotora'::text, 'other'::text])))
);


--
-- Name: seller_addresses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seller_addresses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    seller_id uuid NOT NULL,
    label text DEFAULT 'principal'::text NOT NULL,
    postal_code text,
    street text,
    number text,
    complement text,
    neighborhood text,
    city text,
    state text,
    country_code text DEFAULT 'BR'::text NOT NULL,
    valid_from timestamp with time zone DEFAULT now() NOT NULL,
    valid_until timestamp with time zone,
    is_current boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT seller_addresses_check CHECK (((valid_until IS NULL) OR (valid_until > valid_from)))
);


--
-- Name: seller_bank_aliases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seller_bank_aliases (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    seller_id uuid NOT NULL,
    source_key text NOT NULL,
    external_user text NOT NULL,
    external_user_normalized text NOT NULL,
    bank_id uuid,
    provider_id uuid,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: seller_certifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seller_certifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    seller_id uuid NOT NULL,
    name text NOT NULL,
    issuer text,
    certificate_number text,
    issued_at date,
    expires_at date,
    status text DEFAULT 'active'::text NOT NULL,
    notes text,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT seller_certifications_check CHECK (((expires_at IS NULL) OR (issued_at IS NULL) OR (expires_at >= issued_at))),
    CONSTRAINT seller_certifications_status_check CHECK ((status = ANY (ARRAY['active'::text, 'expired'::text, 'revoked'::text, 'pending'::text])))
);


--
-- Name: seller_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seller_groups (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    tech_key text DEFAULT replace((gen_random_uuid())::text, '-'::text, ''::text) NOT NULL,
    name text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT seller_groups_name_check CHECK (((length(btrim(name)) >= 1) AND (length(btrim(name)) <= 80)))
);


--
-- Name: seller_payment_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seller_payment_accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    seller_id uuid NOT NULL,
    bank_id uuid,
    bank_code_snapshot text,
    bank_name_snapshot text NOT NULL,
    branch text,
    account_number text,
    account_digit text,
    account_type text,
    holder_name text NOT NULL,
    holder_document text NOT NULL,
    pix_key_type text,
    pix_key text,
    verification_status text DEFAULT 'unverified'::text NOT NULL,
    payment_enabled boolean DEFAULT true NOT NULL,
    valid_from timestamp with time zone DEFAULT now() NOT NULL,
    valid_until timestamp with time zone,
    is_current boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT seller_payment_accounts_account_type_check CHECK (((account_type IS NULL) OR (account_type = ANY (ARRAY['checking'::text, 'savings'::text, 'payment'::text, 'other'::text])))),
    CONSTRAINT seller_payment_accounts_check CHECK (((valid_until IS NULL) OR (valid_until > valid_from))),
    CONSTRAINT seller_payment_accounts_check1 CHECK (((account_number IS NOT NULL) OR (pix_key IS NOT NULL))),
    CONSTRAINT seller_payment_accounts_pix_key_type_check CHECK (((pix_key_type IS NULL) OR (pix_key_type = ANY (ARRAY['cpf'::text, 'cnpj'::text, 'email'::text, 'phone'::text, 'random'::text])))),
    CONSTRAINT seller_payment_accounts_verification_status_check CHECK ((verification_status = ANY (ARRAY['unverified'::text, 'verified'::text, 'rejected'::text])))
);


--
-- Name: seller_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seller_profiles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    seller_id uuid NOT NULL,
    legal_name text,
    trade_name text,
    email text,
    phone text,
    whatsapp text,
    birth_or_opening_date date,
    identity_or_registration_number text,
    identity_issuer text,
    occupation text,
    notes text,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: seller_sub_rule_versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seller_sub_rule_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    seller_id uuid NOT NULL,
    version integer NOT NULL,
    component_key text DEFAULT 'all'::text NOT NULL,
    sub_share_pct numeric(9,6) NOT NULL,
    company_share_pct numeric(9,6) GENERATED ALWAYS AS (((100)::numeric - sub_share_pct)) STORED,
    effective_from timestamp with time zone NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    published_at timestamp with time zone,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT seller_sub_rule_versions_component_key_check CHECK (((length(btrim(component_key)) >= 1) AND (length(btrim(component_key)) <= 80))),
    CONSTRAINT seller_sub_rule_versions_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'published'::text]))),
    CONSTRAINT seller_sub_rule_versions_sub_share_pct_check CHECK (((sub_share_pct >= (0)::numeric) AND (sub_share_pct <= (100)::numeric))),
    CONSTRAINT seller_sub_rule_versions_version_check CHECK ((version > 0))
);


--
-- Name: seller_supervisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.seller_supervisions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    supervisor_user_id uuid NOT NULL,
    seller_id uuid NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_by uuid,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: simulations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.simulations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    product_table_version_id uuid NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    requested_amount numeric(14,2),
    released_amount numeric(14,2),
    installment_amount numeric(14,2),
    term integer,
    rate numeric(12,8),
    coefficient numeric(18,10),
    expected_commission_amount numeric(14,2),
    input_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    result_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT simulations_amounts_check CHECK ((((requested_amount IS NULL) OR (requested_amount >= (0)::numeric)) AND ((released_amount IS NULL) OR (released_amount >= (0)::numeric)) AND ((installment_amount IS NULL) OR (installment_amount >= (0)::numeric)) AND ((expected_commission_amount IS NULL) OR (expected_commission_amount >= (0)::numeric)))),
    CONSTRAINT simulations_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'calculated'::text, 'selected'::text, 'expired'::text, 'cancelled'::text]))),
    CONSTRAINT simulations_term_check CHECK (((term IS NULL) OR (term > 0)))
);


--
-- Name: agreements agreements_bank_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agreements
    ADD CONSTRAINT agreements_bank_code_key UNIQUE (bank_id, code);


--
-- Name: agreements agreements_bank_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agreements
    ADD CONSTRAINT agreements_bank_id_id_key UNIQUE (bank_id, id);


--
-- Name: agreements agreements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agreements
    ADD CONSTRAINT agreements_pkey PRIMARY KEY (id);


--
-- Name: ai_credit_ledger ai_credit_ledger_organization_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_credit_ledger
    ADD CONSTRAINT ai_credit_ledger_organization_id_idempotency_key_key UNIQUE (organization_id, idempotency_key);


--
-- Name: ai_credit_ledger ai_credit_ledger_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_credit_ledger
    ADD CONSTRAINT ai_credit_ledger_pkey PRIMARY KEY (id);


--
-- Name: ai_usage_events ai_usage_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_usage_events
    ADD CONSTRAINT ai_usage_events_pkey PRIMARY KEY (id);


--
-- Name: ai_usage_jobs ai_usage_jobs_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_usage_jobs
    ADD CONSTRAINT ai_usage_jobs_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: ai_usage_jobs ai_usage_jobs_organization_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_usage_jobs
    ADD CONSTRAINT ai_usage_jobs_organization_id_idempotency_key_key UNIQUE (organization_id, idempotency_key);


--
-- Name: ai_usage_jobs ai_usage_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_usage_jobs
    ADD CONSTRAINT ai_usage_jobs_pkey PRIMARY KEY (id);


--
-- Name: banks banks_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.banks
    ADD CONSTRAINT banks_code_key UNIQUE (code);


--
-- Name: banks banks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.banks
    ADD CONSTRAINT banks_pkey PRIMARY KEY (id);


--
-- Name: channel_commission_rule_versions channel_commission_rule_versi_organization_id_channel_id_pr_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_commission_rule_versions
    ADD CONSTRAINT channel_commission_rule_versi_organization_id_channel_id_pr_key UNIQUE (organization_id, channel_id, product_table_id, version);


--
-- Name: channel_commission_rule_versions channel_commission_rule_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_commission_rule_versions
    ADD CONSTRAINT channel_commission_rule_versions_pkey PRIMARY KEY (id);


--
-- Name: clients clients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_pkey PRIMARY KEY (id);


--
-- Name: commercial_channels commercial_channels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_channels
    ADD CONSTRAINT commercial_channels_pkey PRIMARY KEY (id);


--
-- Name: commercial_condition_commissions commercial_condition_commissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_commissions
    ADD CONSTRAINT commercial_condition_commissions_pkey PRIMARY KEY (condition_id);


--
-- Name: commercial_condition_components commercial_condition_componen_condition_id_component_type_i_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_components
    ADD CONSTRAINT commercial_condition_componen_condition_id_component_type_i_key UNIQUE (condition_id, component_type_id);


--
-- Name: commercial_condition_component_policy commercial_condition_component_policy_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_component_policy
    ADD CONSTRAINT commercial_condition_component_policy_pkey PRIMARY KEY (condition_id);


--
-- Name: commercial_condition_components commercial_condition_components_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_components
    ADD CONSTRAINT commercial_condition_components_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: commercial_condition_components commercial_condition_components_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_components
    ADD CONSTRAINT commercial_condition_components_pkey PRIMARY KEY (id);


--
-- Name: commercial_condition_shares commercial_condition_shares_condition_id_group_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_shares
    ADD CONSTRAINT commercial_condition_shares_condition_id_group_id_key UNIQUE (condition_id, group_id);


--
-- Name: commercial_condition_shares commercial_condition_shares_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_shares
    ADD CONSTRAINT commercial_condition_shares_pkey PRIMARY KEY (id);


--
-- Name: commercial_conditions commercial_conditions_no_overlapping_term_amount_ranges; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_conditions
    ADD CONSTRAINT commercial_conditions_no_overlapping_term_amount_ranges EXCLUDE USING gist (product_table_version_id WITH =, contract_type_id WITH =, int4range(term_min, term_max, '[]'::text) WITH &&, numrange(amount_min, amount_max, '[]'::text) WITH &&);


--
-- Name: commercial_conditions commercial_conditions_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_conditions
    ADD CONSTRAINT commercial_conditions_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: commercial_conditions commercial_conditions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_conditions
    ADD CONSTRAINT commercial_conditions_pkey PRIMARY KEY (id);


--
-- Name: commercial_entities commercial_entities_organization_id_tax_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_entities
    ADD CONSTRAINT commercial_entities_organization_id_tax_id_key UNIQUE (organization_id, tax_id);


--
-- Name: commercial_entities commercial_entities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_entities
    ADD CONSTRAINT commercial_entities_pkey PRIMARY KEY (id);


--
-- Name: commercial_factor_batches commercial_factor_batches_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_batches
    ADD CONSTRAINT commercial_factor_batches_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: commercial_factor_batches commercial_factor_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_batches
    ADD CONSTRAINT commercial_factor_batches_pkey PRIMARY KEY (id);


--
-- Name: commercial_factor_batches commercial_factor_batches_profile_id_effective_date_revisio_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_batches
    ADD CONSTRAINT commercial_factor_batches_profile_id_effective_date_revisio_key UNIQUE (profile_id, effective_date, revision);


--
-- Name: commercial_factor_entries commercial_factor_entries_batch_id_term_min_term_max_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_entries
    ADD CONSTRAINT commercial_factor_entries_batch_id_term_min_term_max_key UNIQUE (batch_id, term_min, term_max);


--
-- Name: commercial_factor_entries commercial_factor_entries_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_entries
    ADD CONSTRAINT commercial_factor_entries_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: commercial_factor_entries commercial_factor_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_entries
    ADD CONSTRAINT commercial_factor_entries_pkey PRIMARY KEY (id);


--
-- Name: commercial_factor_profiles commercial_factor_profiles_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_profiles
    ADD CONSTRAINT commercial_factor_profiles_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: commercial_factor_profiles commercial_factor_profiles_organization_id_tech_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_profiles
    ADD CONSTRAINT commercial_factor_profiles_organization_id_tech_key_key UNIQUE (organization_id, tech_key);


--
-- Name: commercial_factor_profiles commercial_factor_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_profiles
    ADD CONSTRAINT commercial_factor_profiles_pkey PRIMARY KEY (id);


--
-- Name: commercial_relationships commercial_relationships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_relationships
    ADD CONSTRAINT commercial_relationships_pkey PRIMARY KEY (id);


--
-- Name: commercial_sellers commercial_sellers_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_sellers
    ADD CONSTRAINT commercial_sellers_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: commercial_sellers commercial_sellers_organization_id_tech_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_sellers
    ADD CONSTRAINT commercial_sellers_organization_id_tech_key_key UNIQUE (organization_id, tech_key);


--
-- Name: commercial_sellers commercial_sellers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_sellers
    ADD CONSTRAINT commercial_sellers_pkey PRIMARY KEY (id);


--
-- Name: commission_component_types commission_component_types_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_component_types
    ADD CONSTRAINT commission_component_types_name_key UNIQUE (name);


--
-- Name: commission_component_types commission_component_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_component_types
    ADD CONSTRAINT commission_component_types_pkey PRIMARY KEY (id);


--
-- Name: commission_component_types commission_component_types_tech_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_component_types
    ADD CONSTRAINT commission_component_types_tech_key_key UNIQUE (tech_key);


--
-- Name: commission_group_component_limits commission_group_component_li_organization_id_group_id_comp_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_group_component_limits
    ADD CONSTRAINT commission_group_component_li_organization_id_group_id_comp_key UNIQUE (organization_id, group_id, component_type_id);


--
-- Name: commission_group_component_limits commission_group_component_limits_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_group_component_limits
    ADD CONSTRAINT commission_group_component_limits_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: commission_group_component_limits commission_group_component_limits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_group_component_limits
    ADD CONSTRAINT commission_group_component_limits_pkey PRIMARY KEY (id);


--
-- Name: commission_groups commission_groups_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_groups
    ADD CONSTRAINT commission_groups_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: commission_groups commission_groups_organization_id_tech_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_groups
    ADD CONSTRAINT commission_groups_organization_id_tech_key_key UNIQUE (organization_id, tech_key);


--
-- Name: commission_groups commission_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_groups
    ADD CONSTRAINT commission_groups_pkey PRIMARY KEY (id);


--
-- Name: commission_rule_components commission_rule_components_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_rule_components
    ADD CONSTRAINT commission_rule_components_pkey PRIMARY KEY (id);


--
-- Name: component_payout_policies component_payout_policies_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policies
    ADD CONSTRAINT component_payout_policies_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: component_payout_policies component_payout_policies_organization_id_tech_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policies
    ADD CONSTRAINT component_payout_policies_organization_id_tech_key_key UNIQUE (organization_id, tech_key);


--
-- Name: component_payout_policies component_payout_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policies
    ADD CONSTRAINT component_payout_policies_pkey PRIMARY KEY (id);


--
-- Name: component_payout_policy_items component_payout_policy_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policy_items
    ADD CONSTRAINT component_payout_policy_items_pkey PRIMARY KEY (id);


--
-- Name: component_payout_policy_items component_payout_policy_items_version_id_group_id_component_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policy_items
    ADD CONSTRAINT component_payout_policy_items_version_id_group_id_component_key UNIQUE (version_id, group_id, component_type_id);


--
-- Name: component_payout_policy_versions component_payout_policy_versions_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policy_versions
    ADD CONSTRAINT component_payout_policy_versions_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: component_payout_policy_versions component_payout_policy_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policy_versions
    ADD CONSTRAINT component_payout_policy_versions_pkey PRIMARY KEY (id);


--
-- Name: component_payout_policy_versions component_payout_policy_versions_policy_id_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policy_versions
    ADD CONSTRAINT component_payout_policy_versions_policy_id_version_key UNIQUE (policy_id, version);


--
-- Name: contract_types contract_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_types
    ADD CONSTRAINT contract_types_pkey PRIMARY KEY (id);


--
-- Name: contract_types contract_types_tech_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_types
    ADD CONSTRAINT contract_types_tech_key_key UNIQUE (tech_key);


--
-- Name: contracts contracts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contracts
    ADD CONSTRAINT contracts_pkey PRIMARY KEY (id);


--
-- Name: customer_addresses customer_addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_addresses
    ADD CONSTRAINT customer_addresses_pkey PRIMARY KEY (id);


--
-- Name: customer_bank_accounts customer_bank_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_bank_accounts
    ADD CONSTRAINT customer_bank_accounts_pkey PRIMARY KEY (id);


--
-- Name: customer_documents customer_documents_customer_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_documents
    ADD CONSTRAINT customer_documents_customer_hash_key UNIQUE (organization_id, customer_id, sha256);


--
-- Name: customer_documents customer_documents_path_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_documents
    ADD CONSTRAINT customer_documents_path_key UNIQUE (organization_id, storage_bucket, storage_path);


--
-- Name: customer_documents customer_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_documents
    ADD CONSTRAINT customer_documents_pkey PRIMARY KEY (id);


--
-- Name: customer_pix_keys customer_pix_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_pix_keys
    ADD CONSTRAINT customer_pix_keys_pkey PRIMARY KEY (id);


--
-- Name: customer_timeline_events customer_timeline_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_timeline_events
    ADD CONSTRAINT customer_timeline_events_pkey PRIMARY KEY (id);


--
-- Name: digitization_jobs digitization_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.digitization_jobs
    ADD CONSTRAINT digitization_jobs_pkey PRIMARY KEY (id);


--
-- Name: document_checklist_items document_checklist_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_checklist_items
    ADD CONSTRAINT document_checklist_items_pkey PRIMARY KEY (id);


--
-- Name: document_checklist_items document_checklist_items_type_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_checklist_items
    ADD CONSTRAINT document_checklist_items_type_key UNIQUE (template_id, document_type_id);


--
-- Name: document_checklist_templates document_checklist_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_checklist_templates
    ADD CONSTRAINT document_checklist_templates_pkey PRIMARY KEY (id);


--
-- Name: document_checklist_templates document_checklist_templates_route_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_checklist_templates
    ADD CONSTRAINT document_checklist_templates_route_version_key UNIQUE (route_id, version);


--
-- Name: document_types document_types_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_types
    ADD CONSTRAINT document_types_code_key UNIQUE (code);


--
-- Name: document_types document_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_types
    ADD CONSTRAINT document_types_pkey PRIMARY KEY (id);


--
-- Name: financial_events financial_events_organization_id_idempotency_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_events
    ADD CONSTRAINT financial_events_organization_id_idempotency_key_key UNIQUE (organization_id, idempotency_key);


--
-- Name: financial_events financial_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_events
    ADD CONSTRAINT financial_events_pkey PRIMARY KEY (id);


--
-- Name: financial_evidence_links financial_evidence_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_evidence_links
    ADD CONSTRAINT financial_evidence_links_pkey PRIMARY KEY (id);


--
-- Name: financial_reconciliation_cases financial_reconciliation_cases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_reconciliation_cases
    ADD CONSTRAINT financial_reconciliation_cases_pkey PRIMARY KEY (id);


--
-- Name: import_applied_decisions import_applied_decisions_organization_id_decision_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_applied_decisions
    ADD CONSTRAINT import_applied_decisions_organization_id_decision_id_key UNIQUE (organization_id, decision_id);


--
-- Name: import_applied_decisions import_applied_decisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_applied_decisions
    ADD CONSTRAINT import_applied_decisions_pkey PRIMARY KEY (id);


--
-- Name: import_batches import_batches_organization_id_content_sha256_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_batches
    ADD CONSTRAINT import_batches_organization_id_content_sha256_key UNIQUE (organization_id, content_sha256);


--
-- Name: import_batches import_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_batches
    ADD CONSTRAINT import_batches_pkey PRIMARY KEY (id);


--
-- Name: import_conflict_rows import_conflict_rows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_conflict_rows
    ADD CONSTRAINT import_conflict_rows_pkey PRIMARY KEY (conflict_id, raw_row_id);


--
-- Name: import_conflicts import_conflicts_organization_id_fingerprint_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_conflicts
    ADD CONSTRAINT import_conflicts_organization_id_fingerprint_key UNIQUE (organization_id, fingerprint);


--
-- Name: import_conflicts import_conflicts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_conflicts
    ADD CONSTRAINT import_conflicts_pkey PRIMARY KEY (id);


--
-- Name: import_decisions import_decisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_decisions
    ADD CONSTRAINT import_decisions_pkey PRIMARY KEY (id);


--
-- Name: import_jobs import_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_jobs
    ADD CONSTRAINT import_jobs_pkey PRIMARY KEY (id);


--
-- Name: import_layout_mappings import_layout_mappings_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_layout_mappings
    ADD CONSTRAINT import_layout_mappings_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: import_layout_mappings import_layout_mappings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_layout_mappings
    ADD CONSTRAINT import_layout_mappings_pkey PRIMARY KEY (id);


--
-- Name: import_match_candidates import_match_candidates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_match_candidates
    ADD CONSTRAINT import_match_candidates_pkey PRIMARY KEY (id);


--
-- Name: import_normalized_rows import_normalized_rows_organization_id_raw_row_id_normaliza_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_normalized_rows
    ADD CONSTRAINT import_normalized_rows_organization_id_raw_row_id_normaliza_key UNIQUE (organization_id, raw_row_id, normalization_version);


--
-- Name: import_normalized_rows import_normalized_rows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_normalized_rows
    ADD CONSTRAINT import_normalized_rows_pkey PRIMARY KEY (id);


--
-- Name: import_raw_rows import_raw_rows_organization_id_batch_id_row_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_raw_rows
    ADD CONSTRAINT import_raw_rows_organization_id_batch_id_row_number_key UNIQUE (organization_id, batch_id, row_number);


--
-- Name: import_raw_rows import_raw_rows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_raw_rows
    ADD CONSTRAINT import_raw_rows_pkey PRIMARY KEY (id);


--
-- Name: import_sources import_sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_sources
    ADD CONSTRAINT import_sources_pkey PRIMARY KEY (id);


--
-- Name: integration_adapters integration_adapters_adapter_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_adapters
    ADD CONSTRAINT integration_adapters_adapter_key_key UNIQUE (adapter_key);


--
-- Name: integration_adapters integration_adapters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_adapters
    ADD CONSTRAINT integration_adapters_pkey PRIMARY KEY (id);


--
-- Name: integration_field_mappings integration_field_mappings_adapter_id_contract_version_sour_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_field_mappings
    ADD CONSTRAINT integration_field_mappings_adapter_id_contract_version_sour_key UNIQUE (adapter_id, contract_version, source_field, canonical_field);


--
-- Name: integration_field_mappings integration_field_mappings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_field_mappings
    ADD CONSTRAINT integration_field_mappings_pkey PRIMARY KEY (id);


--
-- Name: integration_run_artifacts integration_run_artifacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_run_artifacts
    ADD CONSTRAINT integration_run_artifacts_pkey PRIMARY KEY (id);


--
-- Name: integration_runs integration_runs_organization_id_binding_id_request_fingerp_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_runs
    ADD CONSTRAINT integration_runs_organization_id_binding_id_request_fingerp_key UNIQUE (organization_id, binding_id, request_fingerprint);


--
-- Name: integration_runs integration_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_runs
    ADD CONSTRAINT integration_runs_pkey PRIMARY KEY (id);


--
-- Name: integration_source_bindings integration_source_bindings_organization_id_source_id_adapt_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_source_bindings
    ADD CONSTRAINT integration_source_bindings_organization_id_source_id_adapt_key UNIQUE (organization_id, source_id, adapter_id);


--
-- Name: integration_source_bindings integration_source_bindings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_source_bindings
    ADD CONSTRAINT integration_source_bindings_pkey PRIMARY KEY (id);


--
-- Name: lead_events lead_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_events
    ADD CONSTRAINT lead_events_pkey PRIMARY KEY (id);


--
-- Name: leads leads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_pkey PRIMARY KEY (id);


--
-- Name: modalities modalities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modalities
    ADD CONSTRAINT modalities_pkey PRIMARY KEY (id);


--
-- Name: modalities modalities_product_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modalities
    ADD CONSTRAINT modalities_product_code_key UNIQUE (product_id, code);


--
-- Name: modalities modalities_product_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modalities
    ADD CONSTRAINT modalities_product_id_id_key UNIQUE (product_id, id);


--
-- Name: national_agreement_templates national_agreement_templates_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.national_agreement_templates
    ADD CONSTRAINT national_agreement_templates_name_key UNIQUE (name);


--
-- Name: national_agreement_templates national_agreement_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.national_agreement_templates
    ADD CONSTRAINT national_agreement_templates_pkey PRIMARY KEY (id);


--
-- Name: national_agreement_templates national_agreement_templates_tech_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.national_agreement_templates
    ADD CONSTRAINT national_agreement_templates_tech_key_key UNIQUE (tech_key);


--
-- Name: network_split_rule_versions network_split_rule_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.network_split_rule_versions
    ADD CONSTRAINT network_split_rule_versions_pkey PRIMARY KEY (id);


--
-- Name: operational_attention_events operational_attention_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_attention_events
    ADD CONSTRAINT operational_attention_events_pkey PRIMARY KEY (id);


--
-- Name: operational_attention_items operational_attention_items_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_attention_items
    ADD CONSTRAINT operational_attention_items_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: operational_attention_items operational_attention_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_attention_items
    ADD CONSTRAINT operational_attention_items_pkey PRIMARY KEY (id);


--
-- Name: operational_cases operational_cases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_cases
    ADD CONSTRAINT operational_cases_pkey PRIMARY KEY (id);


--
-- Name: operational_cases operational_cases_proposal_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_cases
    ADD CONSTRAINT operational_cases_proposal_key UNIQUE (organization_id, proposal_id);


--
-- Name: operational_events operational_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_events
    ADD CONSTRAINT operational_events_pkey PRIMARY KEY (id);


--
-- Name: operational_stages operational_stages_org_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_stages
    ADD CONSTRAINT operational_stages_org_code_key UNIQUE (organization_id, code);


--
-- Name: operational_stages operational_stages_org_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_stages
    ADD CONSTRAINT operational_stages_org_id_key UNIQUE (organization_id, id);


--
-- Name: operational_stages operational_stages_org_id_state_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_stages
    ADD CONSTRAINT operational_stages_org_id_state_key UNIQUE (organization_id, id, canonical_state);


--
-- Name: operational_stages operational_stages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_stages
    ADD CONSTRAINT operational_stages_pkey PRIMARY KEY (id);


--
-- Name: organization_admin_events organization_admin_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_admin_events
    ADD CONSTRAINT organization_admin_events_pkey PRIMARY KEY (id);


--
-- Name: organization_agreements organization_agreements_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_agreements
    ADD CONSTRAINT organization_agreements_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: organization_agreements organization_agreements_organization_id_tech_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_agreements
    ADD CONSTRAINT organization_agreements_organization_id_tech_key_key UNIQUE (organization_id, tech_key);


--
-- Name: organization_agreements organization_agreements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_agreements
    ADD CONSTRAINT organization_agreements_pkey PRIMARY KEY (id);


--
-- Name: organization_ai_limits organization_ai_limits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_ai_limits
    ADD CONSTRAINT organization_ai_limits_pkey PRIMARY KEY (organization_id);


--
-- Name: organization_banks organization_banks_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_banks
    ADD CONSTRAINT organization_banks_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: organization_banks organization_banks_organization_id_tech_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_banks
    ADD CONSTRAINT organization_banks_organization_id_tech_key_key UNIQUE (organization_id, tech_key);


--
-- Name: organization_banks organization_banks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_banks
    ADD CONSTRAINT organization_banks_pkey PRIMARY KEY (id);


--
-- Name: organization_branches organization_branches_organization_id_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_branches
    ADD CONSTRAINT organization_branches_organization_id_code_key UNIQUE (organization_id, code);


--
-- Name: organization_branches organization_branches_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_branches
    ADD CONSTRAINT organization_branches_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: organization_branches organization_branches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_branches
    ADD CONSTRAINT organization_branches_pkey PRIMARY KEY (id);


--
-- Name: organization_contract_type_settings organization_contract_type_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_contract_type_settings
    ADD CONSTRAINT organization_contract_type_settings_pkey PRIMARY KEY (organization_id, contract_type_id);


--
-- Name: organization_invitations organization_invitations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_invitations
    ADD CONSTRAINT organization_invitations_pkey PRIMARY KEY (id);


--
-- Name: organization_memberships organization_memberships_org_user_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT organization_memberships_org_user_key UNIQUE (organization_id, user_id);


--
-- Name: organization_memberships organization_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT organization_memberships_pkey PRIMARY KEY (id);


--
-- Name: organization_product_routes organization_product_routes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_product_routes
    ADD CONSTRAINT organization_product_routes_pkey PRIMARY KEY (id);


--
-- Name: organization_product_routes organization_product_routes_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_product_routes
    ADD CONSTRAINT organization_product_routes_unique UNIQUE (organization_id, bank_id, provider_id, agreement_id, product_id, modality_id);


--
-- Name: organization_providers organization_providers_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_providers
    ADD CONSTRAINT organization_providers_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: organization_providers organization_providers_organization_id_tech_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_providers
    ADD CONSTRAINT organization_providers_organization_id_tech_key_key UNIQUE (organization_id, tech_key);


--
-- Name: organization_providers organization_providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_providers
    ADD CONSTRAINT organization_providers_pkey PRIMARY KEY (id);


--
-- Name: organizations organizations_document_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_document_key UNIQUE (document);


--
-- Name: organizations organizations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organizations
    ADD CONSTRAINT organizations_pkey PRIMARY KEY (id);


--
-- Name: payout_policies payout_policies_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_policies
    ADD CONSTRAINT payout_policies_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: payout_policies payout_policies_organization_id_tech_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_policies
    ADD CONSTRAINT payout_policies_organization_id_tech_key_key UNIQUE (organization_id, tech_key);


--
-- Name: payout_policies payout_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_policies
    ADD CONSTRAINT payout_policies_pkey PRIMARY KEY (id);


--
-- Name: payout_policy_items payout_policy_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_policy_items
    ADD CONSTRAINT payout_policy_items_pkey PRIMARY KEY (id);


--
-- Name: payout_policy_items payout_policy_items_version_id_group_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_policy_items
    ADD CONSTRAINT payout_policy_items_version_id_group_id_key UNIQUE (version_id, group_id);


--
-- Name: payout_policy_versions payout_policy_versions_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_policy_versions
    ADD CONSTRAINT payout_policy_versions_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: payout_policy_versions payout_policy_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_policy_versions
    ADD CONSTRAINT payout_policy_versions_pkey PRIMARY KEY (id);


--
-- Name: payout_policy_versions payout_policy_versions_policy_id_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_policy_versions
    ADD CONSTRAINT payout_policy_versions_policy_id_version_key UNIQUE (policy_id, version);


--
-- Name: platform_admin_audit_events platform_admin_audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_admin_audit_events
    ADD CONSTRAINT platform_admin_audit_events_pkey PRIMARY KEY (id);


--
-- Name: platform_administrators platform_administrators_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_administrators
    ADD CONSTRAINT platform_administrators_pkey PRIMARY KEY (user_id);


--
-- Name: product_table_external_identities product_table_external_identi_organization_id_channel_id_ex_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_table_external_identities
    ADD CONSTRAINT product_table_external_identi_organization_id_channel_id_ex_key UNIQUE (organization_id, channel_id, external_code);


--
-- Name: product_table_external_identities product_table_external_identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_table_external_identities
    ADD CONSTRAINT product_table_external_identities_pkey PRIMARY KEY (id);


--
-- Name: product_table_versions product_table_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_table_versions
    ADD CONSTRAINT product_table_versions_pkey PRIMARY KEY (id);


--
-- Name: product_table_versions product_table_versions_table_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_table_versions
    ADD CONSTRAINT product_table_versions_table_version_key UNIQUE (product_table_id, version);


--
-- Name: product_tables product_tables_org_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_tables
    ADD CONSTRAINT product_tables_org_code_key UNIQUE (organization_id, code);


--
-- Name: product_tables product_tables_org_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_tables
    ADD CONSTRAINT product_tables_org_id_key UNIQUE (organization_id, id);


--
-- Name: product_tables product_tables_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_tables
    ADD CONSTRAINT product_tables_pkey PRIMARY KEY (id);


--
-- Name: products products_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_code_key UNIQUE (code);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: proposal_commercial_component_snapshots proposal_commercial_component_organization_id_proposal_id_c_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_commercial_component_snapshots
    ADD CONSTRAINT proposal_commercial_component_organization_id_proposal_id_c_key UNIQUE (organization_id, proposal_id, commission_component_id);


--
-- Name: proposal_commercial_component_snapshots proposal_commercial_component_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_commercial_component_snapshots
    ADD CONSTRAINT proposal_commercial_component_snapshots_pkey PRIMARY KEY (id);


--
-- Name: proposal_commercial_snapshots proposal_commercial_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_commercial_snapshots
    ADD CONSTRAINT proposal_commercial_snapshots_pkey PRIMARY KEY (proposal_id);


--
-- Name: proposal_document_links proposal_document_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_document_links
    ADD CONSTRAINT proposal_document_links_pkey PRIMARY KEY (id);


--
-- Name: proposal_document_links proposal_document_links_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_document_links
    ADD CONSTRAINT proposal_document_links_unique UNIQUE (requirement_id, customer_document_id);


--
-- Name: proposal_document_requirements proposal_document_requirements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_document_requirements
    ADD CONSTRAINT proposal_document_requirements_pkey PRIMARY KEY (id);


--
-- Name: proposal_external_identities proposal_external_identities_organization_id_institution_ke_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_external_identities
    ADD CONSTRAINT proposal_external_identities_organization_id_institution_ke_key UNIQUE (organization_id, institution_key, external_proposal_number);


--
-- Name: proposal_external_identities proposal_external_identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_external_identities
    ADD CONSTRAINT proposal_external_identities_pkey PRIMARY KEY (id);


--
-- Name: proposal_seller_commission_snapshots proposal_seller_commission_snapshots_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_seller_commission_snapshots
    ADD CONSTRAINT proposal_seller_commission_snapshots_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: proposal_seller_commission_snapshots proposal_seller_commission_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_seller_commission_snapshots
    ADD CONSTRAINT proposal_seller_commission_snapshots_pkey PRIMARY KEY (id);


--
-- Name: proposal_seller_commission_snapshots proposal_seller_commission_snapshots_proposal_id_seller_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_seller_commission_snapshots
    ADD CONSTRAINT proposal_seller_commission_snapshots_proposal_id_seller_id_key UNIQUE (proposal_id, seller_id);


--
-- Name: proposal_status_evidence proposal_status_evidence_organization_id_import_decision_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_status_evidence
    ADD CONSTRAINT proposal_status_evidence_organization_id_import_decision_id_key UNIQUE (organization_id, import_decision_id, canonical_status);


--
-- Name: proposal_status_evidence proposal_status_evidence_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_status_evidence
    ADD CONSTRAINT proposal_status_evidence_pkey PRIMARY KEY (id);


--
-- Name: proposals_v2 proposals_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposals_v2
    ADD CONSTRAINT proposals_v2_pkey PRIMARY KEY (id);


--
-- Name: providers providers_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.providers
    ADD CONSTRAINT providers_code_key UNIQUE (code);


--
-- Name: providers providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.providers
    ADD CONSTRAINT providers_pkey PRIMARY KEY (id);


--
-- Name: seller_addresses seller_addresses_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_addresses
    ADD CONSTRAINT seller_addresses_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: seller_addresses seller_addresses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_addresses
    ADD CONSTRAINT seller_addresses_pkey PRIMARY KEY (id);


--
-- Name: seller_bank_aliases seller_bank_aliases_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_bank_aliases
    ADD CONSTRAINT seller_bank_aliases_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: seller_bank_aliases seller_bank_aliases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_bank_aliases
    ADD CONSTRAINT seller_bank_aliases_pkey PRIMARY KEY (id);


--
-- Name: seller_certifications seller_certifications_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_certifications
    ADD CONSTRAINT seller_certifications_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: seller_certifications seller_certifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_certifications
    ADD CONSTRAINT seller_certifications_pkey PRIMARY KEY (id);


--
-- Name: seller_groups seller_groups_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_groups
    ADD CONSTRAINT seller_groups_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: seller_groups seller_groups_organization_id_tech_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_groups
    ADD CONSTRAINT seller_groups_organization_id_tech_key_key UNIQUE (organization_id, tech_key);


--
-- Name: seller_groups seller_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_groups
    ADD CONSTRAINT seller_groups_pkey PRIMARY KEY (id);


--
-- Name: seller_payment_accounts seller_payment_accounts_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_payment_accounts
    ADD CONSTRAINT seller_payment_accounts_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: seller_payment_accounts seller_payment_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_payment_accounts
    ADD CONSTRAINT seller_payment_accounts_pkey PRIMARY KEY (id);


--
-- Name: seller_profiles seller_profiles_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_profiles
    ADD CONSTRAINT seller_profiles_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: seller_profiles seller_profiles_organization_id_seller_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_profiles
    ADD CONSTRAINT seller_profiles_organization_id_seller_id_key UNIQUE (organization_id, seller_id);


--
-- Name: seller_profiles seller_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_profiles
    ADD CONSTRAINT seller_profiles_pkey PRIMARY KEY (id);


--
-- Name: seller_sub_rule_versions seller_sub_rule_versions_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_sub_rule_versions
    ADD CONSTRAINT seller_sub_rule_versions_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: seller_sub_rule_versions seller_sub_rule_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_sub_rule_versions
    ADD CONSTRAINT seller_sub_rule_versions_pkey PRIMARY KEY (id);


--
-- Name: seller_sub_rule_versions seller_sub_rule_versions_seller_id_component_key_effective__key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_sub_rule_versions
    ADD CONSTRAINT seller_sub_rule_versions_seller_id_component_key_effective__key UNIQUE (seller_id, component_key, effective_from, version);


--
-- Name: seller_sub_rule_versions seller_sub_rule_versions_seller_id_component_key_version_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_sub_rule_versions
    ADD CONSTRAINT seller_sub_rule_versions_seller_id_component_key_version_key UNIQUE (seller_id, component_key, version);


--
-- Name: seller_supervisions seller_supervisions_organization_id_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_supervisions
    ADD CONSTRAINT seller_supervisions_organization_id_id_key UNIQUE (organization_id, id);


--
-- Name: seller_supervisions seller_supervisions_organization_id_supervisor_user_id_sell_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_supervisions
    ADD CONSTRAINT seller_supervisions_organization_id_supervisor_user_id_sell_key UNIQUE (organization_id, supervisor_user_id, seller_id);


--
-- Name: seller_supervisions seller_supervisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_supervisions
    ADD CONSTRAINT seller_supervisions_pkey PRIMARY KEY (id);


--
-- Name: simulations simulations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.simulations
    ADD CONSTRAINT simulations_pkey PRIMARY KEY (id);


--
-- Name: agreements_bank_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX agreements_bank_id_idx ON public.agreements USING btree (bank_id);


--
-- Name: ai_credit_ledger_org_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ai_credit_ledger_org_idx ON public.ai_credit_ledger USING btree (organization_id, created_at);


--
-- Name: ai_usage_events_job_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ai_usage_events_job_idx ON public.ai_usage_events USING btree (organization_id, job_id);


--
-- Name: ai_usage_jobs_month_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ai_usage_jobs_month_idx ON public.ai_usage_jobs USING btree (organization_id, created_at);


--
-- Name: channel_commission_rules_channel_table_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX channel_commission_rules_channel_table_idx ON public.channel_commission_rule_versions USING btree (channel_id, product_table_id);


--
-- Name: channel_commission_rules_product_table_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX channel_commission_rules_product_table_idx ON public.channel_commission_rule_versions USING btree (product_table_id);


--
-- Name: clients_org_active_name_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX clients_org_active_name_idx ON public.clients USING btree (organization_id, full_name) WHERE (deleted_at IS NULL);


--
-- Name: clients_org_cpf_active_uniq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX clients_org_cpf_active_uniq ON public.clients USING btree (organization_id, cpf) WHERE (deleted_at IS NULL);


--
-- Name: clients_org_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX clients_org_created_at_idx ON public.clients USING btree (organization_id, created_at DESC);


--
-- Name: clients_organization_id_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX clients_organization_id_id_key ON public.clients USING btree (organization_id, id);


--
-- Name: commercial_channels_bank_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_channels_bank_idx ON public.commercial_channels USING btree (bank_id);


--
-- Name: commercial_channels_org_bank_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_channels_org_bank_idx ON public.commercial_channels USING btree (organization_id, bank_id);


--
-- Name: commercial_channels_payer_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_channels_payer_idx ON public.commercial_channels USING btree (payer_entity_id);


--
-- Name: commercial_channels_relationship_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_channels_relationship_idx ON public.commercial_channels USING btree (relationship_id);


--
-- Name: commercial_condition_commissions_org_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_condition_commissions_org_idx ON public.commercial_condition_commissions USING btree (organization_id, condition_id);


--
-- Name: commercial_condition_component_policy_attached_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_condition_component_policy_attached_by_idx ON public.commercial_condition_component_policy USING btree (attached_by) WHERE (attached_by IS NOT NULL);


--
-- Name: commercial_condition_component_policy_version_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_condition_component_policy_version_idx ON public.commercial_condition_component_policy USING btree (organization_id, policy_version_id);


--
-- Name: commercial_condition_components_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_condition_components_created_by_idx ON public.commercial_condition_components USING btree (created_by) WHERE (created_by IS NOT NULL);


--
-- Name: commercial_condition_components_org_condition_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_condition_components_org_condition_idx ON public.commercial_condition_components USING btree (organization_id, condition_id);


--
-- Name: commercial_condition_components_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_condition_components_type_idx ON public.commercial_condition_components USING btree (component_type_id);


--
-- Name: commercial_condition_shares_group_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_condition_shares_group_idx ON public.commercial_condition_shares USING btree (organization_id, group_id);


--
-- Name: commercial_conditions_contract_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_conditions_contract_type_idx ON public.commercial_conditions USING btree (contract_type_id);


--
-- Name: commercial_conditions_org_version_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_conditions_org_version_idx ON public.commercial_conditions USING btree (organization_id, product_table_version_id);


--
-- Name: commercial_conditions_term_amount_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_conditions_term_amount_lookup_idx ON public.commercial_conditions USING btree (product_table_version_id, contract_type_id, term_min, term_max, amount_min, amount_max);


--
-- Name: commercial_factor_batches_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_factor_batches_created_by_idx ON public.commercial_factor_batches USING btree (created_by) WHERE (created_by IS NOT NULL);


--
-- Name: commercial_factor_batches_import_batch_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_factor_batches_import_batch_idx ON public.commercial_factor_batches USING btree (import_batch_id) WHERE (import_batch_id IS NOT NULL);


--
-- Name: commercial_factor_batches_resolve_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_factor_batches_resolve_idx ON public.commercial_factor_batches USING btree (organization_id, profile_id, effective_date DESC, revision DESC) WHERE (status = 'published'::text);


--
-- Name: commercial_factor_entries_term_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_factor_entries_term_idx ON public.commercial_factor_entries USING btree (organization_id, batch_id, term_min, term_max);


--
-- Name: commercial_factor_profiles_agreement_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_factor_profiles_agreement_idx ON public.commercial_factor_profiles USING btree (organization_id, org_agreement_id) WHERE (org_agreement_id IS NOT NULL);


--
-- Name: commercial_factor_profiles_contract_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_factor_profiles_contract_type_idx ON public.commercial_factor_profiles USING btree (contract_type_id) WHERE (contract_type_id IS NOT NULL);


--
-- Name: commercial_factor_profiles_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_factor_profiles_created_by_idx ON public.commercial_factor_profiles USING btree (created_by) WHERE (created_by IS NOT NULL);


--
-- Name: commercial_factor_profiles_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_factor_profiles_lookup_idx ON public.commercial_factor_profiles USING btree (organization_id, org_bank_id, factor_mode, is_active);


--
-- Name: commercial_factor_profiles_scope_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX commercial_factor_profiles_scope_key ON public.commercial_factor_profiles USING btree (organization_id, org_bank_id, org_agreement_id, product_table_id, contract_type_id, factor_mode) NULLS NOT DISTINCT;


--
-- Name: commercial_factor_profiles_table_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_factor_profiles_table_idx ON public.commercial_factor_profiles USING btree (organization_id, product_table_id) WHERE (product_table_id IS NOT NULL);


--
-- Name: commercial_relationships_bank_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_relationships_bank_idx ON public.commercial_relationships USING btree (bank_id);


--
-- Name: commercial_relationships_downstream_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_relationships_downstream_idx ON public.commercial_relationships USING btree (downstream_entity_id);


--
-- Name: commercial_relationships_org_downstream_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_relationships_org_downstream_idx ON public.commercial_relationships USING btree (organization_id, downstream_entity_id);


--
-- Name: commercial_relationships_org_upstream_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_relationships_org_upstream_idx ON public.commercial_relationships USING btree (organization_id, upstream_entity_id);


--
-- Name: commercial_relationships_upstream_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_relationships_upstream_idx ON public.commercial_relationships USING btree (upstream_entity_id);


--
-- Name: commercial_sellers_commission_group_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_sellers_commission_group_idx ON public.commercial_sellers USING btree (organization_id, commission_group_id);


--
-- Name: commercial_sellers_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_sellers_created_by_idx ON public.commercial_sellers USING btree (created_by) WHERE (created_by IS NOT NULL);


--
-- Name: commercial_sellers_org_user_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX commercial_sellers_org_user_key ON public.commercial_sellers USING btree (organization_id, user_id) WHERE (user_id IS NOT NULL);


--
-- Name: commercial_sellers_seller_group_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commercial_sellers_seller_group_idx ON public.commercial_sellers USING btree (organization_id, seller_group_id);


--
-- Name: commercial_sellers_tax_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX commercial_sellers_tax_id_key ON public.commercial_sellers USING btree (organization_id, regexp_replace(tax_id, '[^0-9]'::text, ''::text, 'g'::text)) WHERE (tax_id IS NOT NULL);


--
-- Name: commission_components_org_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commission_components_org_idx ON public.commission_rule_components USING btree (organization_id);


--
-- Name: commission_components_rule_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX commission_components_rule_idx ON public.commission_rule_components USING btree (rule_version_id);


--
-- Name: commission_groups_name_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX commission_groups_name_key ON public.commission_groups USING btree (organization_id, lower(btrim(name)));


--
-- Name: component_payout_policies_agreement_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX component_payout_policies_agreement_idx ON public.component_payout_policies USING btree (organization_id, org_agreement_id) WHERE (org_agreement_id IS NOT NULL);


--
-- Name: component_payout_policies_bank_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX component_payout_policies_bank_idx ON public.component_payout_policies USING btree (organization_id, org_bank_id) WHERE (org_bank_id IS NOT NULL);


--
-- Name: component_payout_policies_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX component_payout_policies_created_by_idx ON public.component_payout_policies USING btree (created_by) WHERE (created_by IS NOT NULL);


--
-- Name: component_payout_policies_scope_name_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX component_payout_policies_scope_name_key ON public.component_payout_policies USING btree (organization_id, lower(btrim(name)), org_bank_id, org_agreement_id, product_table_id) NULLS NOT DISTINCT;


--
-- Name: component_payout_policies_table_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX component_payout_policies_table_idx ON public.component_payout_policies USING btree (organization_id, product_table_id) WHERE (product_table_id IS NOT NULL);


--
-- Name: component_payout_policy_items_component_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX component_payout_policy_items_component_idx ON public.component_payout_policy_items USING btree (component_type_id);


--
-- Name: component_payout_policy_items_group_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX component_payout_policy_items_group_idx ON public.component_payout_policy_items USING btree (organization_id, group_id);


--
-- Name: component_payout_policy_versions_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX component_payout_policy_versions_created_by_idx ON public.component_payout_policy_versions USING btree (created_by) WHERE (created_by IS NOT NULL);


--
-- Name: component_payout_policy_versions_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX component_payout_policy_versions_lookup_idx ON public.component_payout_policy_versions USING btree (organization_id, policy_id, effective_from DESC, version DESC);


--
-- Name: contract_types_global_name_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX contract_types_global_name_key ON public.contract_types USING btree (lower(btrim(name))) WHERE (organization_id IS NULL);


--
-- Name: contract_types_organization_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contract_types_organization_idx ON public.contract_types USING btree (organization_id) WHERE (organization_id IS NOT NULL);


--
-- Name: contract_types_tenant_name_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX contract_types_tenant_name_key ON public.contract_types USING btree (organization_id, lower(btrim(name))) WHERE (organization_id IS NOT NULL);


--
-- Name: contracts_client_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contracts_client_id_idx ON public.contracts USING btree (client_id);


--
-- Name: contracts_organization_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contracts_organization_id_idx ON public.contracts USING btree (organization_id);


--
-- Name: contracts_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contracts_user_id_idx ON public.contracts USING btree (user_id);


--
-- Name: customer_addresses_org_customer_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX customer_addresses_org_customer_idx ON public.customer_addresses USING btree (organization_id, customer_id);


--
-- Name: customer_bank_accounts_one_primary_per_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX customer_bank_accounts_one_primary_per_customer ON public.customer_bank_accounts USING btree (organization_id, customer_id) WHERE (is_primary = true);


--
-- Name: customer_bank_accounts_org_customer_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX customer_bank_accounts_org_customer_id_key ON public.customer_bank_accounts USING btree (organization_id, customer_id, id);


--
-- Name: customer_bank_accounts_org_customer_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX customer_bank_accounts_org_customer_idx ON public.customer_bank_accounts USING btree (organization_id, customer_id);


--
-- Name: customer_bank_accounts_org_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX customer_bank_accounts_org_id_key ON public.customer_bank_accounts USING btree (organization_id, id);


--
-- Name: customer_documents_document_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX customer_documents_document_type_idx ON public.customer_documents USING btree (document_type_id);


--
-- Name: customer_documents_org_customer_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX customer_documents_org_customer_idx ON public.customer_documents USING btree (organization_id, customer_id, created_at DESC);


--
-- Name: customer_documents_org_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX customer_documents_org_id_key ON public.customer_documents USING btree (organization_id, id);


--
-- Name: customer_documents_uploaded_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX customer_documents_uploaded_by_idx ON public.customer_documents USING btree (uploaded_by);


--
-- Name: customer_pix_keys_bank_account_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX customer_pix_keys_bank_account_idx ON public.customer_pix_keys USING btree (organization_id, customer_id, bank_account_id);


--
-- Name: customer_pix_keys_one_primary_per_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX customer_pix_keys_one_primary_per_customer ON public.customer_pix_keys USING btree (organization_id, customer_id) WHERE (is_primary = true);


--
-- Name: customer_pix_keys_org_customer_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX customer_pix_keys_org_customer_idx ON public.customer_pix_keys USING btree (organization_id, customer_id);


--
-- Name: customer_timeline_actor_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX customer_timeline_actor_idx ON public.customer_timeline_events USING btree (actor_user_id);


--
-- Name: customer_timeline_org_customer_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX customer_timeline_org_customer_time_idx ON public.customer_timeline_events USING btree (organization_id, customer_id, occurred_at DESC);


--
-- Name: digitization_jobs_active_proposal_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX digitization_jobs_active_proposal_key ON public.digitization_jobs USING btree (organization_id, proposal_id) WHERE (status = ANY (ARRAY['queued'::text, 'assigned'::text, 'in_progress'::text, 'blocked'::text, 'submitted'::text]));


--
-- Name: digitization_jobs_assigned_to_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX digitization_jobs_assigned_to_idx ON public.digitization_jobs USING btree (assigned_to);


--
-- Name: digitization_jobs_org_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX digitization_jobs_org_id_key ON public.digitization_jobs USING btree (organization_id, id);


--
-- Name: digitization_jobs_org_status_priority_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX digitization_jobs_org_status_priority_idx ON public.digitization_jobs USING btree (organization_id, status, priority DESC, queued_at);


--
-- Name: document_checklist_items_document_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_checklist_items_document_type_idx ON public.document_checklist_items USING btree (document_type_id);


--
-- Name: document_checklist_items_org_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX document_checklist_items_org_id_key ON public.document_checklist_items USING btree (organization_id, id);


--
-- Name: document_checklist_items_org_template_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_checklist_items_org_template_idx ON public.document_checklist_items USING btree (organization_id, template_id);


--
-- Name: document_checklist_templates_org_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX document_checklist_templates_org_id_key ON public.document_checklist_templates USING btree (organization_id, id);


--
-- Name: document_checklist_templates_org_route_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX document_checklist_templates_org_route_idx ON public.document_checklist_templates USING btree (organization_id, route_id);


--
-- Name: financial_events_channel_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX financial_events_channel_idx ON public.financial_events USING btree (channel_id);


--
-- Name: financial_events_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX financial_events_created_by_idx ON public.financial_events USING btree (created_by);


--
-- Name: financial_events_org_proposal_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX financial_events_org_proposal_idx ON public.financial_events USING btree (organization_id, proposal_id, occurred_at);


--
-- Name: financial_events_payer_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX financial_events_payer_idx ON public.financial_events USING btree (payer_entity_id);


--
-- Name: financial_events_producer_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX financial_events_producer_idx ON public.financial_events USING btree (producer_entity_id);


--
-- Name: financial_events_proposal_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX financial_events_proposal_idx ON public.financial_events USING btree (proposal_id);


--
-- Name: financial_events_reversal_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX financial_events_reversal_idx ON public.financial_events USING btree (reverses_event_id);


--
-- Name: financial_evidence_batch_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX financial_evidence_batch_idx ON public.financial_evidence_links USING btree (import_batch_id);


--
-- Name: financial_evidence_decision_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX financial_evidence_decision_idx ON public.financial_evidence_links USING btree (import_decision_id);


--
-- Name: financial_evidence_event_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX financial_evidence_event_idx ON public.financial_evidence_links USING btree (financial_event_id);


--
-- Name: financial_evidence_org_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX financial_evidence_org_idx ON public.financial_evidence_links USING btree (organization_id);


--
-- Name: financial_evidence_raw_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX financial_evidence_raw_idx ON public.financial_evidence_links USING btree (import_raw_row_id);


--
-- Name: financial_reconciliation_case_identity_uq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX financial_reconciliation_case_identity_uq ON public.financial_reconciliation_cases USING btree (organization_id, proposal_id, COALESCE(component_type, '__none__'::text));


--
-- Name: financial_reconciliation_channel_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX financial_reconciliation_channel_idx ON public.financial_reconciliation_cases USING btree (channel_id);


--
-- Name: financial_reconciliation_org_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX financial_reconciliation_org_status_idx ON public.financial_reconciliation_cases USING btree (organization_id, status);


--
-- Name: financial_reconciliation_proposal_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX financial_reconciliation_proposal_idx ON public.financial_reconciliation_cases USING btree (proposal_id);


--
-- Name: financial_reconciliation_resolved_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX financial_reconciliation_resolved_by_idx ON public.financial_reconciliation_cases USING btree (resolved_by);


--
-- Name: import_applied_decisions_applied_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_applied_decisions_applied_by_idx ON public.import_applied_decisions USING btree (applied_by);


--
-- Name: import_applied_decisions_decision_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_applied_decisions_decision_idx ON public.import_applied_decisions USING btree (decision_id);


--
-- Name: import_applied_decisions_proposal_identity_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_applied_decisions_proposal_identity_idx ON public.import_applied_decisions USING btree (proposal_external_identity_id);


--
-- Name: import_applied_decisions_table_identity_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_applied_decisions_table_identity_idx ON public.import_applied_decisions USING btree (table_external_identity_id);


--
-- Name: import_batches_adapter_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_batches_adapter_idx ON public.import_batches USING btree (adapter_id) WHERE (adapter_id IS NOT NULL);


--
-- Name: import_batches_org_source_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_batches_org_source_idx ON public.import_batches USING btree (organization_id, source_id);


--
-- Name: import_batches_received_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_batches_received_by_idx ON public.import_batches USING btree (received_by);


--
-- Name: import_batches_source_external_batch_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX import_batches_source_external_batch_uidx ON public.import_batches USING btree (organization_id, source_id, external_batch_id) WHERE (external_batch_id IS NOT NULL);


--
-- Name: import_batches_source_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_batches_source_idx ON public.import_batches USING btree (source_id);


--
-- Name: import_conflict_rows_org_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_conflict_rows_org_idx ON public.import_conflict_rows USING btree (organization_id);


--
-- Name: import_conflict_rows_raw_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_conflict_rows_raw_idx ON public.import_conflict_rows USING btree (raw_row_id);


--
-- Name: import_conflicts_batch_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_conflicts_batch_idx ON public.import_conflicts USING btree (batch_id);


--
-- Name: import_conflicts_org_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_conflicts_org_status_idx ON public.import_conflicts USING btree (organization_id, status, created_at DESC);


--
-- Name: import_conflicts_resolved_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_conflicts_resolved_by_idx ON public.import_conflicts USING btree (resolved_by) WHERE (resolved_by IS NOT NULL);


--
-- Name: import_decisions_batch_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_decisions_batch_idx ON public.import_decisions USING btree (batch_id);


--
-- Name: import_decisions_candidate_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_decisions_candidate_idx ON public.import_decisions USING btree (candidate_id);


--
-- Name: import_decisions_decided_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_decisions_decided_by_idx ON public.import_decisions USING btree (decided_by);


--
-- Name: import_decisions_normalized_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_decisions_normalized_idx ON public.import_decisions USING btree (normalized_row_id);


--
-- Name: import_decisions_org_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_decisions_org_idx ON public.import_decisions USING btree (organization_id);


--
-- Name: import_jobs_organization_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_jobs_organization_id_idx ON public.import_jobs USING btree (organization_id);


--
-- Name: import_layout_mappings_one_confirmed; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX import_layout_mappings_one_confirmed ON public.import_layout_mappings USING btree (organization_id, lower(btrim(source_label)), layout_fingerprint) WHERE (status = 'confirmed'::text);


--
-- Name: import_layout_mappings_version_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX import_layout_mappings_version_key ON public.import_layout_mappings USING btree (organization_id, lower(btrim(source_label)), layout_fingerprint, version);


--
-- Name: import_match_channel_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_match_channel_idx ON public.import_match_candidates USING btree (channel_id);


--
-- Name: import_match_normalized_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_match_normalized_idx ON public.import_match_candidates USING btree (normalized_row_id);


--
-- Name: import_match_org_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_match_org_idx ON public.import_match_candidates USING btree (organization_id);


--
-- Name: import_match_producer_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_match_producer_idx ON public.import_match_candidates USING btree (producer_entity_id);


--
-- Name: import_match_product_table_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_match_product_table_idx ON public.import_match_candidates USING btree (product_table_id);


--
-- Name: import_match_proposal_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_match_proposal_idx ON public.import_match_candidates USING btree (proposal_id);


--
-- Name: import_normalized_proposal_number_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_normalized_proposal_number_idx ON public.import_normalized_rows USING btree (organization_id, bank_key, external_proposal_number);


--
-- Name: import_normalized_raw_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_normalized_raw_idx ON public.import_normalized_rows USING btree (raw_row_id);


--
-- Name: import_raw_rows_batch_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_raw_rows_batch_idx ON public.import_raw_rows USING btree (batch_id);


--
-- Name: import_sources_entity_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_sources_entity_idx ON public.import_sources USING btree (source_entity_id);


--
-- Name: import_sources_org_entity_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_sources_org_entity_idx ON public.import_sources USING btree (organization_id, source_entity_id);


--
-- Name: import_sources_semantic_reviewed_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX import_sources_semantic_reviewed_by_idx ON public.import_sources USING btree (financial_semantic_reviewed_by);


--
-- Name: integration_field_mappings_adapter_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX integration_field_mappings_adapter_idx ON public.integration_field_mappings USING btree (adapter_id, contract_version);


--
-- Name: integration_run_artifacts_batch_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX integration_run_artifacts_batch_idx ON public.integration_run_artifacts USING btree (import_batch_id) WHERE (import_batch_id IS NOT NULL);


--
-- Name: integration_run_artifacts_dedupe_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX integration_run_artifacts_dedupe_uidx ON public.integration_run_artifacts USING btree (run_id, artifact_kind, content_sha256) WHERE (content_sha256 IS NOT NULL);


--
-- Name: integration_run_artifacts_org_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX integration_run_artifacts_org_idx ON public.integration_run_artifacts USING btree (organization_id);


--
-- Name: integration_run_artifacts_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX integration_run_artifacts_run_idx ON public.integration_run_artifacts USING btree (run_id);


--
-- Name: integration_runs_adapter_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX integration_runs_adapter_idx ON public.integration_runs USING btree (adapter_id);


--
-- Name: integration_runs_binding_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX integration_runs_binding_idx ON public.integration_runs USING btree (binding_id);


--
-- Name: integration_runs_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX integration_runs_created_by_idx ON public.integration_runs USING btree (created_by) WHERE (created_by IS NOT NULL);


--
-- Name: integration_runs_dispatch_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX integration_runs_dispatch_idx ON public.integration_runs USING btree (status, next_attempt_at, lease_expires_at) WHERE (status = ANY (ARRAY['queued'::text, 'failed'::text, 'running'::text]));


--
-- Name: integration_runs_org_status_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX integration_runs_org_status_created_idx ON public.integration_runs USING btree (organization_id, status, created_at DESC);


--
-- Name: integration_runs_parent_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX integration_runs_parent_uidx ON public.integration_runs USING btree (parent_run_id) WHERE (parent_run_id IS NOT NULL);


--
-- Name: integration_source_bindings_adapter_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX integration_source_bindings_adapter_idx ON public.integration_source_bindings USING btree (adapter_id);


--
-- Name: integration_source_bindings_org_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX integration_source_bindings_org_idx ON public.integration_source_bindings USING btree (organization_id);


--
-- Name: integration_source_bindings_source_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX integration_source_bindings_source_idx ON public.integration_source_bindings USING btree (source_id);


--
-- Name: lead_events_actor_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lead_events_actor_idx ON public.lead_events USING btree (actor_user_id) WHERE (actor_user_id IS NOT NULL);


--
-- Name: lead_events_lead_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lead_events_lead_idx ON public.lead_events USING btree (lead_id, created_at);


--
-- Name: lead_events_org_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lead_events_org_idx ON public.lead_events USING btree (organization_id);


--
-- Name: leads_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX leads_created_by_idx ON public.leads USING btree (created_by) WHERE (created_by IS NOT NULL);


--
-- Name: leads_customer_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX leads_customer_uidx ON public.leads USING btree (customer_id) WHERE (customer_id IS NOT NULL);


--
-- Name: leads_org_channel_ref_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX leads_org_channel_ref_uidx ON public.leads USING btree (organization_id, channel, external_ref) WHERE (external_ref IS NOT NULL);


--
-- Name: leads_org_customer_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX leads_org_customer_idx ON public.leads USING btree (organization_id, customer_id) WHERE (customer_id IS NOT NULL);


--
-- Name: leads_org_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX leads_org_status_idx ON public.leads USING btree (organization_id, status, created_at DESC);


--
-- Name: leads_owner_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX leads_owner_idx ON public.leads USING btree (owner_user_id) WHERE (owner_user_id IS NOT NULL);


--
-- Name: network_split_bank_table_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX network_split_bank_table_idx ON public.network_split_rule_versions USING btree (bank_id, product_table_id);


--
-- Name: network_split_org_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX network_split_org_idx ON public.network_split_rule_versions USING btree (organization_id);


--
-- Name: network_split_product_table_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX network_split_product_table_idx ON public.network_split_rule_versions USING btree (product_table_id);


--
-- Name: network_split_relationship_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX network_split_relationship_idx ON public.network_split_rule_versions USING btree (relationship_id);


--
-- Name: operational_attention_events_item_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX operational_attention_events_item_idx ON public.operational_attention_events USING btree (organization_id, item_id, created_at);


--
-- Name: operational_attention_items_active_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX operational_attention_items_active_key ON public.operational_attention_items USING btree (organization_id, dedupe_key) WHERE (status = ANY (ARRAY['open'::text, 'snoozed'::text, 'dismissed'::text]));


--
-- Name: operational_attention_items_org_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX operational_attention_items_org_status_idx ON public.operational_attention_items USING btree (organization_id, status, severity);


--
-- Name: operational_cases_digitization_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX operational_cases_digitization_idx ON public.operational_cases USING btree (organization_id, digitization_job_id);


--
-- Name: operational_cases_org_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX operational_cases_org_id_key ON public.operational_cases USING btree (organization_id, id);


--
-- Name: operational_cases_org_stage_due_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX operational_cases_org_stage_due_idx ON public.operational_cases USING btree (organization_id, current_stage_id, due_at);


--
-- Name: operational_cases_org_stage_state_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX operational_cases_org_stage_state_idx ON public.operational_cases USING btree (organization_id, current_stage_id, canonical_state);


--
-- Name: operational_cases_org_state_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX operational_cases_org_state_idx ON public.operational_cases USING btree (organization_id, canonical_state);


--
-- Name: operational_cases_owner_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX operational_cases_owner_idx ON public.operational_cases USING btree (owner_user_id);


--
-- Name: operational_events_actor_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX operational_events_actor_idx ON public.operational_events USING btree (actor_user_id);


--
-- Name: operational_events_case_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX operational_events_case_time_idx ON public.operational_events USING btree (organization_id, operational_case_id, occurred_at DESC);


--
-- Name: organization_admin_events_actor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_admin_events_actor ON public.organization_admin_events USING btree (actor_user_id);


--
-- Name: organization_admin_events_org_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_admin_events_org_time ON public.organization_admin_events USING btree (organization_id, occurred_at DESC);


--
-- Name: organization_admin_events_target; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_admin_events_target ON public.organization_admin_events USING btree (target_user_id);


--
-- Name: organization_agreements_name_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_agreements_name_key ON public.organization_agreements USING btree (organization_id, lower(btrim(name)));


--
-- Name: organization_agreements_template_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_agreements_template_idx ON public.organization_agreements USING btree (template_id) WHERE (template_id IS NOT NULL);


--
-- Name: organization_agreements_template_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_agreements_template_key ON public.organization_agreements USING btree (organization_id, template_id) WHERE (template_id IS NOT NULL);


--
-- Name: organization_banks_name_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_banks_name_key ON public.organization_banks USING btree (organization_id, lower(btrim(name)));


--
-- Name: organization_branches_one_matrix; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_branches_one_matrix ON public.organization_branches USING btree (organization_id) WHERE (branch_type = 'matrix'::text);


--
-- Name: organization_contract_type_settings_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_contract_type_settings_type_idx ON public.organization_contract_type_settings USING btree (contract_type_id);


--
-- Name: organization_invitations_accepted_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_invitations_accepted_user ON public.organization_invitations USING btree (accepted_user_id);


--
-- Name: organization_invitations_invited_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_invitations_invited_by ON public.organization_invitations USING btree (invited_by);


--
-- Name: organization_invitations_one_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_invitations_one_pending ON public.organization_invitations USING btree (organization_id, email) WHERE (status = 'pending'::text);


--
-- Name: organization_invitations_org_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_invitations_org_status ON public.organization_invitations USING btree (organization_id, status, created_at DESC);


--
-- Name: organization_invitations_pending_seller_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_invitations_pending_seller_key ON public.organization_invitations USING btree (organization_id, seller_id) WHERE ((seller_id IS NOT NULL) AND (status = 'pending'::text));


--
-- Name: organization_memberships_org_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_memberships_org_status_idx ON public.organization_memberships USING btree (organization_id, status);


--
-- Name: organization_memberships_user_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_memberships_user_status_idx ON public.organization_memberships USING btree (user_id, status);


--
-- Name: organization_product_routes_bank_agreement_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_product_routes_bank_agreement_idx ON public.organization_product_routes USING btree (bank_id, agreement_id);


--
-- Name: organization_product_routes_org_agreement_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_product_routes_org_agreement_idx ON public.organization_product_routes USING btree (organization_id, org_agreement_id) WHERE (org_agreement_id IS NOT NULL);


--
-- Name: organization_product_routes_org_bank_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_product_routes_org_bank_idx ON public.organization_product_routes USING btree (organization_id, org_bank_id) WHERE (org_bank_id IS NOT NULL);


--
-- Name: organization_product_routes_org_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_product_routes_org_id_key ON public.organization_product_routes USING btree (organization_id, id);


--
-- Name: organization_product_routes_org_provider_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_product_routes_org_provider_idx ON public.organization_product_routes USING btree (organization_id, org_provider_id) WHERE (org_provider_id IS NOT NULL);


--
-- Name: organization_product_routes_org_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_product_routes_org_status_idx ON public.organization_product_routes USING btree (organization_id, status);


--
-- Name: organization_product_routes_product_modality_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_product_routes_product_modality_idx ON public.organization_product_routes USING btree (product_id, modality_id);


--
-- Name: organization_product_routes_provider_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX organization_product_routes_provider_idx ON public.organization_product_routes USING btree (provider_id);


--
-- Name: organization_product_routes_v3_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_product_routes_v3_key ON public.organization_product_routes USING btree (organization_id, org_bank_id, COALESCE(org_provider_id, '00000000-0000-0000-0000-000000000000'::uuid), org_agreement_id) WHERE (org_bank_id IS NOT NULL);


--
-- Name: organization_providers_name_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX organization_providers_name_key ON public.organization_providers USING btree (organization_id, lower(btrim(name)));


--
-- Name: payout_policies_name_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX payout_policies_name_key ON public.payout_policies USING btree (organization_id, lower(btrim(name)));


--
-- Name: payout_policy_items_group_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payout_policy_items_group_idx ON public.payout_policy_items USING btree (organization_id, group_id);


--
-- Name: payout_policy_versions_policy_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX payout_policy_versions_policy_idx ON public.payout_policy_versions USING btree (organization_id, policy_id);


--
-- Name: platform_admin_audit_actor_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_admin_audit_actor_time_idx ON public.platform_admin_audit_events USING btree (actor_user_id, occurred_at DESC);


--
-- Name: platform_admin_audit_org_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_admin_audit_org_idx ON public.platform_admin_audit_events USING btree (organization_id);


--
-- Name: platform_admin_audit_target_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_admin_audit_target_user_idx ON public.platform_admin_audit_events USING btree (target_user_id);


--
-- Name: product_table_external_channel_table_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX product_table_external_channel_table_idx ON public.product_table_external_identities USING btree (channel_id, product_table_id);


--
-- Name: product_table_external_product_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX product_table_external_product_idx ON public.product_table_external_identities USING btree (product_table_id);


--
-- Name: product_table_versions_org_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX product_table_versions_org_id_key ON public.product_table_versions USING btree (organization_id, id);


--
-- Name: product_table_versions_org_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX product_table_versions_org_status_idx ON public.product_table_versions USING btree (organization_id, status);


--
-- Name: product_table_versions_org_table_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX product_table_versions_org_table_idx ON public.product_table_versions USING btree (organization_id, product_table_id);


--
-- Name: product_table_versions_table_effective_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX product_table_versions_table_effective_idx ON public.product_table_versions USING btree (product_table_id, effective_from DESC);


--
-- Name: product_tables_org_route_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX product_tables_org_route_idx ON public.product_tables USING btree (organization_id, route_id);


--
-- Name: profiles_organization_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profiles_organization_id_idx ON public.profiles USING btree (organization_id);


--
-- Name: proposal_component_snapshot_component_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_component_snapshot_component_idx ON public.proposal_commercial_component_snapshots USING btree (commission_component_id);


--
-- Name: proposal_component_snapshot_proposal_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_component_snapshot_proposal_idx ON public.proposal_commercial_component_snapshots USING btree (proposal_id);


--
-- Name: proposal_component_snapshot_seller_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_component_snapshot_seller_idx ON public.proposal_commercial_component_snapshots USING btree (organization_id, seller_id) WHERE (seller_id IS NOT NULL);


--
-- Name: proposal_component_snapshot_split_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_component_snapshot_split_idx ON public.proposal_commercial_component_snapshots USING btree (split_rule_version_id) WHERE (split_rule_version_id IS NOT NULL);


--
-- Name: proposal_component_snapshot_sub_rule_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_component_snapshot_sub_rule_idx ON public.proposal_commercial_component_snapshots USING btree (organization_id, seller_sub_rule_version_id) WHERE (seller_sub_rule_version_id IS NOT NULL);


--
-- Name: proposal_document_links_document_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_document_links_document_idx ON public.proposal_document_links USING btree (organization_id, customer_document_id);


--
-- Name: proposal_document_links_linked_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_document_links_linked_by_idx ON public.proposal_document_links USING btree (linked_by);


--
-- Name: proposal_document_links_org_requirement_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_document_links_org_requirement_idx ON public.proposal_document_links USING btree (organization_id, requirement_id);


--
-- Name: proposal_document_requirements_document_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_document_requirements_document_type_idx ON public.proposal_document_requirements USING btree (document_type_id);


--
-- Name: proposal_document_requirements_exception_approver_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_document_requirements_exception_approver_idx ON public.proposal_document_requirements USING btree (exception_approved_by);


--
-- Name: proposal_document_requirements_item_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_document_requirements_item_idx ON public.proposal_document_requirements USING btree (organization_id, checklist_item_id);


--
-- Name: proposal_document_requirements_org_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX proposal_document_requirements_org_id_key ON public.proposal_document_requirements USING btree (organization_id, id);


--
-- Name: proposal_document_requirements_proposal_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_document_requirements_proposal_status_idx ON public.proposal_document_requirements USING btree (organization_id, proposal_id, status);


--
-- Name: proposal_external_channel_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_external_channel_idx ON public.proposal_external_identities USING btree (channel_id);


--
-- Name: proposal_external_identities_org_inst_number_ci_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX proposal_external_identities_org_inst_number_ci_uidx ON public.proposal_external_identities USING btree (organization_id, lower(institution_key), external_proposal_number);


--
-- Name: proposal_external_proposal_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_external_proposal_idx ON public.proposal_external_identities USING btree (proposal_id);


--
-- Name: proposal_seller_commission_org_seller_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_seller_commission_org_seller_idx ON public.proposal_seller_commission_snapshots USING btree (organization_id, seller_id, frozen_at DESC);


--
-- Name: proposal_seller_commission_proposal_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_seller_commission_proposal_idx ON public.proposal_seller_commission_snapshots USING btree (proposal_id);


--
-- Name: proposal_snapshot_channel_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_snapshot_channel_idx ON public.proposal_commercial_snapshots USING btree (channel_id);


--
-- Name: proposal_snapshot_org_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_snapshot_org_idx ON public.proposal_commercial_snapshots USING btree (organization_id);


--
-- Name: proposal_snapshot_payer_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_snapshot_payer_idx ON public.proposal_commercial_snapshots USING btree (payer_entity_id);


--
-- Name: proposal_snapshot_producer_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_snapshot_producer_idx ON public.proposal_commercial_snapshots USING btree (producer_entity_id);


--
-- Name: proposal_snapshot_rule_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_snapshot_rule_idx ON public.proposal_commercial_snapshots USING btree (commission_rule_version_id);


--
-- Name: proposal_snapshot_split_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_snapshot_split_idx ON public.proposal_commercial_snapshots USING btree (split_rule_version_id);


--
-- Name: proposal_status_evidence_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_status_evidence_created_by_idx ON public.proposal_status_evidence USING btree (created_by);


--
-- Name: proposal_status_evidence_decision_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_status_evidence_decision_idx ON public.proposal_status_evidence USING btree (import_decision_id);


--
-- Name: proposal_status_evidence_proposal_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposal_status_evidence_proposal_idx ON public.proposal_status_evidence USING btree (proposal_id);


--
-- Name: proposals_v2_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposals_v2_created_by_idx ON public.proposals_v2 USING btree (created_by);


--
-- Name: proposals_v2_org_customer_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposals_v2_org_customer_created_idx ON public.proposals_v2 USING btree (organization_id, customer_id, created_at DESC);


--
-- Name: proposals_v2_org_external_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX proposals_v2_org_external_id_key ON public.proposals_v2 USING btree (organization_id, external_proposal_id) WHERE (external_proposal_id IS NOT NULL);


--
-- Name: proposals_v2_org_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX proposals_v2_org_id_key ON public.proposals_v2 USING btree (organization_id, id);


--
-- Name: proposals_v2_org_seller_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposals_v2_org_seller_idx ON public.proposals_v2 USING btree (organization_id, seller_id) WHERE (seller_id IS NOT NULL);


--
-- Name: proposals_v2_org_simulation_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposals_v2_org_simulation_idx ON public.proposals_v2 USING btree (organization_id, simulation_id);


--
-- Name: proposals_v2_org_simulation_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX proposals_v2_org_simulation_unique ON public.proposals_v2 USING btree (organization_id, simulation_id) WHERE (simulation_id IS NOT NULL);


--
-- Name: proposals_v2_org_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposals_v2_org_status_idx ON public.proposals_v2 USING btree (organization_id, status);


--
-- Name: proposals_v2_org_table_version_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposals_v2_org_table_version_idx ON public.proposals_v2 USING btree (organization_id, product_table_version_id);


--
-- Name: proposals_v2_simulation_snapshot_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX proposals_v2_simulation_snapshot_idx ON public.proposals_v2 USING btree (organization_id, simulation_id, customer_id, product_table_version_id);


--
-- Name: seller_addresses_one_current; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX seller_addresses_one_current ON public.seller_addresses USING btree (organization_id, seller_id) WHERE is_current;


--
-- Name: seller_bank_aliases_scope_user_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX seller_bank_aliases_scope_user_key ON public.seller_bank_aliases USING btree (organization_id, lower(btrim(source_key)), external_user_normalized) WHERE is_active;


--
-- Name: seller_bank_aliases_seller_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX seller_bank_aliases_seller_idx ON public.seller_bank_aliases USING btree (organization_id, seller_id) WHERE is_active;


--
-- Name: seller_groups_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX seller_groups_created_by_idx ON public.seller_groups USING btree (created_by) WHERE (created_by IS NOT NULL);


--
-- Name: seller_groups_name_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX seller_groups_name_key ON public.seller_groups USING btree (organization_id, lower(btrim(name)));


--
-- Name: seller_payment_accounts_one_current; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX seller_payment_accounts_one_current ON public.seller_payment_accounts USING btree (organization_id, seller_id) WHERE is_current;


--
-- Name: seller_sub_rule_lookup_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX seller_sub_rule_lookup_idx ON public.seller_sub_rule_versions USING btree (organization_id, seller_id, component_key, effective_from DESC, version DESC) WHERE (status = 'published'::text);


--
-- Name: seller_sub_rule_org_seller_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX seller_sub_rule_org_seller_id_key ON public.seller_sub_rule_versions USING btree (organization_id, seller_id, id);


--
-- Name: seller_sub_rule_versions_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX seller_sub_rule_versions_created_by_idx ON public.seller_sub_rule_versions USING btree (created_by) WHERE (created_by IS NOT NULL);


--
-- Name: seller_supervisions_seller_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX seller_supervisions_seller_idx ON public.seller_supervisions USING btree (organization_id, seller_id) WHERE is_active;


--
-- Name: seller_supervisions_supervisor_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX seller_supervisions_supervisor_idx ON public.seller_supervisions USING btree (organization_id, supervisor_user_id) WHERE is_active;


--
-- Name: simulations_created_by_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX simulations_created_by_idx ON public.simulations USING btree (created_by);


--
-- Name: simulations_org_customer_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX simulations_org_customer_created_idx ON public.simulations USING btree (organization_id, customer_id, created_at DESC);


--
-- Name: simulations_org_id_customer_table_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX simulations_org_id_customer_table_key ON public.simulations USING btree (organization_id, id, customer_id, product_table_version_id);


--
-- Name: simulations_org_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX simulations_org_id_key ON public.simulations USING btree (organization_id, id);


--
-- Name: simulations_org_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX simulations_org_status_idx ON public.simulations USING btree (organization_id, status);


--
-- Name: simulations_org_table_version_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX simulations_org_table_version_idx ON public.simulations USING btree (organization_id, product_table_version_id);


--
-- Name: ai_credit_ledger ai_credit_ledger_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ai_credit_ledger_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.ai_credit_ledger FOR EACH ROW EXECUTE FUNCTION public.guard_ai_write();


--
-- Name: ai_usage_events ai_usage_events_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ai_usage_events_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.ai_usage_events FOR EACH ROW EXECUTE FUNCTION public.guard_ai_write();


--
-- Name: ai_usage_jobs ai_usage_jobs_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ai_usage_jobs_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.ai_usage_jobs FOR EACH ROW EXECUTE FUNCTION public.guard_ai_write();


--
-- Name: channel_commission_rule_versions channel_commission_rule_versions_freeze_published; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER channel_commission_rule_versions_freeze_published BEFORE DELETE OR UPDATE ON public.channel_commission_rule_versions FOR EACH ROW EXECUTE FUNCTION public.freeze_published_commercial_rule();


--
-- Name: channel_commission_rule_versions channel_commission_rule_versions_same_org_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER channel_commission_rule_versions_same_org_guard BEFORE INSERT OR UPDATE ON public.channel_commission_rule_versions FOR EACH ROW EXECUTE FUNCTION public.assert_same_organization_reference();


--
-- Name: commercial_channels commercial_channels_same_org_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commercial_channels_same_org_guard BEFORE INSERT OR UPDATE ON public.commercial_channels FOR EACH ROW EXECUTE FUNCTION public.assert_same_organization_reference();


--
-- Name: commercial_condition_commissions commercial_condition_commissions_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commercial_condition_commissions_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.commercial_condition_commissions FOR EACH ROW EXECUTE FUNCTION public.guard_condition_write();


--
-- Name: commercial_condition_component_policy commercial_condition_component_policy_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commercial_condition_component_policy_00_guard BEFORE INSERT OR UPDATE ON public.commercial_condition_component_policy FOR EACH ROW EXECUTE FUNCTION public.guard_condition_component_policy();


--
-- Name: commercial_condition_components commercial_condition_components_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commercial_condition_components_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.commercial_condition_components FOR EACH ROW EXECUTE FUNCTION public.guard_component_commission_write();


--
-- Name: commercial_condition_shares commercial_condition_shares_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commercial_condition_shares_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.commercial_condition_shares FOR EACH ROW EXECUTE FUNCTION public.guard_condition_write();


--
-- Name: commercial_conditions commercial_conditions_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commercial_conditions_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.commercial_conditions FOR EACH ROW EXECUTE FUNCTION public.guard_condition_write();


--
-- Name: commercial_conditions commercial_conditions_01_contract_type_scope; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commercial_conditions_01_contract_type_scope BEFORE INSERT OR UPDATE OF contract_type_id, organization_id ON public.commercial_conditions FOR EACH ROW EXECUTE FUNCTION public.guard_condition_contract_type_scope();


--
-- Name: commercial_factor_batches commercial_factor_batches_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commercial_factor_batches_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.commercial_factor_batches FOR EACH ROW EXECUTE FUNCTION public.guard_factor_batch();


--
-- Name: commercial_factor_entries commercial_factor_entries_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commercial_factor_entries_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.commercial_factor_entries FOR EACH ROW EXECUTE FUNCTION public.guard_factor_entry();


--
-- Name: commercial_factor_profiles commercial_factor_profiles_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commercial_factor_profiles_00_guard BEFORE INSERT OR UPDATE ON public.commercial_factor_profiles FOR EACH ROW EXECUTE FUNCTION public.guard_factor_profile();


--
-- Name: commercial_relationships commercial_relationships_same_org_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commercial_relationships_same_org_guard BEFORE INSERT OR UPDATE ON public.commercial_relationships FOR EACH ROW EXECUTE FUNCTION public.assert_same_organization_reference();


--
-- Name: commercial_sellers commercial_sellers_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commercial_sellers_00_guard BEFORE INSERT OR UPDATE ON public.commercial_sellers FOR EACH ROW EXECUTE FUNCTION public.guard_seller_catalog_row();


--
-- Name: commission_group_component_limits commission_group_component_limits_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commission_group_component_limits_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.commission_group_component_limits FOR EACH ROW EXECUTE FUNCTION public.guard_commission_group_component_limit_write();


--
-- Name: commission_groups commission_groups_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commission_groups_00_guard BEFORE INSERT OR UPDATE ON public.commission_groups FOR EACH ROW EXECUTE FUNCTION public.guard_org_catalog_row();


--
-- Name: commission_groups commission_groups_20_received_basis_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commission_groups_20_received_basis_guard BEFORE INSERT OR UPDATE OF calculation_basis ON public.commission_groups FOR EACH ROW EXECUTE FUNCTION public.guard_commission_group_received_basis();


--
-- Name: commission_rule_components commission_rule_components_same_org_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER commission_rule_components_same_org_guard BEFORE INSERT OR UPDATE ON public.commission_rule_components FOR EACH ROW EXECUTE FUNCTION public.assert_same_organization_reference();


--
-- Name: component_payout_policies component_payout_policies_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER component_payout_policies_00_guard BEFORE INSERT OR UPDATE ON public.component_payout_policies FOR EACH ROW EXECUTE FUNCTION public.guard_org_catalog_row();


--
-- Name: component_payout_policies component_payout_policies_01_scope; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER component_payout_policies_01_scope BEFORE INSERT OR UPDATE ON public.component_payout_policies FOR EACH ROW EXECUTE FUNCTION public.guard_component_payout_policy_scope();


--
-- Name: component_payout_policy_items component_payout_policy_items_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER component_payout_policy_items_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.component_payout_policy_items FOR EACH ROW EXECUTE FUNCTION public.guard_component_commission_write();


--
-- Name: component_payout_policy_items component_payout_policy_items_15_group_limit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER component_payout_policy_items_15_group_limit BEFORE INSERT OR UPDATE OF group_id, component_type_id, mode, share_pct, direct_value_kind, direct_value ON public.component_payout_policy_items FOR EACH ROW EXECUTE FUNCTION public.guard_component_payout_group_limit();


--
-- Name: component_payout_policy_versions component_payout_policy_versions_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER component_payout_policy_versions_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.component_payout_policy_versions FOR EACH ROW EXECUTE FUNCTION public.guard_component_commission_write();


--
-- Name: contract_types contract_types_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER contract_types_00_guard BEFORE INSERT OR UPDATE ON public.contract_types FOR EACH ROW EXECUTE FUNCTION public.guard_contract_type_catalog();


--
-- Name: customer_documents customer_documents_evidence_immutable_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER customer_documents_evidence_immutable_guard BEFORE UPDATE ON public.customer_documents FOR EACH ROW EXECUTE FUNCTION public.guard_customer_document_evidence_immutable();


--
-- Name: digitization_jobs digitization_jobs_documents_ready_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER digitization_jobs_documents_ready_guard BEFORE INSERT ON public.digitization_jobs FOR EACH ROW EXECUTE FUNCTION public.guard_digitization_job_documents_ready();


--
-- Name: document_checklist_items document_checklist_items_draft_parent_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER document_checklist_items_draft_parent_guard BEFORE INSERT OR UPDATE ON public.document_checklist_items FOR EACH ROW EXECUTE FUNCTION public.guard_document_checklist_item_draft_parent();


--
-- Name: document_checklist_templates document_checklist_templates_00_catalog_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER document_checklist_templates_00_catalog_guard BEFORE INSERT OR UPDATE ON public.document_checklist_templates FOR EACH ROW EXECUTE FUNCTION public.guard_catalog_publication();


--
-- Name: document_checklist_templates document_checklist_templates_immutable_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER document_checklist_templates_immutable_guard BEFORE UPDATE ON public.document_checklist_templates FOR EACH ROW EXECUTE FUNCTION public.guard_document_checklist_template_immutable();


--
-- Name: financial_events financial_event_insert_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER financial_event_insert_guard BEFORE INSERT ON public.financial_events FOR EACH ROW EXECUTE FUNCTION public.guard_financial_event_insert();


--
-- Name: import_layout_mappings import_layout_mappings_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER import_layout_mappings_00_guard BEFORE INSERT OR UPDATE ON public.import_layout_mappings FOR EACH ROW EXECUTE FUNCTION public.guard_import_layout_mapping();


--
-- Name: import_sources import_sources_financial_semantic_freeze; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER import_sources_financial_semantic_freeze BEFORE UPDATE ON public.import_sources FOR EACH ROW EXECUTE FUNCTION public.freeze_import_source_financial_semantic();


--
-- Name: network_split_rule_versions network_split_rule_versions_freeze_published; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER network_split_rule_versions_freeze_published BEFORE DELETE OR UPDATE ON public.network_split_rule_versions FOR EACH ROW EXECUTE FUNCTION public.freeze_published_commercial_rule();


--
-- Name: network_split_rule_versions network_split_rule_versions_same_org_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER network_split_rule_versions_same_org_guard BEFORE INSERT OR UPDATE ON public.network_split_rule_versions FOR EACH ROW EXECUTE FUNCTION public.assert_same_organization_reference();


--
-- Name: operational_attention_events operational_attention_events_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER operational_attention_events_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.operational_attention_events FOR EACH ROW EXECUTE FUNCTION public.guard_attention_write();


--
-- Name: operational_attention_items operational_attention_items_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER operational_attention_items_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.operational_attention_items FOR EACH ROW EXECUTE FUNCTION public.guard_attention_write();


--
-- Name: organization_admin_events organization_admin_events_00_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER organization_admin_events_00_append_only BEFORE INSERT OR DELETE OR UPDATE ON public.organization_admin_events FOR EACH ROW EXECUTE FUNCTION public.guard_admin_event_write();


--
-- Name: organization_agreements organization_agreements_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER organization_agreements_00_guard BEFORE INSERT OR UPDATE ON public.organization_agreements FOR EACH ROW EXECUTE FUNCTION public.guard_org_catalog_row();


--
-- Name: organization_ai_limits organization_ai_limits_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER organization_ai_limits_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.organization_ai_limits FOR EACH ROW EXECUTE FUNCTION public.guard_ai_write();


--
-- Name: organization_banks organization_banks_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER organization_banks_00_guard BEFORE INSERT OR UPDATE ON public.organization_banks FOR EACH ROW EXECUTE FUNCTION public.guard_org_catalog_row();


--
-- Name: organization_contract_type_settings organization_contract_type_settings_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER organization_contract_type_settings_00_guard BEFORE INSERT OR UPDATE ON public.organization_contract_type_settings FOR EACH ROW EXECUTE FUNCTION public.guard_contract_type_setting();


--
-- Name: organization_invitations organization_invitations_00_governed_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER organization_invitations_00_governed_write BEFORE INSERT OR DELETE OR UPDATE ON public.organization_invitations FOR EACH ROW EXECUTE FUNCTION public.guard_invitation_write();


--
-- Name: organization_memberships organization_memberships_00_governed_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER organization_memberships_00_governed_write BEFORE INSERT OR DELETE OR UPDATE ON public.organization_memberships FOR EACH ROW EXECUTE FUNCTION public.guard_membership_write();


--
-- Name: organization_providers organization_providers_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER organization_providers_00_guard BEFORE INSERT OR UPDATE ON public.organization_providers FOR EACH ROW EXECUTE FUNCTION public.guard_org_catalog_row();


--
-- Name: payout_policies payout_policies_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER payout_policies_00_guard BEFORE INSERT OR UPDATE ON public.payout_policies FOR EACH ROW EXECUTE FUNCTION public.guard_org_catalog_row();


--
-- Name: payout_policies payout_policies_01_token; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER payout_policies_01_token BEFORE INSERT ON public.payout_policies FOR EACH ROW EXECUTE FUNCTION public.guard_payout_write();


--
-- Name: payout_policy_items payout_policy_items_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER payout_policy_items_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.payout_policy_items FOR EACH ROW EXECUTE FUNCTION public.guard_payout_write();


--
-- Name: payout_policy_versions payout_policy_versions_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER payout_policy_versions_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.payout_policy_versions FOR EACH ROW EXECUTE FUNCTION public.guard_payout_write();


--
-- Name: product_table_external_identities product_table_external_identities_same_org_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER product_table_external_identities_same_org_guard BEFORE INSERT OR UPDATE ON public.product_table_external_identities FOR EACH ROW EXECUTE FUNCTION public.assert_same_organization_reference();


--
-- Name: product_table_versions product_table_versions_00_catalog_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER product_table_versions_00_catalog_guard BEFORE INSERT OR UPDATE ON public.product_table_versions FOR EACH ROW EXECUTE FUNCTION public.guard_catalog_publication();


--
-- Name: product_table_versions product_table_versions_immutable_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER product_table_versions_immutable_guard BEFORE UPDATE ON public.product_table_versions FOR EACH ROW EXECUTE FUNCTION public.guard_product_table_version_immutable();


--
-- Name: proposal_commercial_snapshots proposal_commercial_route_insert_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER proposal_commercial_route_insert_guard BEFORE INSERT ON public.proposal_commercial_snapshots FOR EACH ROW EXECUTE FUNCTION public.guard_proposal_commercial_route_insert();


--
-- Name: proposal_commercial_snapshots proposal_commercial_snapshots_same_org_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER proposal_commercial_snapshots_same_org_guard BEFORE INSERT OR UPDATE ON public.proposal_commercial_snapshots FOR EACH ROW EXECUTE FUNCTION public.assert_same_organization_reference();


--
-- Name: proposal_commercial_component_snapshots proposal_component_route_insert_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER proposal_component_route_insert_guard BEFORE INSERT ON public.proposal_commercial_component_snapshots FOR EACH ROW EXECUTE FUNCTION public.guard_proposal_commercial_route_insert();


--
-- Name: proposal_commercial_component_snapshots proposal_component_snapshot_20_seller_commission; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER proposal_component_snapshot_20_seller_commission AFTER INSERT ON public.proposal_commercial_component_snapshots FOR EACH ROW EXECUTE FUNCTION public.snapshot_seller_commission_after_component();


--
-- Name: proposal_document_requirements proposal_document_requirements_snapshot_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER proposal_document_requirements_snapshot_guard BEFORE UPDATE ON public.proposal_document_requirements FOR EACH ROW EXECUTE FUNCTION public.guard_proposal_document_requirement_snapshot();


--
-- Name: proposal_document_requirements proposal_document_requirements_workflow_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER proposal_document_requirements_workflow_guard BEFORE UPDATE ON public.proposal_document_requirements FOR EACH ROW EXECUTE FUNCTION public.guard_proposal_document_requirement_workflow();


--
-- Name: proposal_external_identities proposal_external_identities_same_org_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER proposal_external_identities_same_org_guard BEFORE INSERT OR UPDATE ON public.proposal_external_identities FOR EACH ROW EXECUTE FUNCTION public.assert_same_organization_reference();


--
-- Name: proposal_seller_commission_snapshots proposal_seller_commission_snapshots_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER proposal_seller_commission_snapshots_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.proposal_seller_commission_snapshots FOR EACH ROW EXECUTE FUNCTION public.guard_seller_commission_snapshot();


--
-- Name: proposals_v2 proposals_v2_00_governed_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER proposals_v2_00_governed_write BEFORE INSERT OR UPDATE ON public.proposals_v2 FOR EACH ROW EXECUTE FUNCTION public.guard_proposal_write();


--
-- Name: proposals_v2 proposals_v2_commercial_snapshot_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER proposals_v2_commercial_snapshot_guard BEFORE INSERT OR UPDATE ON public.proposals_v2 FOR EACH ROW EXECUTE FUNCTION public.guard_proposal_commercial_snapshot();


--
-- Name: proposals_v2 proposals_v2_status_transition_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER proposals_v2_status_transition_guard BEFORE UPDATE OF status ON public.proposals_v2 FOR EACH ROW EXECUTE FUNCTION public.guard_proposal_status_transition();


--
-- Name: seller_addresses seller_addresses_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER seller_addresses_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.seller_addresses FOR EACH ROW EXECUTE FUNCTION public.guard_seller_profile_write();


--
-- Name: seller_bank_aliases seller_bank_aliases_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER seller_bank_aliases_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.seller_bank_aliases FOR EACH ROW EXECUTE FUNCTION public.guard_seller_bank_alias();


--
-- Name: seller_certifications seller_certifications_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER seller_certifications_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.seller_certifications FOR EACH ROW EXECUTE FUNCTION public.guard_seller_profile_write();


--
-- Name: seller_groups seller_groups_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER seller_groups_00_guard BEFORE INSERT OR UPDATE ON public.seller_groups FOR EACH ROW EXECUTE FUNCTION public.guard_seller_catalog_row();


--
-- Name: seller_payment_accounts seller_payment_accounts_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER seller_payment_accounts_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.seller_payment_accounts FOR EACH ROW EXECUTE FUNCTION public.guard_seller_profile_write();


--
-- Name: seller_profiles seller_profiles_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER seller_profiles_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.seller_profiles FOR EACH ROW EXECUTE FUNCTION public.guard_seller_profile_write();


--
-- Name: seller_sub_rule_versions seller_sub_rule_versions_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER seller_sub_rule_versions_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.seller_sub_rule_versions FOR EACH ROW EXECUTE FUNCTION public.guard_seller_sub_rule();


--
-- Name: seller_supervisions seller_supervisions_00_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER seller_supervisions_00_guard BEFORE INSERT OR DELETE OR UPDATE ON public.seller_supervisions FOR EACH ROW EXECUTE FUNCTION public.guard_seller_supervision();


--
-- Name: simulations simulations_00_governed_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER simulations_00_governed_write BEFORE INSERT OR DELETE OR UPDATE ON public.simulations FOR EACH ROW EXECUTE FUNCTION public.guard_simulation_write();


--
-- Name: simulations simulations_selected_immutable_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER simulations_selected_immutable_guard BEFORE UPDATE ON public.simulations FOR EACH ROW EXECUTE FUNCTION public.guard_simulation_selected_immutable();


--
-- Name: customer_timeline_events trg_customer_timeline_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_customer_timeline_write BEFORE INSERT OR UPDATE ON public.customer_timeline_events FOR EACH ROW EXECUTE FUNCTION public.guard_customer_timeline_write();


--
-- Name: digitization_jobs trg_digitization_jobs_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_digitization_jobs_write BEFORE INSERT OR UPDATE ON public.digitization_jobs FOR EACH ROW EXECUTE FUNCTION public.guard_operational_pipeline_write();


--
-- Name: import_batches trg_import_batch_adapter_contract; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_import_batch_adapter_contract BEFORE INSERT OR UPDATE OF adapter_id, adapter_contract_version ON public.import_batches FOR EACH ROW EXECUTE FUNCTION public.guard_import_batch_adapter_contract();


--
-- Name: import_batches trg_import_batch_adapter_write_once; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_import_batch_adapter_write_once BEFORE UPDATE OF adapter_id, adapter_contract_version ON public.import_batches FOR EACH ROW EXECUTE FUNCTION public.guard_import_batch_adapter_write_once();


--
-- Name: import_conflict_rows trg_import_conflict_row_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_import_conflict_row_write BEFORE INSERT ON public.import_conflict_rows FOR EACH ROW EXECUTE FUNCTION public.guard_import_conflict_row_write();


--
-- Name: import_conflicts trg_import_conflict_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_import_conflict_write BEFORE INSERT OR UPDATE ON public.import_conflicts FOR EACH ROW EXECUTE FUNCTION public.guard_import_conflict_write();


--
-- Name: import_match_candidates trg_import_match_candidate_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_import_match_candidate_insert BEFORE INSERT ON public.import_match_candidates FOR EACH ROW EXECUTE FUNCTION public.guard_import_match_candidate_insert();


--
-- Name: import_normalized_rows trg_import_normalized_row_consistency; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_import_normalized_row_consistency BEFORE INSERT OR UPDATE ON public.import_normalized_rows FOR EACH ROW EXECUTE FUNCTION public.guard_import_normalized_row_consistency();


--
-- Name: import_raw_rows trg_import_raw_row_immutable; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_import_raw_row_immutable BEFORE DELETE OR UPDATE ON public.import_raw_rows FOR EACH ROW EXECUTE FUNCTION public.guard_import_raw_row_immutable();


--
-- Name: integration_run_artifacts trg_integration_artifact_consistency; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_integration_artifact_consistency BEFORE INSERT OR UPDATE ON public.integration_run_artifacts FOR EACH ROW EXECUTE FUNCTION public.guard_integration_artifact_consistency();


--
-- Name: integration_run_artifacts trg_integration_artifact_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_integration_artifact_write BEFORE INSERT OR DELETE OR UPDATE ON public.integration_run_artifacts FOR EACH ROW EXECUTE FUNCTION public.guard_integration_artifact_write();


--
-- Name: integration_source_bindings trg_integration_binding_no_secrets; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_integration_binding_no_secrets BEFORE INSERT OR UPDATE ON public.integration_source_bindings FOR EACH ROW EXECUTE FUNCTION public.guard_integration_binding_no_secrets();


--
-- Name: integration_runs trg_integration_run_consistency; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_integration_run_consistency BEFORE INSERT OR UPDATE ON public.integration_runs FOR EACH ROW EXECUTE FUNCTION public.guard_integration_run_consistency();


--
-- Name: integration_runs trg_integration_run_state; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_integration_run_state BEFORE INSERT OR DELETE OR UPDATE ON public.integration_runs FOR EACH ROW EXECUTE FUNCTION public.guard_integration_run_state();


--
-- Name: operational_cases trg_operational_cases_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_operational_cases_write BEFORE INSERT OR UPDATE ON public.operational_cases FOR EACH ROW EXECUTE FUNCTION public.guard_operational_pipeline_write();


--
-- Name: operational_events trg_operational_events_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_operational_events_write BEFORE INSERT OR UPDATE ON public.operational_events FOR EACH ROW EXECUTE FUNCTION public.guard_operational_pipeline_write();


--
-- Name: financial_reconciliation_cases trg_reconciliation_case_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_reconciliation_case_write BEFORE INSERT OR UPDATE ON public.financial_reconciliation_cases FOR EACH ROW EXECUTE FUNCTION public.guard_reconciliation_case_write();


--
-- Name: agreements agreements_bank_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.agreements
    ADD CONSTRAINT agreements_bank_id_fkey FOREIGN KEY (bank_id) REFERENCES public.banks(id) ON DELETE RESTRICT;


--
-- Name: ai_credit_ledger ai_credit_ledger_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_credit_ledger
    ADD CONSTRAINT ai_credit_ledger_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: ai_credit_ledger ai_credit_ledger_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_credit_ledger
    ADD CONSTRAINT ai_credit_ledger_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: ai_credit_ledger ai_credit_ledger_organization_id_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_credit_ledger
    ADD CONSTRAINT ai_credit_ledger_organization_id_job_id_fkey FOREIGN KEY (organization_id, job_id) REFERENCES public.ai_usage_jobs(organization_id, id) ON DELETE RESTRICT;


--
-- Name: ai_usage_events ai_usage_events_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_usage_events
    ADD CONSTRAINT ai_usage_events_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: ai_usage_events ai_usage_events_organization_id_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_usage_events
    ADD CONSTRAINT ai_usage_events_organization_id_job_id_fkey FOREIGN KEY (organization_id, job_id) REFERENCES public.ai_usage_jobs(organization_id, id) ON DELETE RESTRICT;


--
-- Name: ai_usage_jobs ai_usage_jobs_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_usage_jobs
    ADD CONSTRAINT ai_usage_jobs_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: ai_usage_jobs ai_usage_jobs_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ai_usage_jobs
    ADD CONSTRAINT ai_usage_jobs_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: channel_commission_rule_versions channel_commission_rule_versions_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_commission_rule_versions
    ADD CONSTRAINT channel_commission_rule_versions_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.commercial_channels(id);


--
-- Name: channel_commission_rule_versions channel_commission_rule_versions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_commission_rule_versions
    ADD CONSTRAINT channel_commission_rule_versions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: channel_commission_rule_versions channel_commission_rule_versions_product_table_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.channel_commission_rule_versions
    ADD CONSTRAINT channel_commission_rule_versions_product_table_id_fkey FOREIGN KEY (product_table_id) REFERENCES public.product_tables(id);


--
-- Name: clients clients_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.clients
    ADD CONSTRAINT clients_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: commercial_channels commercial_channels_bank_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_channels
    ADD CONSTRAINT commercial_channels_bank_id_fkey FOREIGN KEY (bank_id) REFERENCES public.banks(id);


--
-- Name: commercial_channels commercial_channels_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_channels
    ADD CONSTRAINT commercial_channels_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: commercial_channels commercial_channels_payer_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_channels
    ADD CONSTRAINT commercial_channels_payer_entity_id_fkey FOREIGN KEY (payer_entity_id) REFERENCES public.commercial_entities(id);


--
-- Name: commercial_channels commercial_channels_relationship_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_channels
    ADD CONSTRAINT commercial_channels_relationship_id_fkey FOREIGN KEY (relationship_id) REFERENCES public.commercial_relationships(id);


--
-- Name: commercial_condition_commissions commercial_condition_commissi_organization_id_condition_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_commissions
    ADD CONSTRAINT commercial_condition_commissi_organization_id_condition_id_fkey FOREIGN KEY (organization_id, condition_id) REFERENCES public.commercial_conditions(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commercial_condition_commissions commercial_condition_commissi_organization_id_policy_versi_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_commissions
    ADD CONSTRAINT commercial_condition_commissi_organization_id_policy_versi_fkey FOREIGN KEY (organization_id, policy_version_id) REFERENCES public.payout_policy_versions(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commercial_condition_commissions commercial_condition_commissions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_commissions
    ADD CONSTRAINT commercial_condition_commissions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: commercial_condition_component_policy commercial_condition_compone_organization_id_condition_id_fkey1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_component_policy
    ADD CONSTRAINT commercial_condition_compone_organization_id_condition_id_fkey1 FOREIGN KEY (organization_id, condition_id) REFERENCES public.commercial_conditions(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commercial_condition_components commercial_condition_componen_organization_id_condition_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_components
    ADD CONSTRAINT commercial_condition_componen_organization_id_condition_id_fkey FOREIGN KEY (organization_id, condition_id) REFERENCES public.commercial_conditions(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commercial_condition_component_policy commercial_condition_componen_organization_id_policy_versi_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_component_policy
    ADD CONSTRAINT commercial_condition_componen_organization_id_policy_versi_fkey FOREIGN KEY (organization_id, policy_version_id) REFERENCES public.component_payout_policy_versions(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commercial_condition_component_policy commercial_condition_component_policy_attached_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_component_policy
    ADD CONSTRAINT commercial_condition_component_policy_attached_by_fkey FOREIGN KEY (attached_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: commercial_condition_component_policy commercial_condition_component_policy_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_component_policy
    ADD CONSTRAINT commercial_condition_component_policy_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: commercial_condition_components commercial_condition_components_component_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_components
    ADD CONSTRAINT commercial_condition_components_component_type_id_fkey FOREIGN KEY (component_type_id) REFERENCES public.commission_component_types(id) ON DELETE RESTRICT;


--
-- Name: commercial_condition_components commercial_condition_components_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_components
    ADD CONSTRAINT commercial_condition_components_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: commercial_condition_components commercial_condition_components_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_components
    ADD CONSTRAINT commercial_condition_components_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: commercial_condition_shares commercial_condition_shares_organization_id_condition_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_shares
    ADD CONSTRAINT commercial_condition_shares_organization_id_condition_id_fkey FOREIGN KEY (organization_id, condition_id) REFERENCES public.commercial_conditions(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commercial_condition_shares commercial_condition_shares_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_shares
    ADD CONSTRAINT commercial_condition_shares_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: commercial_condition_shares commercial_condition_shares_organization_id_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_shares
    ADD CONSTRAINT commercial_condition_shares_organization_id_group_id_fkey FOREIGN KEY (organization_id, group_id) REFERENCES public.commission_groups(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commercial_condition_shares commercial_condition_shares_organization_id_policy_version_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_condition_shares
    ADD CONSTRAINT commercial_condition_shares_organization_id_policy_version_fkey FOREIGN KEY (organization_id, policy_version_id) REFERENCES public.payout_policy_versions(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commercial_conditions commercial_conditions_contract_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_conditions
    ADD CONSTRAINT commercial_conditions_contract_type_id_fkey FOREIGN KEY (contract_type_id) REFERENCES public.contract_types(id) ON DELETE RESTRICT;


--
-- Name: commercial_conditions commercial_conditions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_conditions
    ADD CONSTRAINT commercial_conditions_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: commercial_conditions commercial_conditions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_conditions
    ADD CONSTRAINT commercial_conditions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: commercial_conditions commercial_conditions_organization_id_product_table_versio_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_conditions
    ADD CONSTRAINT commercial_conditions_organization_id_product_table_versio_fkey FOREIGN KEY (organization_id, product_table_version_id) REFERENCES public.product_table_versions(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commercial_entities commercial_entities_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_entities
    ADD CONSTRAINT commercial_entities_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: commercial_factor_batches commercial_factor_batches_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_batches
    ADD CONSTRAINT commercial_factor_batches_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: commercial_factor_batches commercial_factor_batches_import_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_batches
    ADD CONSTRAINT commercial_factor_batches_import_batch_id_fkey FOREIGN KEY (import_batch_id) REFERENCES public.import_batches(id) ON DELETE RESTRICT;


--
-- Name: commercial_factor_batches commercial_factor_batches_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_batches
    ADD CONSTRAINT commercial_factor_batches_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: commercial_factor_batches commercial_factor_batches_organization_id_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_batches
    ADD CONSTRAINT commercial_factor_batches_organization_id_profile_id_fkey FOREIGN KEY (organization_id, profile_id) REFERENCES public.commercial_factor_profiles(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commercial_factor_entries commercial_factor_entries_organization_id_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_entries
    ADD CONSTRAINT commercial_factor_entries_organization_id_batch_id_fkey FOREIGN KEY (organization_id, batch_id) REFERENCES public.commercial_factor_batches(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commercial_factor_entries commercial_factor_entries_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_entries
    ADD CONSTRAINT commercial_factor_entries_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: commercial_factor_profiles commercial_factor_profiles_contract_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_profiles
    ADD CONSTRAINT commercial_factor_profiles_contract_type_id_fkey FOREIGN KEY (contract_type_id) REFERENCES public.contract_types(id) ON DELETE RESTRICT;


--
-- Name: commercial_factor_profiles commercial_factor_profiles_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_profiles
    ADD CONSTRAINT commercial_factor_profiles_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: commercial_factor_profiles commercial_factor_profiles_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_profiles
    ADD CONSTRAINT commercial_factor_profiles_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: commercial_factor_profiles commercial_factor_profiles_organization_id_org_agreement_i_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_profiles
    ADD CONSTRAINT commercial_factor_profiles_organization_id_org_agreement_i_fkey FOREIGN KEY (organization_id, org_agreement_id) REFERENCES public.organization_agreements(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commercial_factor_profiles commercial_factor_profiles_organization_id_org_bank_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_profiles
    ADD CONSTRAINT commercial_factor_profiles_organization_id_org_bank_id_fkey FOREIGN KEY (organization_id, org_bank_id) REFERENCES public.organization_banks(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commercial_factor_profiles commercial_factor_profiles_organization_id_product_table_i_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_factor_profiles
    ADD CONSTRAINT commercial_factor_profiles_organization_id_product_table_i_fkey FOREIGN KEY (organization_id, product_table_id) REFERENCES public.product_tables(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commercial_relationships commercial_relationships_bank_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_relationships
    ADD CONSTRAINT commercial_relationships_bank_id_fkey FOREIGN KEY (bank_id) REFERENCES public.banks(id);


--
-- Name: commercial_relationships commercial_relationships_downstream_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_relationships
    ADD CONSTRAINT commercial_relationships_downstream_entity_id_fkey FOREIGN KEY (downstream_entity_id) REFERENCES public.commercial_entities(id);


--
-- Name: commercial_relationships commercial_relationships_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_relationships
    ADD CONSTRAINT commercial_relationships_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: commercial_relationships commercial_relationships_upstream_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_relationships
    ADD CONSTRAINT commercial_relationships_upstream_entity_id_fkey FOREIGN KEY (upstream_entity_id) REFERENCES public.commercial_entities(id);


--
-- Name: commercial_sellers commercial_sellers_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_sellers
    ADD CONSTRAINT commercial_sellers_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: commercial_sellers commercial_sellers_org_branch_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_sellers
    ADD CONSTRAINT commercial_sellers_org_branch_fk FOREIGN KEY (organization_id, branch_id) REFERENCES public.organization_branches(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commercial_sellers commercial_sellers_org_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_sellers
    ADD CONSTRAINT commercial_sellers_org_user_fk FOREIGN KEY (organization_id, user_id) REFERENCES public.organization_memberships(organization_id, user_id) ON DELETE RESTRICT;


--
-- Name: commercial_sellers commercial_sellers_organization_id_commission_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_sellers
    ADD CONSTRAINT commercial_sellers_organization_id_commission_group_id_fkey FOREIGN KEY (organization_id, commission_group_id) REFERENCES public.commission_groups(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commercial_sellers commercial_sellers_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_sellers
    ADD CONSTRAINT commercial_sellers_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: commercial_sellers commercial_sellers_organization_id_seller_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_sellers
    ADD CONSTRAINT commercial_sellers_organization_id_seller_group_id_fkey FOREIGN KEY (organization_id, seller_group_id) REFERENCES public.seller_groups(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commission_group_component_limits commission_group_component_limits_component_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_group_component_limits
    ADD CONSTRAINT commission_group_component_limits_component_type_id_fkey FOREIGN KEY (component_type_id) REFERENCES public.commission_component_types(id) ON DELETE RESTRICT;


--
-- Name: commission_group_component_limits commission_group_component_limits_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_group_component_limits
    ADD CONSTRAINT commission_group_component_limits_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: commission_group_component_limits commission_group_component_limits_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_group_component_limits
    ADD CONSTRAINT commission_group_component_limits_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: commission_group_component_limits commission_group_component_limits_organization_id_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_group_component_limits
    ADD CONSTRAINT commission_group_component_limits_organization_id_group_id_fkey FOREIGN KEY (organization_id, group_id) REFERENCES public.commission_groups(organization_id, id) ON DELETE RESTRICT;


--
-- Name: commission_group_component_limits commission_group_component_limits_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_group_component_limits
    ADD CONSTRAINT commission_group_component_limits_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: commission_groups commission_groups_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_groups
    ADD CONSTRAINT commission_groups_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: commission_groups commission_groups_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_groups
    ADD CONSTRAINT commission_groups_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: commission_rule_components commission_rule_components_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_rule_components
    ADD CONSTRAINT commission_rule_components_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: commission_rule_components commission_rule_components_rule_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commission_rule_components
    ADD CONSTRAINT commission_rule_components_rule_version_id_fkey FOREIGN KEY (rule_version_id) REFERENCES public.channel_commission_rule_versions(id);


--
-- Name: component_payout_policies component_payout_policies_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policies
    ADD CONSTRAINT component_payout_policies_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: component_payout_policies component_payout_policies_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policies
    ADD CONSTRAINT component_payout_policies_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: component_payout_policies component_payout_policies_organization_id_org_agreement_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policies
    ADD CONSTRAINT component_payout_policies_organization_id_org_agreement_id_fkey FOREIGN KEY (organization_id, org_agreement_id) REFERENCES public.organization_agreements(organization_id, id) ON DELETE RESTRICT;


--
-- Name: component_payout_policies component_payout_policies_organization_id_org_bank_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policies
    ADD CONSTRAINT component_payout_policies_organization_id_org_bank_id_fkey FOREIGN KEY (organization_id, org_bank_id) REFERENCES public.organization_banks(organization_id, id) ON DELETE RESTRICT;


--
-- Name: component_payout_policies component_payout_policies_organization_id_product_table_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policies
    ADD CONSTRAINT component_payout_policies_organization_id_product_table_id_fkey FOREIGN KEY (organization_id, product_table_id) REFERENCES public.product_tables(organization_id, id) ON DELETE RESTRICT;


--
-- Name: component_payout_policy_items component_payout_policy_items_component_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policy_items
    ADD CONSTRAINT component_payout_policy_items_component_type_id_fkey FOREIGN KEY (component_type_id) REFERENCES public.commission_component_types(id) ON DELETE RESTRICT;


--
-- Name: component_payout_policy_items component_payout_policy_items_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policy_items
    ADD CONSTRAINT component_payout_policy_items_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: component_payout_policy_items component_payout_policy_items_organization_id_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policy_items
    ADD CONSTRAINT component_payout_policy_items_organization_id_group_id_fkey FOREIGN KEY (organization_id, group_id) REFERENCES public.commission_groups(organization_id, id) ON DELETE RESTRICT;


--
-- Name: component_payout_policy_items component_payout_policy_items_organization_id_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policy_items
    ADD CONSTRAINT component_payout_policy_items_organization_id_version_id_fkey FOREIGN KEY (organization_id, version_id) REFERENCES public.component_payout_policy_versions(organization_id, id) ON DELETE RESTRICT;


--
-- Name: component_payout_policy_versions component_payout_policy_versions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policy_versions
    ADD CONSTRAINT component_payout_policy_versions_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: component_payout_policy_versions component_payout_policy_versions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policy_versions
    ADD CONSTRAINT component_payout_policy_versions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: component_payout_policy_versions component_payout_policy_versions_organization_id_policy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.component_payout_policy_versions
    ADD CONSTRAINT component_payout_policy_versions_organization_id_policy_id_fkey FOREIGN KEY (organization_id, policy_id) REFERENCES public.component_payout_policies(organization_id, id) ON DELETE RESTRICT;


--
-- Name: contract_types contract_types_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_types
    ADD CONSTRAINT contract_types_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: contract_types contract_types_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contract_types
    ADD CONSTRAINT contract_types_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: contracts contracts_client_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contracts
    ADD CONSTRAINT contracts_client_id_fkey FOREIGN KEY (client_id) REFERENCES public.clients(id) ON DELETE CASCADE;


--
-- Name: contracts contracts_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contracts
    ADD CONSTRAINT contracts_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: contracts contracts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contracts
    ADD CONSTRAINT contracts_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: customer_addresses customer_addresses_customer_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_addresses
    ADD CONSTRAINT customer_addresses_customer_tenant_fk FOREIGN KEY (organization_id, customer_id) REFERENCES public.clients(organization_id, id) ON DELETE RESTRICT;


--
-- Name: customer_addresses customer_addresses_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_addresses
    ADD CONSTRAINT customer_addresses_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: customer_bank_accounts customer_bank_accounts_customer_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_bank_accounts
    ADD CONSTRAINT customer_bank_accounts_customer_tenant_fk FOREIGN KEY (organization_id, customer_id) REFERENCES public.clients(organization_id, id) ON DELETE RESTRICT;


--
-- Name: customer_bank_accounts customer_bank_accounts_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_bank_accounts
    ADD CONSTRAINT customer_bank_accounts_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: customer_documents customer_documents_customer_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_documents
    ADD CONSTRAINT customer_documents_customer_tenant_fk FOREIGN KEY (organization_id, customer_id) REFERENCES public.clients(organization_id, id) ON DELETE RESTRICT;


--
-- Name: customer_documents customer_documents_document_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_documents
    ADD CONSTRAINT customer_documents_document_type_id_fkey FOREIGN KEY (document_type_id) REFERENCES public.document_types(id) ON DELETE RESTRICT;


--
-- Name: customer_documents customer_documents_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_documents
    ADD CONSTRAINT customer_documents_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: customer_documents customer_documents_uploaded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_documents
    ADD CONSTRAINT customer_documents_uploaded_by_fkey FOREIGN KEY (uploaded_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: customer_pix_keys customer_pix_keys_bank_account_customer_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_pix_keys
    ADD CONSTRAINT customer_pix_keys_bank_account_customer_fk FOREIGN KEY (organization_id, customer_id, bank_account_id) REFERENCES public.customer_bank_accounts(organization_id, customer_id, id) ON DELETE RESTRICT;


--
-- Name: customer_pix_keys customer_pix_keys_customer_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_pix_keys
    ADD CONSTRAINT customer_pix_keys_customer_tenant_fk FOREIGN KEY (organization_id, customer_id) REFERENCES public.clients(organization_id, id) ON DELETE RESTRICT;


--
-- Name: customer_pix_keys customer_pix_keys_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_pix_keys
    ADD CONSTRAINT customer_pix_keys_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: customer_timeline_events customer_timeline_customer_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_timeline_events
    ADD CONSTRAINT customer_timeline_customer_tenant_fk FOREIGN KEY (organization_id, customer_id) REFERENCES public.clients(organization_id, id) ON DELETE RESTRICT;


--
-- Name: customer_timeline_events customer_timeline_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_timeline_events
    ADD CONSTRAINT customer_timeline_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: customer_timeline_events customer_timeline_events_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_timeline_events
    ADD CONSTRAINT customer_timeline_events_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: digitization_jobs digitization_jobs_assigned_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.digitization_jobs
    ADD CONSTRAINT digitization_jobs_assigned_to_fkey FOREIGN KEY (assigned_to) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: digitization_jobs digitization_jobs_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.digitization_jobs
    ADD CONSTRAINT digitization_jobs_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: digitization_jobs digitization_jobs_proposal_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.digitization_jobs
    ADD CONSTRAINT digitization_jobs_proposal_tenant_fk FOREIGN KEY (organization_id, proposal_id) REFERENCES public.proposals_v2(organization_id, id) ON DELETE RESTRICT;


--
-- Name: document_checklist_items document_checklist_items_document_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_checklist_items
    ADD CONSTRAINT document_checklist_items_document_type_id_fkey FOREIGN KEY (document_type_id) REFERENCES public.document_types(id) ON DELETE RESTRICT;


--
-- Name: document_checklist_items document_checklist_items_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_checklist_items
    ADD CONSTRAINT document_checklist_items_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: document_checklist_items document_checklist_items_template_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_checklist_items
    ADD CONSTRAINT document_checklist_items_template_tenant_fk FOREIGN KEY (organization_id, template_id) REFERENCES public.document_checklist_templates(organization_id, id) ON DELETE RESTRICT;


--
-- Name: document_checklist_templates document_checklist_templates_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_checklist_templates
    ADD CONSTRAINT document_checklist_templates_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: document_checklist_templates document_checklist_templates_route_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_checklist_templates
    ADD CONSTRAINT document_checklist_templates_route_tenant_fk FOREIGN KEY (organization_id, route_id) REFERENCES public.organization_product_routes(organization_id, id) ON DELETE RESTRICT;


--
-- Name: financial_events financial_events_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_events
    ADD CONSTRAINT financial_events_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.commercial_channels(id);


--
-- Name: financial_events financial_events_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_events
    ADD CONSTRAINT financial_events_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: financial_events financial_events_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_events
    ADD CONSTRAINT financial_events_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: financial_events financial_events_payer_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_events
    ADD CONSTRAINT financial_events_payer_entity_id_fkey FOREIGN KEY (payer_entity_id) REFERENCES public.commercial_entities(id);


--
-- Name: financial_events financial_events_producer_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_events
    ADD CONSTRAINT financial_events_producer_entity_id_fkey FOREIGN KEY (producer_entity_id) REFERENCES public.commercial_entities(id);


--
-- Name: financial_events financial_events_proposal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_events
    ADD CONSTRAINT financial_events_proposal_id_fkey FOREIGN KEY (proposal_id) REFERENCES public.proposals_v2(id);


--
-- Name: financial_events financial_events_reverses_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_events
    ADD CONSTRAINT financial_events_reverses_event_id_fkey FOREIGN KEY (reverses_event_id) REFERENCES public.financial_events(id);


--
-- Name: financial_evidence_links financial_evidence_links_financial_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_evidence_links
    ADD CONSTRAINT financial_evidence_links_financial_event_id_fkey FOREIGN KEY (financial_event_id) REFERENCES public.financial_events(id);


--
-- Name: financial_evidence_links financial_evidence_links_import_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_evidence_links
    ADD CONSTRAINT financial_evidence_links_import_batch_id_fkey FOREIGN KEY (import_batch_id) REFERENCES public.import_batches(id);


--
-- Name: financial_evidence_links financial_evidence_links_import_decision_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_evidence_links
    ADD CONSTRAINT financial_evidence_links_import_decision_id_fkey FOREIGN KEY (import_decision_id) REFERENCES public.import_decisions(id);


--
-- Name: financial_evidence_links financial_evidence_links_import_raw_row_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_evidence_links
    ADD CONSTRAINT financial_evidence_links_import_raw_row_id_fkey FOREIGN KEY (import_raw_row_id) REFERENCES public.import_raw_rows(id);


--
-- Name: financial_evidence_links financial_evidence_links_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_evidence_links
    ADD CONSTRAINT financial_evidence_links_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: financial_reconciliation_cases financial_reconciliation_cases_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_reconciliation_cases
    ADD CONSTRAINT financial_reconciliation_cases_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.commercial_channels(id);


--
-- Name: financial_reconciliation_cases financial_reconciliation_cases_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_reconciliation_cases
    ADD CONSTRAINT financial_reconciliation_cases_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: financial_reconciliation_cases financial_reconciliation_cases_proposal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_reconciliation_cases
    ADD CONSTRAINT financial_reconciliation_cases_proposal_id_fkey FOREIGN KEY (proposal_id) REFERENCES public.proposals_v2(id);


--
-- Name: financial_reconciliation_cases financial_reconciliation_cases_resolved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.financial_reconciliation_cases
    ADD CONSTRAINT financial_reconciliation_cases_resolved_by_fkey FOREIGN KEY (resolved_by) REFERENCES auth.users(id);


--
-- Name: import_applied_decisions import_applied_decisions_applied_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_applied_decisions
    ADD CONSTRAINT import_applied_decisions_applied_by_fkey FOREIGN KEY (applied_by) REFERENCES auth.users(id);


--
-- Name: import_applied_decisions import_applied_decisions_decision_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_applied_decisions
    ADD CONSTRAINT import_applied_decisions_decision_id_fkey FOREIGN KEY (decision_id) REFERENCES public.import_decisions(id);


--
-- Name: import_applied_decisions import_applied_decisions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_applied_decisions
    ADD CONSTRAINT import_applied_decisions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: import_applied_decisions import_applied_decisions_proposal_external_identity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_applied_decisions
    ADD CONSTRAINT import_applied_decisions_proposal_external_identity_id_fkey FOREIGN KEY (proposal_external_identity_id) REFERENCES public.proposal_external_identities(id);


--
-- Name: import_applied_decisions import_applied_decisions_table_external_identity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_applied_decisions
    ADD CONSTRAINT import_applied_decisions_table_external_identity_id_fkey FOREIGN KEY (table_external_identity_id) REFERENCES public.product_table_external_identities(id);


--
-- Name: import_batches import_batches_adapter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_batches
    ADD CONSTRAINT import_batches_adapter_id_fkey FOREIGN KEY (adapter_id) REFERENCES public.integration_adapters(id);


--
-- Name: import_batches import_batches_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_batches
    ADD CONSTRAINT import_batches_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: import_batches import_batches_received_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_batches
    ADD CONSTRAINT import_batches_received_by_fkey FOREIGN KEY (received_by) REFERENCES auth.users(id);


--
-- Name: import_batches import_batches_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_batches
    ADD CONSTRAINT import_batches_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.import_sources(id);


--
-- Name: import_conflict_rows import_conflict_rows_conflict_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_conflict_rows
    ADD CONSTRAINT import_conflict_rows_conflict_id_fkey FOREIGN KEY (conflict_id) REFERENCES public.import_conflicts(id) ON DELETE RESTRICT;


--
-- Name: import_conflict_rows import_conflict_rows_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_conflict_rows
    ADD CONSTRAINT import_conflict_rows_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: import_conflict_rows import_conflict_rows_raw_row_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_conflict_rows
    ADD CONSTRAINT import_conflict_rows_raw_row_id_fkey FOREIGN KEY (raw_row_id) REFERENCES public.import_raw_rows(id);


--
-- Name: import_conflicts import_conflicts_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_conflicts
    ADD CONSTRAINT import_conflicts_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.import_batches(id);


--
-- Name: import_conflicts import_conflicts_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_conflicts
    ADD CONSTRAINT import_conflicts_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: import_conflicts import_conflicts_resolved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_conflicts
    ADD CONSTRAINT import_conflicts_resolved_by_fkey FOREIGN KEY (resolved_by) REFERENCES auth.users(id);


--
-- Name: import_decisions import_decisions_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_decisions
    ADD CONSTRAINT import_decisions_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.import_batches(id);


--
-- Name: import_decisions import_decisions_candidate_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_decisions
    ADD CONSTRAINT import_decisions_candidate_id_fkey FOREIGN KEY (candidate_id) REFERENCES public.import_match_candidates(id);


--
-- Name: import_decisions import_decisions_decided_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_decisions
    ADD CONSTRAINT import_decisions_decided_by_fkey FOREIGN KEY (decided_by) REFERENCES auth.users(id);


--
-- Name: import_decisions import_decisions_normalized_row_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_decisions
    ADD CONSTRAINT import_decisions_normalized_row_id_fkey FOREIGN KEY (normalized_row_id) REFERENCES public.import_normalized_rows(id);


--
-- Name: import_decisions import_decisions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_decisions
    ADD CONSTRAINT import_decisions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: import_jobs import_jobs_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_jobs
    ADD CONSTRAINT import_jobs_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: import_layout_mappings import_layout_mappings_confirmed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_layout_mappings
    ADD CONSTRAINT import_layout_mappings_confirmed_by_fkey FOREIGN KEY (confirmed_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: import_layout_mappings import_layout_mappings_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_layout_mappings
    ADD CONSTRAINT import_layout_mappings_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: import_match_candidates import_match_candidates_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_match_candidates
    ADD CONSTRAINT import_match_candidates_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.commercial_channels(id);


--
-- Name: import_match_candidates import_match_candidates_normalized_row_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_match_candidates
    ADD CONSTRAINT import_match_candidates_normalized_row_id_fkey FOREIGN KEY (normalized_row_id) REFERENCES public.import_normalized_rows(id);


--
-- Name: import_match_candidates import_match_candidates_org_seller_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_match_candidates
    ADD CONSTRAINT import_match_candidates_org_seller_fk FOREIGN KEY (organization_id, seller_id) REFERENCES public.commercial_sellers(organization_id, id) ON DELETE RESTRICT;


--
-- Name: import_match_candidates import_match_candidates_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_match_candidates
    ADD CONSTRAINT import_match_candidates_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: import_match_candidates import_match_candidates_producer_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_match_candidates
    ADD CONSTRAINT import_match_candidates_producer_entity_id_fkey FOREIGN KEY (producer_entity_id) REFERENCES public.commercial_entities(id);


--
-- Name: import_match_candidates import_match_candidates_product_table_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_match_candidates
    ADD CONSTRAINT import_match_candidates_product_table_id_fkey FOREIGN KEY (product_table_id) REFERENCES public.product_tables(id);


--
-- Name: import_match_candidates import_match_candidates_proposal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_match_candidates
    ADD CONSTRAINT import_match_candidates_proposal_id_fkey FOREIGN KEY (proposal_id) REFERENCES public.proposals_v2(id);


--
-- Name: import_normalized_rows import_normalized_rows_org_seller_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_normalized_rows
    ADD CONSTRAINT import_normalized_rows_org_seller_fk FOREIGN KEY (organization_id, resolved_seller_id) REFERENCES public.commercial_sellers(organization_id, id) ON DELETE RESTRICT;


--
-- Name: import_normalized_rows import_normalized_rows_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_normalized_rows
    ADD CONSTRAINT import_normalized_rows_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: import_normalized_rows import_normalized_rows_raw_row_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_normalized_rows
    ADD CONSTRAINT import_normalized_rows_raw_row_id_fkey FOREIGN KEY (raw_row_id) REFERENCES public.import_raw_rows(id);


--
-- Name: import_raw_rows import_raw_rows_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_raw_rows
    ADD CONSTRAINT import_raw_rows_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.import_batches(id);


--
-- Name: import_raw_rows import_raw_rows_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_raw_rows
    ADD CONSTRAINT import_raw_rows_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: import_sources import_sources_financial_semantic_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_sources
    ADD CONSTRAINT import_sources_financial_semantic_reviewed_by_fkey FOREIGN KEY (financial_semantic_reviewed_by) REFERENCES auth.users(id);


--
-- Name: import_sources import_sources_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_sources
    ADD CONSTRAINT import_sources_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: import_sources import_sources_source_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_sources
    ADD CONSTRAINT import_sources_source_entity_id_fkey FOREIGN KEY (source_entity_id) REFERENCES public.commercial_entities(id);


--
-- Name: integration_field_mappings integration_field_mappings_adapter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_field_mappings
    ADD CONSTRAINT integration_field_mappings_adapter_id_fkey FOREIGN KEY (adapter_id) REFERENCES public.integration_adapters(id);


--
-- Name: integration_run_artifacts integration_run_artifacts_import_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_run_artifacts
    ADD CONSTRAINT integration_run_artifacts_import_batch_id_fkey FOREIGN KEY (import_batch_id) REFERENCES public.import_batches(id);


--
-- Name: integration_run_artifacts integration_run_artifacts_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_run_artifacts
    ADD CONSTRAINT integration_run_artifacts_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: integration_run_artifacts integration_run_artifacts_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_run_artifacts
    ADD CONSTRAINT integration_run_artifacts_run_id_fkey FOREIGN KEY (run_id) REFERENCES public.integration_runs(id) ON DELETE RESTRICT;


--
-- Name: integration_runs integration_runs_adapter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_runs
    ADD CONSTRAINT integration_runs_adapter_id_fkey FOREIGN KEY (adapter_id) REFERENCES public.integration_adapters(id);


--
-- Name: integration_runs integration_runs_binding_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_runs
    ADD CONSTRAINT integration_runs_binding_id_fkey FOREIGN KEY (binding_id) REFERENCES public.integration_source_bindings(id);


--
-- Name: integration_runs integration_runs_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_runs
    ADD CONSTRAINT integration_runs_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: integration_runs integration_runs_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_runs
    ADD CONSTRAINT integration_runs_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: integration_runs integration_runs_parent_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_runs
    ADD CONSTRAINT integration_runs_parent_run_id_fkey FOREIGN KEY (parent_run_id) REFERENCES public.integration_runs(id);


--
-- Name: integration_source_bindings integration_source_bindings_adapter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_source_bindings
    ADD CONSTRAINT integration_source_bindings_adapter_id_fkey FOREIGN KEY (adapter_id) REFERENCES public.integration_adapters(id);


--
-- Name: integration_source_bindings integration_source_bindings_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_source_bindings
    ADD CONSTRAINT integration_source_bindings_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: integration_source_bindings integration_source_bindings_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.integration_source_bindings
    ADD CONSTRAINT integration_source_bindings_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.import_sources(id);


--
-- Name: lead_events lead_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_events
    ADD CONSTRAINT lead_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES auth.users(id);


--
-- Name: lead_events lead_events_lead_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_events
    ADD CONSTRAINT lead_events_lead_id_fkey FOREIGN KEY (lead_id) REFERENCES public.leads(id) ON DELETE RESTRICT;


--
-- Name: lead_events lead_events_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lead_events
    ADD CONSTRAINT lead_events_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: leads leads_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: leads leads_customer_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_customer_fk FOREIGN KEY (organization_id, customer_id) REFERENCES public.clients(organization_id, id);


--
-- Name: leads leads_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: leads leads_owner_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT leads_owner_user_id_fkey FOREIGN KEY (owner_user_id) REFERENCES auth.users(id);


--
-- Name: modalities modalities_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modalities
    ADD CONSTRAINT modalities_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- Name: network_split_rule_versions network_split_rule_versions_bank_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.network_split_rule_versions
    ADD CONSTRAINT network_split_rule_versions_bank_id_fkey FOREIGN KEY (bank_id) REFERENCES public.banks(id);


--
-- Name: network_split_rule_versions network_split_rule_versions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.network_split_rule_versions
    ADD CONSTRAINT network_split_rule_versions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: network_split_rule_versions network_split_rule_versions_product_table_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.network_split_rule_versions
    ADD CONSTRAINT network_split_rule_versions_product_table_id_fkey FOREIGN KEY (product_table_id) REFERENCES public.product_tables(id);


--
-- Name: network_split_rule_versions network_split_rule_versions_relationship_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.network_split_rule_versions
    ADD CONSTRAINT network_split_rule_versions_relationship_id_fkey FOREIGN KEY (relationship_id) REFERENCES public.commercial_relationships(id);


--
-- Name: operational_attention_events operational_attention_events_actor_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_attention_events
    ADD CONSTRAINT operational_attention_events_actor_fkey FOREIGN KEY (actor) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: operational_attention_events operational_attention_events_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_attention_events
    ADD CONSTRAINT operational_attention_events_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: operational_attention_events operational_attention_events_organization_id_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_attention_events
    ADD CONSTRAINT operational_attention_events_organization_id_item_id_fkey FOREIGN KEY (organization_id, item_id) REFERENCES public.operational_attention_items(organization_id, id) ON DELETE RESTRICT;


--
-- Name: operational_attention_items operational_attention_items_assigned_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_attention_items
    ADD CONSTRAINT operational_attention_items_assigned_to_fkey FOREIGN KEY (assigned_to) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: operational_attention_items operational_attention_items_decided_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_attention_items
    ADD CONSTRAINT operational_attention_items_decided_by_fkey FOREIGN KEY (decided_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: operational_attention_items operational_attention_items_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_attention_items
    ADD CONSTRAINT operational_attention_items_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: operational_cases operational_cases_digitization_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_cases
    ADD CONSTRAINT operational_cases_digitization_tenant_fk FOREIGN KEY (organization_id, digitization_job_id) REFERENCES public.digitization_jobs(organization_id, id) ON DELETE RESTRICT;


--
-- Name: operational_cases operational_cases_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_cases
    ADD CONSTRAINT operational_cases_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: operational_cases operational_cases_owner_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_cases
    ADD CONSTRAINT operational_cases_owner_user_id_fkey FOREIGN KEY (owner_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: operational_cases operational_cases_proposal_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_cases
    ADD CONSTRAINT operational_cases_proposal_tenant_fk FOREIGN KEY (organization_id, proposal_id) REFERENCES public.proposals_v2(organization_id, id) ON DELETE RESTRICT;


--
-- Name: operational_cases operational_cases_stage_state_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_cases
    ADD CONSTRAINT operational_cases_stage_state_fk FOREIGN KEY (organization_id, current_stage_id, canonical_state) REFERENCES public.operational_stages(organization_id, id, canonical_state) ON DELETE RESTRICT;


--
-- Name: operational_cases operational_cases_stage_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_cases
    ADD CONSTRAINT operational_cases_stage_tenant_fk FOREIGN KEY (organization_id, current_stage_id) REFERENCES public.operational_stages(organization_id, id) ON DELETE RESTRICT;


--
-- Name: operational_events operational_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_events
    ADD CONSTRAINT operational_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: operational_events operational_events_case_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_events
    ADD CONSTRAINT operational_events_case_tenant_fk FOREIGN KEY (organization_id, operational_case_id) REFERENCES public.operational_cases(organization_id, id) ON DELETE RESTRICT;


--
-- Name: operational_events operational_events_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_events
    ADD CONSTRAINT operational_events_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: operational_stages operational_stages_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_stages
    ADD CONSTRAINT operational_stages_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: organization_admin_events organization_admin_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_admin_events
    ADD CONSTRAINT organization_admin_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: organization_admin_events organization_admin_events_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_admin_events
    ADD CONSTRAINT organization_admin_events_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: organization_admin_events organization_admin_events_target_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_admin_events
    ADD CONSTRAINT organization_admin_events_target_user_id_fkey FOREIGN KEY (target_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: organization_agreements organization_agreements_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_agreements
    ADD CONSTRAINT organization_agreements_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: organization_agreements organization_agreements_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_agreements
    ADD CONSTRAINT organization_agreements_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: organization_agreements organization_agreements_template_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_agreements
    ADD CONSTRAINT organization_agreements_template_id_fkey FOREIGN KEY (template_id) REFERENCES public.national_agreement_templates(id) ON DELETE RESTRICT;


--
-- Name: organization_ai_limits organization_ai_limits_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_ai_limits
    ADD CONSTRAINT organization_ai_limits_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: organization_ai_limits organization_ai_limits_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_ai_limits
    ADD CONSTRAINT organization_ai_limits_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: organization_banks organization_banks_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_banks
    ADD CONSTRAINT organization_banks_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: organization_banks organization_banks_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_banks
    ADD CONSTRAINT organization_banks_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: organization_branches organization_branches_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_branches
    ADD CONSTRAINT organization_branches_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: organization_branches organization_branches_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_branches
    ADD CONSTRAINT organization_branches_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: organization_branches organization_branches_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_branches
    ADD CONSTRAINT organization_branches_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: organization_contract_type_settings organization_contract_type_settings_contract_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_contract_type_settings
    ADD CONSTRAINT organization_contract_type_settings_contract_type_id_fkey FOREIGN KEY (contract_type_id) REFERENCES public.contract_types(id) ON DELETE RESTRICT;


--
-- Name: organization_contract_type_settings organization_contract_type_settings_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_contract_type_settings
    ADD CONSTRAINT organization_contract_type_settings_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: organization_contract_type_settings organization_contract_type_settings_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_contract_type_settings
    ADD CONSTRAINT organization_contract_type_settings_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: organization_invitations organization_invitations_accepted_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_invitations
    ADD CONSTRAINT organization_invitations_accepted_user_id_fkey FOREIGN KEY (accepted_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: organization_invitations organization_invitations_invited_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_invitations
    ADD CONSTRAINT organization_invitations_invited_by_fkey FOREIGN KEY (invited_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: organization_invitations organization_invitations_org_seller_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_invitations
    ADD CONSTRAINT organization_invitations_org_seller_fk FOREIGN KEY (organization_id, seller_id) REFERENCES public.commercial_sellers(organization_id, id) ON DELETE RESTRICT;


--
-- Name: organization_invitations organization_invitations_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_invitations
    ADD CONSTRAINT organization_invitations_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: organization_memberships organization_memberships_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT organization_memberships_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: organization_memberships organization_memberships_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_memberships
    ADD CONSTRAINT organization_memberships_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: organization_product_routes organization_product_routes_agreement_bank_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_product_routes
    ADD CONSTRAINT organization_product_routes_agreement_bank_fk FOREIGN KEY (bank_id, agreement_id) REFERENCES public.agreements(bank_id, id) ON DELETE RESTRICT;


--
-- Name: organization_product_routes organization_product_routes_bank_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_product_routes
    ADD CONSTRAINT organization_product_routes_bank_id_fkey FOREIGN KEY (bank_id) REFERENCES public.banks(id) ON DELETE RESTRICT;


--
-- Name: organization_product_routes organization_product_routes_modality_product_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_product_routes
    ADD CONSTRAINT organization_product_routes_modality_product_fk FOREIGN KEY (product_id, modality_id) REFERENCES public.modalities(product_id, id) ON DELETE RESTRICT;


--
-- Name: organization_product_routes organization_product_routes_org_agreement_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_product_routes
    ADD CONSTRAINT organization_product_routes_org_agreement_fk FOREIGN KEY (organization_id, org_agreement_id) REFERENCES public.organization_agreements(organization_id, id) ON DELETE RESTRICT;


--
-- Name: organization_product_routes organization_product_routes_org_bank_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_product_routes
    ADD CONSTRAINT organization_product_routes_org_bank_fk FOREIGN KEY (organization_id, org_bank_id) REFERENCES public.organization_banks(organization_id, id) ON DELETE RESTRICT;


--
-- Name: organization_product_routes organization_product_routes_org_provider_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_product_routes
    ADD CONSTRAINT organization_product_routes_org_provider_fk FOREIGN KEY (organization_id, org_provider_id) REFERENCES public.organization_providers(organization_id, id) ON DELETE RESTRICT;


--
-- Name: organization_product_routes organization_product_routes_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_product_routes
    ADD CONSTRAINT organization_product_routes_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: organization_product_routes organization_product_routes_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_product_routes
    ADD CONSTRAINT organization_product_routes_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- Name: organization_product_routes organization_product_routes_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_product_routes
    ADD CONSTRAINT organization_product_routes_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.providers(id) ON DELETE RESTRICT;


--
-- Name: organization_providers organization_providers_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_providers
    ADD CONSTRAINT organization_providers_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: organization_providers organization_providers_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.organization_providers
    ADD CONSTRAINT organization_providers_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: payout_policies payout_policies_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_policies
    ADD CONSTRAINT payout_policies_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: payout_policies payout_policies_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_policies
    ADD CONSTRAINT payout_policies_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: payout_policy_items payout_policy_items_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_policy_items
    ADD CONSTRAINT payout_policy_items_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: payout_policy_items payout_policy_items_organization_id_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_policy_items
    ADD CONSTRAINT payout_policy_items_organization_id_group_id_fkey FOREIGN KEY (organization_id, group_id) REFERENCES public.commission_groups(organization_id, id) ON DELETE RESTRICT;


--
-- Name: payout_policy_items payout_policy_items_organization_id_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_policy_items
    ADD CONSTRAINT payout_policy_items_organization_id_version_id_fkey FOREIGN KEY (organization_id, version_id) REFERENCES public.payout_policy_versions(organization_id, id) ON DELETE RESTRICT;


--
-- Name: payout_policy_versions payout_policy_versions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_policy_versions
    ADD CONSTRAINT payout_policy_versions_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: payout_policy_versions payout_policy_versions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_policy_versions
    ADD CONSTRAINT payout_policy_versions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: payout_policy_versions payout_policy_versions_organization_id_policy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payout_policy_versions
    ADD CONSTRAINT payout_policy_versions_organization_id_policy_id_fkey FOREIGN KEY (organization_id, policy_id) REFERENCES public.payout_policies(organization_id, id) ON DELETE RESTRICT;


--
-- Name: platform_admin_audit_events platform_admin_audit_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_admin_audit_events
    ADD CONSTRAINT platform_admin_audit_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES auth.users(id) ON DELETE RESTRICT;


--
-- Name: platform_admin_audit_events platform_admin_audit_events_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_admin_audit_events
    ADD CONSTRAINT platform_admin_audit_events_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: platform_admin_audit_events platform_admin_audit_events_target_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_admin_audit_events
    ADD CONSTRAINT platform_admin_audit_events_target_user_id_fkey FOREIGN KEY (target_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: platform_administrators platform_administrators_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_administrators
    ADD CONSTRAINT platform_administrators_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: product_table_external_identities product_table_external_identities_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_table_external_identities
    ADD CONSTRAINT product_table_external_identities_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.commercial_channels(id);


--
-- Name: product_table_external_identities product_table_external_identities_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_table_external_identities
    ADD CONSTRAINT product_table_external_identities_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: product_table_external_identities product_table_external_identities_product_table_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_table_external_identities
    ADD CONSTRAINT product_table_external_identities_product_table_id_fkey FOREIGN KEY (product_table_id) REFERENCES public.product_tables(id);


--
-- Name: product_table_versions product_table_versions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_table_versions
    ADD CONSTRAINT product_table_versions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: product_table_versions product_table_versions_table_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_table_versions
    ADD CONSTRAINT product_table_versions_table_tenant_fk FOREIGN KEY (organization_id, product_table_id) REFERENCES public.product_tables(organization_id, id) ON DELETE RESTRICT;


--
-- Name: product_tables product_tables_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_tables
    ADD CONSTRAINT product_tables_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: product_tables product_tables_route_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_tables
    ADD CONSTRAINT product_tables_route_tenant_fk FOREIGN KEY (organization_id, route_id) REFERENCES public.organization_product_routes(organization_id, id) ON DELETE RESTRICT;


--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE CASCADE;


--
-- Name: proposal_commercial_component_snapshots proposal_commercial_component_snap_commission_component_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_commercial_component_snapshots
    ADD CONSTRAINT proposal_commercial_component_snap_commission_component_id_fkey FOREIGN KEY (commission_component_id) REFERENCES public.commission_rule_components(id);


--
-- Name: proposal_commercial_component_snapshots proposal_commercial_component_snapsh_split_rule_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_commercial_component_snapshots
    ADD CONSTRAINT proposal_commercial_component_snapsh_split_rule_version_id_fkey FOREIGN KEY (split_rule_version_id) REFERENCES public.network_split_rule_versions(id);


--
-- Name: proposal_commercial_component_snapshots proposal_commercial_component_snapshots_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_commercial_component_snapshots
    ADD CONSTRAINT proposal_commercial_component_snapshots_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: proposal_commercial_component_snapshots proposal_commercial_component_snapshots_proposal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_commercial_component_snapshots
    ADD CONSTRAINT proposal_commercial_component_snapshots_proposal_id_fkey FOREIGN KEY (proposal_id) REFERENCES public.proposals_v2(id);


--
-- Name: proposal_commercial_snapshots proposal_commercial_snapshots_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_commercial_snapshots
    ADD CONSTRAINT proposal_commercial_snapshots_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.commercial_channels(id);


--
-- Name: proposal_commercial_snapshots proposal_commercial_snapshots_commission_rule_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_commercial_snapshots
    ADD CONSTRAINT proposal_commercial_snapshots_commission_rule_version_id_fkey FOREIGN KEY (commission_rule_version_id) REFERENCES public.channel_commission_rule_versions(id);


--
-- Name: proposal_commercial_snapshots proposal_commercial_snapshots_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_commercial_snapshots
    ADD CONSTRAINT proposal_commercial_snapshots_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: proposal_commercial_snapshots proposal_commercial_snapshots_payer_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_commercial_snapshots
    ADD CONSTRAINT proposal_commercial_snapshots_payer_entity_id_fkey FOREIGN KEY (payer_entity_id) REFERENCES public.commercial_entities(id);


--
-- Name: proposal_commercial_snapshots proposal_commercial_snapshots_producer_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_commercial_snapshots
    ADD CONSTRAINT proposal_commercial_snapshots_producer_entity_id_fkey FOREIGN KEY (producer_entity_id) REFERENCES public.commercial_entities(id);


--
-- Name: proposal_commercial_snapshots proposal_commercial_snapshots_proposal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_commercial_snapshots
    ADD CONSTRAINT proposal_commercial_snapshots_proposal_id_fkey FOREIGN KEY (proposal_id) REFERENCES public.proposals_v2(id);


--
-- Name: proposal_commercial_snapshots proposal_commercial_snapshots_split_rule_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_commercial_snapshots
    ADD CONSTRAINT proposal_commercial_snapshots_split_rule_version_id_fkey FOREIGN KEY (split_rule_version_id) REFERENCES public.network_split_rule_versions(id);


--
-- Name: proposal_commercial_component_snapshots proposal_component_snapshot_seller_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_commercial_component_snapshots
    ADD CONSTRAINT proposal_component_snapshot_seller_tenant_fk FOREIGN KEY (organization_id, seller_id) REFERENCES public.commercial_sellers(organization_id, id) ON DELETE RESTRICT;


--
-- Name: proposal_commercial_component_snapshots proposal_component_snapshot_sub_rule_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_commercial_component_snapshots
    ADD CONSTRAINT proposal_component_snapshot_sub_rule_fk FOREIGN KEY (organization_id, seller_id, seller_sub_rule_version_id) REFERENCES public.seller_sub_rule_versions(organization_id, seller_id, id) ON DELETE RESTRICT;


--
-- Name: proposal_document_links proposal_document_links_document_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_document_links
    ADD CONSTRAINT proposal_document_links_document_tenant_fk FOREIGN KEY (organization_id, customer_document_id) REFERENCES public.customer_documents(organization_id, id) ON DELETE RESTRICT;


--
-- Name: proposal_document_links proposal_document_links_linked_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_document_links
    ADD CONSTRAINT proposal_document_links_linked_by_fkey FOREIGN KEY (linked_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: proposal_document_links proposal_document_links_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_document_links
    ADD CONSTRAINT proposal_document_links_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: proposal_document_links proposal_document_links_requirement_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_document_links
    ADD CONSTRAINT proposal_document_links_requirement_tenant_fk FOREIGN KEY (organization_id, requirement_id) REFERENCES public.proposal_document_requirements(organization_id, id) ON DELETE RESTRICT;


--
-- Name: proposal_document_requirements proposal_document_requirements_document_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_document_requirements
    ADD CONSTRAINT proposal_document_requirements_document_type_id_fkey FOREIGN KEY (document_type_id) REFERENCES public.document_types(id) ON DELETE RESTRICT;


--
-- Name: proposal_document_requirements proposal_document_requirements_exception_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_document_requirements
    ADD CONSTRAINT proposal_document_requirements_exception_approved_by_fkey FOREIGN KEY (exception_approved_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: proposal_document_requirements proposal_document_requirements_item_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_document_requirements
    ADD CONSTRAINT proposal_document_requirements_item_tenant_fk FOREIGN KEY (organization_id, checklist_item_id) REFERENCES public.document_checklist_items(organization_id, id) ON DELETE RESTRICT;


--
-- Name: proposal_document_requirements proposal_document_requirements_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_document_requirements
    ADD CONSTRAINT proposal_document_requirements_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: proposal_document_requirements proposal_document_requirements_proposal_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_document_requirements
    ADD CONSTRAINT proposal_document_requirements_proposal_tenant_fk FOREIGN KEY (organization_id, proposal_id) REFERENCES public.proposals_v2(organization_id, id) ON DELETE RESTRICT;


--
-- Name: proposal_external_identities proposal_external_identities_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_external_identities
    ADD CONSTRAINT proposal_external_identities_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.commercial_channels(id);


--
-- Name: proposal_external_identities proposal_external_identities_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_external_identities
    ADD CONSTRAINT proposal_external_identities_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: proposal_external_identities proposal_external_identities_proposal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_external_identities
    ADD CONSTRAINT proposal_external_identities_proposal_id_fkey FOREIGN KEY (proposal_id) REFERENCES public.proposals_v2(id);


--
-- Name: proposal_seller_commission_snapshots proposal_seller_commission_sn_organization_id_commission_g_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_seller_commission_snapshots
    ADD CONSTRAINT proposal_seller_commission_sn_organization_id_commission_g_fkey FOREIGN KEY (organization_id, commission_group_id) REFERENCES public.commission_groups(organization_id, id) ON DELETE RESTRICT;


--
-- Name: proposal_seller_commission_snapshots proposal_seller_commission_sna_organization_id_proposal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_seller_commission_snapshots
    ADD CONSTRAINT proposal_seller_commission_sna_organization_id_proposal_id_fkey FOREIGN KEY (organization_id, proposal_id) REFERENCES public.proposals_v2(organization_id, id) ON DELETE RESTRICT;


--
-- Name: proposal_seller_commission_snapshots proposal_seller_commission_snaps_organization_id_seller_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_seller_commission_snapshots
    ADD CONSTRAINT proposal_seller_commission_snaps_organization_id_seller_id_fkey FOREIGN KEY (organization_id, seller_id) REFERENCES public.commercial_sellers(organization_id, id) ON DELETE RESTRICT;


--
-- Name: proposal_seller_commission_snapshots proposal_seller_commission_snapshots_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_seller_commission_snapshots
    ADD CONSTRAINT proposal_seller_commission_snapshots_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: proposal_status_evidence proposal_status_evidence_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_status_evidence
    ADD CONSTRAINT proposal_status_evidence_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: proposal_status_evidence proposal_status_evidence_import_decision_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_status_evidence
    ADD CONSTRAINT proposal_status_evidence_import_decision_id_fkey FOREIGN KEY (import_decision_id) REFERENCES public.import_decisions(id);


--
-- Name: proposal_status_evidence proposal_status_evidence_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_status_evidence
    ADD CONSTRAINT proposal_status_evidence_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id);


--
-- Name: proposal_status_evidence proposal_status_evidence_proposal_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposal_status_evidence
    ADD CONSTRAINT proposal_status_evidence_proposal_id_fkey FOREIGN KEY (proposal_id) REFERENCES public.proposals_v2(id);


--
-- Name: proposals_v2 proposals_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposals_v2
    ADD CONSTRAINT proposals_v2_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: proposals_v2 proposals_v2_customer_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposals_v2
    ADD CONSTRAINT proposals_v2_customer_tenant_fk FOREIGN KEY (organization_id, customer_id) REFERENCES public.clients(organization_id, id) ON DELETE RESTRICT;


--
-- Name: proposals_v2 proposals_v2_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposals_v2
    ADD CONSTRAINT proposals_v2_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: proposals_v2 proposals_v2_seller_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposals_v2
    ADD CONSTRAINT proposals_v2_seller_tenant_fk FOREIGN KEY (organization_id, seller_id) REFERENCES public.commercial_sellers(organization_id, id) ON DELETE RESTRICT;


--
-- Name: proposals_v2 proposals_v2_simulation_snapshot_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposals_v2
    ADD CONSTRAINT proposals_v2_simulation_snapshot_fk FOREIGN KEY (organization_id, simulation_id, customer_id, product_table_version_id) REFERENCES public.simulations(organization_id, id, customer_id, product_table_version_id) ON DELETE RESTRICT;


--
-- Name: proposals_v2 proposals_v2_simulation_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposals_v2
    ADD CONSTRAINT proposals_v2_simulation_tenant_fk FOREIGN KEY (organization_id, simulation_id) REFERENCES public.simulations(organization_id, id) ON DELETE RESTRICT;


--
-- Name: proposals_v2 proposals_v2_table_version_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.proposals_v2
    ADD CONSTRAINT proposals_v2_table_version_tenant_fk FOREIGN KEY (organization_id, product_table_version_id) REFERENCES public.product_table_versions(organization_id, id) ON DELETE RESTRICT;


--
-- Name: seller_addresses seller_addresses_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_addresses
    ADD CONSTRAINT seller_addresses_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: seller_addresses seller_addresses_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_addresses
    ADD CONSTRAINT seller_addresses_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: seller_addresses seller_addresses_organization_id_seller_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_addresses
    ADD CONSTRAINT seller_addresses_organization_id_seller_id_fkey FOREIGN KEY (organization_id, seller_id) REFERENCES public.commercial_sellers(organization_id, id) ON DELETE RESTRICT;


--
-- Name: seller_bank_aliases seller_bank_aliases_bank_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_bank_aliases
    ADD CONSTRAINT seller_bank_aliases_bank_id_fkey FOREIGN KEY (bank_id) REFERENCES public.banks(id) ON DELETE RESTRICT;


--
-- Name: seller_bank_aliases seller_bank_aliases_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_bank_aliases
    ADD CONSTRAINT seller_bank_aliases_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: seller_bank_aliases seller_bank_aliases_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_bank_aliases
    ADD CONSTRAINT seller_bank_aliases_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: seller_bank_aliases seller_bank_aliases_organization_id_seller_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_bank_aliases
    ADD CONSTRAINT seller_bank_aliases_organization_id_seller_id_fkey FOREIGN KEY (organization_id, seller_id) REFERENCES public.commercial_sellers(organization_id, id) ON DELETE RESTRICT;


--
-- Name: seller_bank_aliases seller_bank_aliases_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_bank_aliases
    ADD CONSTRAINT seller_bank_aliases_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.providers(id) ON DELETE RESTRICT;


--
-- Name: seller_bank_aliases seller_bank_aliases_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_bank_aliases
    ADD CONSTRAINT seller_bank_aliases_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: seller_certifications seller_certifications_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_certifications
    ADD CONSTRAINT seller_certifications_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: seller_certifications seller_certifications_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_certifications
    ADD CONSTRAINT seller_certifications_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: seller_certifications seller_certifications_organization_id_seller_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_certifications
    ADD CONSTRAINT seller_certifications_organization_id_seller_id_fkey FOREIGN KEY (organization_id, seller_id) REFERENCES public.commercial_sellers(organization_id, id) ON DELETE RESTRICT;


--
-- Name: seller_certifications seller_certifications_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_certifications
    ADD CONSTRAINT seller_certifications_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: seller_groups seller_groups_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_groups
    ADD CONSTRAINT seller_groups_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: seller_groups seller_groups_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_groups
    ADD CONSTRAINT seller_groups_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: seller_payment_accounts seller_payment_accounts_bank_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_payment_accounts
    ADD CONSTRAINT seller_payment_accounts_bank_id_fkey FOREIGN KEY (bank_id) REFERENCES public.banks(id) ON DELETE RESTRICT;


--
-- Name: seller_payment_accounts seller_payment_accounts_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_payment_accounts
    ADD CONSTRAINT seller_payment_accounts_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: seller_payment_accounts seller_payment_accounts_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_payment_accounts
    ADD CONSTRAINT seller_payment_accounts_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: seller_payment_accounts seller_payment_accounts_organization_id_seller_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_payment_accounts
    ADD CONSTRAINT seller_payment_accounts_organization_id_seller_id_fkey FOREIGN KEY (organization_id, seller_id) REFERENCES public.commercial_sellers(organization_id, id) ON DELETE RESTRICT;


--
-- Name: seller_profiles seller_profiles_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_profiles
    ADD CONSTRAINT seller_profiles_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: seller_profiles seller_profiles_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_profiles
    ADD CONSTRAINT seller_profiles_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: seller_profiles seller_profiles_organization_id_seller_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_profiles
    ADD CONSTRAINT seller_profiles_organization_id_seller_id_fkey FOREIGN KEY (organization_id, seller_id) REFERENCES public.commercial_sellers(organization_id, id) ON DELETE RESTRICT;


--
-- Name: seller_profiles seller_profiles_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_profiles
    ADD CONSTRAINT seller_profiles_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: seller_sub_rule_versions seller_sub_rule_versions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_sub_rule_versions
    ADD CONSTRAINT seller_sub_rule_versions_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: seller_sub_rule_versions seller_sub_rule_versions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_sub_rule_versions
    ADD CONSTRAINT seller_sub_rule_versions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: seller_sub_rule_versions seller_sub_rule_versions_organization_id_seller_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_sub_rule_versions
    ADD CONSTRAINT seller_sub_rule_versions_organization_id_seller_id_fkey FOREIGN KEY (organization_id, seller_id) REFERENCES public.commercial_sellers(organization_id, id) ON DELETE RESTRICT;


--
-- Name: seller_supervisions seller_supervisions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_supervisions
    ADD CONSTRAINT seller_supervisions_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: seller_supervisions seller_supervisions_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_supervisions
    ADD CONSTRAINT seller_supervisions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: seller_supervisions seller_supervisions_organization_id_seller_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_supervisions
    ADD CONSTRAINT seller_supervisions_organization_id_seller_id_fkey FOREIGN KEY (organization_id, seller_id) REFERENCES public.commercial_sellers(organization_id, id) ON DELETE RESTRICT;


--
-- Name: seller_supervisions seller_supervisions_organization_id_supervisor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_supervisions
    ADD CONSTRAINT seller_supervisions_organization_id_supervisor_user_id_fkey FOREIGN KEY (organization_id, supervisor_user_id) REFERENCES public.organization_memberships(organization_id, user_id) ON DELETE RESTRICT;


--
-- Name: seller_supervisions seller_supervisions_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.seller_supervisions
    ADD CONSTRAINT seller_supervisions_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: simulations simulations_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.simulations
    ADD CONSTRAINT simulations_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: simulations simulations_customer_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.simulations
    ADD CONSTRAINT simulations_customer_tenant_fk FOREIGN KEY (organization_id, customer_id) REFERENCES public.clients(organization_id, id) ON DELETE RESTRICT;


--
-- Name: simulations simulations_organization_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.simulations
    ADD CONSTRAINT simulations_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;


--
-- Name: simulations simulations_table_version_tenant_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.simulations
    ADD CONSTRAINT simulations_table_version_tenant_fk FOREIGN KEY (organization_id, product_table_version_id) REFERENCES public.product_table_versions(organization_id, id) ON DELETE RESTRICT;


--
-- Name: agreements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.agreements ENABLE ROW LEVEL SECURITY;

--
-- Name: agreements agreements_authenticated_read; Type: POLICY; Schema: public; Owner: -
--

--
-- Schema private (captured from production via pg_get_functiondef on 2026-09-24; pg_dump ran with --schema=public)
--

CREATE SCHEMA IF NOT EXISTS private;
GRANT USAGE ON SCHEMA private TO authenticated;

CREATE OR REPLACE FUNCTION private.attach_import_batch_adapter(p_batch_id uuid, p_adapter_key text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_user uuid:=(select auth.uid());b record;v_adapter uuid;v_ver text;
begin
 if v_user is null then raise exception 'batch_not_found_or_forbidden'; end if;
 select id,organization_id,adapter_id,received_by,parser_key into b from public.import_batches where id=p_batch_id for update;
 if not found or not exists(select 1 from public.organization_memberships m where m.organization_id=b.organization_id and m.user_id=v_user and m.status='active' and (b.received_by is not distinct from v_user or m.role in ('admin','manager','supervisor'))) then raise exception 'batch_not_found_or_forbidden'; end if;
 select id,contract_version into v_adapter,v_ver from public.integration_adapters where adapter_key=p_adapter_key and status<>'disabled';
 if v_adapter is null then raise exception 'adapter_not_found'; end if;
 if b.parser_key is distinct from p_adapter_key then raise exception 'adapter_parser_mismatch'; end if;
 if b.adapter_id is not null then if b.adapter_id<>v_adapter then raise exception 'batch_adapter_immutable'; end if; return; end if;
 perform set_config('corban.adapter_attach_rpc','on',true);
 update public.import_batches set adapter_id=v_adapter,adapter_contract_version=v_ver where id=b.id and adapter_id is null;
 perform set_config('corban.adapter_attach_rpc','off',true);
end $function$
;

CREATE OR REPLACE FUNCTION private.caller_role_in(p_org uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select m.role from public.organization_memberships m where m.organization_id=p_org and m.user_id=(select auth.uid()) and m.status='active' limit 1
$function$
;

CREATE OR REPLACE FUNCTION private.commercial_route(p_proposal_id uuid)
 RETURNS TABLE(proposal_id uuid, channel_id uuid, producer_entity_id uuid, payer_entity_id uuid, commission_rule_version_id uuid, split_rule_version_id uuid, snapshot jsonb, created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_org uuid;
begin
 select p.organization_id into v_org from public.proposals_v2 p where p.id=p_proposal_id;
 if v_org is null or coalesce(private.caller_role_in(v_org),'') not in ('admin','manager','supervisor') then raise exception 'forbidden'; end if;
 return query select s.proposal_id,s.channel_id,s.producer_entity_id,s.payer_entity_id,s.commission_rule_version_id,s.split_rule_version_id,s.snapshot,s.created_at
  from public.proposal_commercial_snapshots s where s.proposal_id=p_proposal_id and s.organization_id=v_org;
end $function$
;

CREATE OR REPLACE FUNCTION private.import_row_evidence(p_row_id uuid)
 RETURNS TABLE(record_kind text, amount numeric, normalized_payload jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_org uuid;
begin
 select n.organization_id into v_org from public.import_normalized_rows n where n.id=p_row_id;
 if v_org is null or coalesce(private.caller_role_in(v_org),'') not in ('admin','manager','supervisor') then raise exception 'forbidden'; end if;
 return query select n.record_kind,n.amount,n.normalized_payload from public.import_normalized_rows n where n.id=p_row_id and n.organization_id=v_org;
end $function$
;

CREATE OR REPLACE FUNCTION private.lead_write(p_org uuid, p_lead uuid, p_op text, p_args jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_user uuid:=(select auth.uid());v_role text;l public.leads%rowtype;v_id uuid;v_customer uuid;
begin
 v_role:=private.caller_role_in(p_org);
 if v_user is null or v_role is null then raise exception 'lead_forbidden'; end if;
 if p_op='create' then
  insert into public.leads(organization_id,channel,campaign,external_ref,full_name,phone,email,owner_user_id,metadata,created_by)
  values(p_org,p_args->>'channel',nullif(p_args->>'campaign',''),nullif(p_args->>'external_ref',''),p_args->>'full_name',nullif(p_args->>'phone',''),nullif(lower(p_args->>'email'),''),v_user,coalesce(p_args->'metadata','{}'::jsonb),v_user)
  on conflict (organization_id,channel,external_ref) where external_ref is not null do nothing returning id into v_id;
  if v_id is null then select id into v_id from public.leads where organization_id=p_org and channel=p_args->>'channel' and external_ref=nullif(p_args->>'external_ref',''); return v_id; end if;
  insert into public.lead_events(organization_id,lead_id,event_type,to_status,actor_user_id,detail) values(p_org,v_id,'created','new',v_user,jsonb_build_object('channel',p_args->>'channel','campaign',p_args->>'campaign'));
  return v_id;
 end if;
 select * into l from public.leads where id=p_lead and organization_id=p_org for update;
 if not found then raise exception 'lead_forbidden'; end if;
 if p_op='status' then
  if l.status in ('converted') then raise exception 'lead_already_converted'; end if;
  if p_args->>'status' not in ('new','contacted','qualified','lost') then raise exception 'invalid_lead_status'; end if;
  if p_args->>'status'='lost' and nullif(btrim(p_args->>'lost_reason'),'') is null then raise exception 'lost_reason_required'; end if;
  if l.status='lost' and p_args->>'status'<>'lost' and v_role not in ('admin','manager','supervisor') then raise exception 'lead_reactivation_requires_supervisor'; end if;
  update public.leads set status=p_args->>'status',lost_reason=case when p_args->>'status'='lost' then p_args->>'lost_reason' else null end,updated_at=now() where id=l.id;
  insert into public.lead_events(organization_id,lead_id,event_type,from_status,to_status,actor_user_id,detail) values(p_org,l.id,case when l.status='lost' then 'reactivated' else 'status_changed' end,l.status,p_args->>'status',v_user,jsonb_build_object('lost_reason',p_args->>'lost_reason'));
  return l.id;
 end if;
 if p_op='convert' then
  if l.status='converted' then return l.customer_id; end if;
  if l.status='lost' then raise exception 'lost_lead_must_be_reactivated'; end if;
  if p_args->>'cpf' !~ '^[0-9]{11}$' then raise exception 'invalid_cpf_format'; end if;
  insert into public.clients(organization_id,full_name,cpf,phone,email,original_source) values(p_org,l.full_name,p_args->>'cpf',l.phone,l.email,'lead:'||l.channel) returning id into v_customer;
  insert into public.customer_timeline_events(organization_id,customer_id,event_type,source,actor_user_id) values(p_org,v_customer,'customer.created','lead_conversion',v_user);
  update public.leads set status='converted',customer_id=v_customer,converted_at=now(),updated_at=now() where id=l.id;
  insert into public.lead_events(organization_id,lead_id,event_type,from_status,to_status,actor_user_id,detail) values(p_org,l.id,'converted',l.status,'converted',v_user,jsonb_build_object('customer_id',v_customer));
  return v_customer;
 end if;
 raise exception 'invalid_lead_operation';
end $function$
;

CREATE OR REPLACE FUNCTION private.list_import_rows(p_batch_id uuid, p_numbers text[] DEFAULT NULL::text[])
 RETURNS TABLE(id uuid, organization_id uuid, raw_row_id uuid, batch_id uuid, source_id uuid, row_number integer, record_kind text, bank_key text, external_proposal_number text, producer_tax_id text, external_table_code text, external_table_name text, operation_type text, term integer, rate numeric, normalization_version text, commission_upfront numeric, commission_deferred numeric, amount numeric, normalized_payload jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_org uuid;v_role text;v_priv boolean;
begin
 select b.organization_id into v_org from public.import_batches b where b.id=p_batch_id;
 v_role:=case when v_org is null then null else private.caller_role_in(v_org) end;
 if v_role is null then raise exception 'batch_not_found_or_forbidden'; end if;
 v_priv:=v_role in ('admin','manager','supervisor');
 return query
  select n.id,n.organization_id,n.raw_row_id,rr.batch_id,b.source_id,rr.row_number,n.record_kind,n.bank_key,n.external_proposal_number,n.producer_tax_id,n.external_table_code,n.external_table_name,n.operation_type,n.term,n.rate,n.normalization_version,
   case when v_priv then n.commission_upfront end,case when v_priv then n.commission_deferred end,case when v_priv then n.amount end,case when v_priv then n.normalized_payload end
  from public.import_normalized_rows n
  join public.import_raw_rows rr on rr.id=n.raw_row_id and rr.organization_id=n.organization_id
  join public.import_batches b on b.id=rr.batch_id and b.organization_id=rr.organization_id
  where n.organization_id=v_org
    and ((p_numbers is null and rr.batch_id=p_batch_id) or (p_numbers is not null and n.external_proposal_number=any(p_numbers)))
  order by rr.row_number,n.id
  limit 500;
end $function$
;

REVOKE ALL ON FUNCTION private.attach_import_batch_adapter(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.caller_role_in(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.commercial_route(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.import_row_evidence(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.lead_write(uuid, uuid, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.list_import_rows(uuid, text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.attach_import_batch_adapter(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION private.caller_role_in(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION private.commercial_route(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION private.import_row_evidence(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION private.lead_write(uuid, uuid, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION private.list_import_rows(uuid, text[]) TO authenticated;


CREATE POLICY agreements_authenticated_read ON public.agreements FOR SELECT TO authenticated USING (true);


--
-- Name: ai_credit_ledger; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ai_credit_ledger ENABLE ROW LEVEL SECURITY;

--
-- Name: ai_credit_ledger ai_credit_ledger_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_credit_ledger_insert ON public.ai_credit_ledger FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: ai_credit_ledger ai_credit_ledger_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_credit_ledger_select ON public.ai_credit_ledger FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: ai_usage_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ai_usage_events ENABLE ROW LEVEL SECURITY;

--
-- Name: ai_usage_events ai_usage_events_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_usage_events_insert ON public.ai_usage_events FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: ai_usage_events ai_usage_events_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_usage_events_select ON public.ai_usage_events FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: ai_usage_jobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ai_usage_jobs ENABLE ROW LEVEL SECURITY;

--
-- Name: ai_usage_jobs ai_usage_jobs_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_usage_jobs_insert ON public.ai_usage_jobs FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: ai_usage_jobs ai_usage_jobs_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_usage_jobs_select ON public.ai_usage_jobs FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: ai_usage_jobs ai_usage_jobs_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ai_usage_jobs_update ON public.ai_usage_jobs FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: banks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.banks ENABLE ROW LEVEL SECURITY;

--
-- Name: banks banks_authenticated_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY banks_authenticated_read ON public.banks FOR SELECT TO authenticated USING (true);


--
-- Name: channel_commission_rule_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.channel_commission_rule_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: channel_commission_rule_versions channel_commission_rule_versions_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY channel_commission_rule_versions_insert_manager ON public.channel_commission_rule_versions FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: channel_commission_rule_versions channel_commission_rule_versions_select_supervisor_plus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY channel_commission_rule_versions_select_supervisor_plus ON public.channel_commission_rule_versions FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: channel_commission_rule_versions channel_commission_rule_versions_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY channel_commission_rule_versions_update_manager ON public.channel_commission_rule_versions FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: clients; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.clients ENABLE ROW LEVEL SECURITY;

--
-- Name: clients clients_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY clients_insert_member ON public.clients FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: clients clients_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY clients_select_member ON public.clients FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: clients clients_update_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY clients_update_member ON public.clients FOR UPDATE TO authenticated USING (public.is_active_organization_member(organization_id)) WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: commercial_channels; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.commercial_channels ENABLE ROW LEVEL SECURITY;

--
-- Name: commercial_channels commercial_channels_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_channels_insert_manager ON public.commercial_channels FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_channels commercial_channels_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_channels_select_member ON public.commercial_channels FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: commercial_channels commercial_channels_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_channels_update_manager ON public.commercial_channels FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_condition_commissions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.commercial_condition_commissions ENABLE ROW LEVEL SECURITY;

--
-- Name: commercial_condition_commissions commercial_condition_commissions_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_condition_commissions_insert ON public.commercial_condition_commissions FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_condition_commissions commercial_condition_commissions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_condition_commissions_select ON public.commercial_condition_commissions FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: commercial_condition_commissions commercial_condition_commissions_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_condition_commissions_update ON public.commercial_condition_commissions FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_condition_component_policy; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.commercial_condition_component_policy ENABLE ROW LEVEL SECURITY;

--
-- Name: commercial_condition_component_policy commercial_condition_component_policy_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_condition_component_policy_insert ON public.commercial_condition_component_policy FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_condition_component_policy commercial_condition_component_policy_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_condition_component_policy_select ON public.commercial_condition_component_policy FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: commercial_condition_component_policy commercial_condition_component_policy_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_condition_component_policy_update ON public.commercial_condition_component_policy FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_condition_components; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.commercial_condition_components ENABLE ROW LEVEL SECURITY;

--
-- Name: commercial_condition_components commercial_condition_components_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_condition_components_delete ON public.commercial_condition_components FOR DELETE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_condition_components commercial_condition_components_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_condition_components_insert ON public.commercial_condition_components FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_condition_components commercial_condition_components_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_condition_components_select ON public.commercial_condition_components FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: commercial_condition_components commercial_condition_components_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_condition_components_update ON public.commercial_condition_components FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_condition_shares; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.commercial_condition_shares ENABLE ROW LEVEL SECURITY;

--
-- Name: commercial_condition_shares commercial_condition_shares_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_condition_shares_delete ON public.commercial_condition_shares FOR DELETE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_condition_shares commercial_condition_shares_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_condition_shares_insert ON public.commercial_condition_shares FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_condition_shares commercial_condition_shares_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_condition_shares_select ON public.commercial_condition_shares FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: commercial_condition_shares commercial_condition_shares_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_condition_shares_update ON public.commercial_condition_shares FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_conditions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.commercial_conditions ENABLE ROW LEVEL SECURITY;

--
-- Name: commercial_conditions commercial_conditions_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_conditions_insert ON public.commercial_conditions FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_conditions commercial_conditions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_conditions_select ON public.commercial_conditions FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: commercial_conditions commercial_conditions_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_conditions_update ON public.commercial_conditions FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_entities; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.commercial_entities ENABLE ROW LEVEL SECURITY;

--
-- Name: commercial_entities commercial_entities_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_entities_insert_manager ON public.commercial_entities FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_entities commercial_entities_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_entities_select_member ON public.commercial_entities FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: commercial_entities commercial_entities_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_entities_update_manager ON public.commercial_entities FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_factor_batches; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.commercial_factor_batches ENABLE ROW LEVEL SECURITY;

--
-- Name: commercial_factor_batches commercial_factor_batches_delete_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_factor_batches_delete_manager ON public.commercial_factor_batches FOR DELETE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_factor_batches commercial_factor_batches_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_factor_batches_insert_manager ON public.commercial_factor_batches FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_factor_batches commercial_factor_batches_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_factor_batches_select_member ON public.commercial_factor_batches FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: commercial_factor_batches commercial_factor_batches_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_factor_batches_update_manager ON public.commercial_factor_batches FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_factor_entries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.commercial_factor_entries ENABLE ROW LEVEL SECURITY;

--
-- Name: commercial_factor_entries commercial_factor_entries_delete_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_factor_entries_delete_manager ON public.commercial_factor_entries FOR DELETE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_factor_entries commercial_factor_entries_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_factor_entries_insert_manager ON public.commercial_factor_entries FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_factor_entries commercial_factor_entries_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_factor_entries_select_member ON public.commercial_factor_entries FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: commercial_factor_entries commercial_factor_entries_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_factor_entries_update_manager ON public.commercial_factor_entries FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_factor_profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.commercial_factor_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: commercial_factor_profiles commercial_factor_profiles_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_factor_profiles_insert_manager ON public.commercial_factor_profiles FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_factor_profiles commercial_factor_profiles_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_factor_profiles_select_member ON public.commercial_factor_profiles FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: commercial_factor_profiles commercial_factor_profiles_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_factor_profiles_update_manager ON public.commercial_factor_profiles FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_relationships; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.commercial_relationships ENABLE ROW LEVEL SECURITY;

--
-- Name: commercial_relationships commercial_relationships_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_relationships_insert_manager ON public.commercial_relationships FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_relationships commercial_relationships_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_relationships_select_member ON public.commercial_relationships FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: commercial_relationships commercial_relationships_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_relationships_update_manager ON public.commercial_relationships FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_sellers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.commercial_sellers ENABLE ROW LEVEL SECURITY;

--
-- Name: commercial_sellers commercial_sellers_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_sellers_insert_manager ON public.commercial_sellers FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commercial_sellers commercial_sellers_select_scoped; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_sellers_select_scoped ON public.commercial_sellers FOR SELECT TO authenticated USING ((public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]) OR (user_id = auth.uid())));


--
-- Name: commercial_sellers commercial_sellers_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commercial_sellers_update_manager ON public.commercial_sellers FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commission_component_types; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.commission_component_types ENABLE ROW LEVEL SECURITY;

--
-- Name: commission_component_types commission_component_types_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commission_component_types_read ON public.commission_component_types FOR SELECT TO authenticated USING (true);


--
-- Name: commission_group_component_limits; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.commission_group_component_limits ENABLE ROW LEVEL SECURITY;

--
-- Name: commission_group_component_limits commission_group_component_limits_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commission_group_component_limits_select_member ON public.commission_group_component_limits FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: commission_group_component_limits commission_group_component_limits_write_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commission_group_component_limits_write_manager ON public.commission_group_component_limits TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commission_groups; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.commission_groups ENABLE ROW LEVEL SECURITY;

--
-- Name: commission_groups commission_groups_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commission_groups_insert_manager ON public.commission_groups FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commission_groups commission_groups_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commission_groups_select ON public.commission_groups FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: commission_groups commission_groups_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commission_groups_update_manager ON public.commission_groups FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commission_rule_components; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.commission_rule_components ENABLE ROW LEVEL SECURITY;

--
-- Name: commission_rule_components commission_rule_components_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commission_rule_components_insert_manager ON public.commission_rule_components FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: commission_rule_components commission_rule_components_select_supervisor_plus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commission_rule_components_select_supervisor_plus ON public.commission_rule_components FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: commission_rule_components commission_rule_components_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY commission_rule_components_update_manager ON public.commission_rule_components FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: component_payout_policies; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.component_payout_policies ENABLE ROW LEVEL SECURITY;

--
-- Name: component_payout_policies component_payout_policies_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY component_payout_policies_insert ON public.component_payout_policies FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: component_payout_policies component_payout_policies_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY component_payout_policies_select ON public.component_payout_policies FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: component_payout_policies component_payout_policies_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY component_payout_policies_update ON public.component_payout_policies FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: component_payout_policy_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.component_payout_policy_items ENABLE ROW LEVEL SECURITY;

--
-- Name: component_payout_policy_items component_payout_policy_items_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY component_payout_policy_items_insert ON public.component_payout_policy_items FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: component_payout_policy_items component_payout_policy_items_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY component_payout_policy_items_select ON public.component_payout_policy_items FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: component_payout_policy_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.component_payout_policy_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: component_payout_policy_versions component_payout_policy_versions_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY component_payout_policy_versions_insert ON public.component_payout_policy_versions FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: component_payout_policy_versions component_payout_policy_versions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY component_payout_policy_versions_select ON public.component_payout_policy_versions FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: contract_types; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contract_types ENABLE ROW LEVEL SECURITY;

--
-- Name: contract_types contract_types_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contract_types_insert_manager ON public.contract_types FOR INSERT TO authenticated WITH CHECK (((organization_id IS NOT NULL) AND public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])));


--
-- Name: contract_types contract_types_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contract_types_read ON public.contract_types FOR SELECT TO authenticated USING (((organization_id IS NULL) OR public.is_active_organization_member(organization_id)));


--
-- Name: contract_types contract_types_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contract_types_update_manager ON public.contract_types FOR UPDATE TO authenticated USING (((organization_id IS NOT NULL) AND public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((organization_id IS NOT NULL) AND public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])));


--
-- Name: contracts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contracts ENABLE ROW LEVEL SECURITY;

--
-- Name: contracts contracts_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contracts_insert_member ON public.contracts FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: contracts contracts_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contracts_select_member ON public.contracts FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: contracts contracts_update_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY contracts_update_member ON public.contracts FOR UPDATE TO authenticated USING (public.is_active_organization_member(organization_id)) WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: customer_addresses; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customer_addresses ENABLE ROW LEVEL SECURITY;

--
-- Name: customer_addresses customer_addresses_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customer_addresses_insert_member ON public.customer_addresses FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: customer_addresses customer_addresses_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customer_addresses_select_member ON public.customer_addresses FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: customer_addresses customer_addresses_update_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customer_addresses_update_member ON public.customer_addresses FOR UPDATE TO authenticated USING (public.is_active_organization_member(organization_id)) WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: customer_bank_accounts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customer_bank_accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: customer_bank_accounts customer_bank_accounts_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customer_bank_accounts_insert_member ON public.customer_bank_accounts FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: customer_bank_accounts customer_bank_accounts_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customer_bank_accounts_select_member ON public.customer_bank_accounts FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: customer_bank_accounts customer_bank_accounts_update_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customer_bank_accounts_update_member ON public.customer_bank_accounts FOR UPDATE TO authenticated USING (public.is_active_organization_member(organization_id)) WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: customer_documents; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customer_documents ENABLE ROW LEVEL SECURITY;

--
-- Name: customer_documents customer_documents_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customer_documents_insert_member ON public.customer_documents FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: customer_documents customer_documents_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customer_documents_select_member ON public.customer_documents FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: customer_documents customer_documents_update_supervisor; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customer_documents_update_supervisor ON public.customer_documents FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: customer_pix_keys; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customer_pix_keys ENABLE ROW LEVEL SECURITY;

--
-- Name: customer_pix_keys customer_pix_keys_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customer_pix_keys_insert_member ON public.customer_pix_keys FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: customer_pix_keys customer_pix_keys_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customer_pix_keys_select_member ON public.customer_pix_keys FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: customer_pix_keys customer_pix_keys_update_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customer_pix_keys_update_member ON public.customer_pix_keys FOR UPDATE TO authenticated USING (public.is_active_organization_member(organization_id)) WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: customer_timeline_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customer_timeline_events ENABLE ROW LEVEL SECURITY;

--
-- Name: customer_timeline_events customer_timeline_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customer_timeline_insert_member ON public.customer_timeline_events FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: customer_timeline_events customer_timeline_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customer_timeline_select_member ON public.customer_timeline_events FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: digitization_jobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.digitization_jobs ENABLE ROW LEVEL SECURITY;

--
-- Name: digitization_jobs digitization_jobs_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY digitization_jobs_insert_member ON public.digitization_jobs FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: digitization_jobs digitization_jobs_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY digitization_jobs_select_member ON public.digitization_jobs FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: digitization_jobs digitization_jobs_update_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY digitization_jobs_update_member ON public.digitization_jobs FOR UPDATE TO authenticated USING (public.is_active_organization_member(organization_id)) WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: document_checklist_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.document_checklist_items ENABLE ROW LEVEL SECURITY;

--
-- Name: document_checklist_items document_checklist_items_insert_draft_supervisor; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY document_checklist_items_insert_draft_supervisor ON public.document_checklist_items FOR INSERT TO authenticated WITH CHECK ((public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]) AND (EXISTS ( SELECT 1
   FROM public.document_checklist_templates t
  WHERE ((t.organization_id = document_checklist_items.organization_id) AND (t.id = document_checklist_items.template_id) AND (t.status = 'draft'::text))))));


--
-- Name: document_checklist_items document_checklist_items_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY document_checklist_items_select_member ON public.document_checklist_items FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: document_checklist_items document_checklist_items_update_draft_supervisor; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY document_checklist_items_update_draft_supervisor ON public.document_checklist_items FOR UPDATE TO authenticated USING ((public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]) AND (EXISTS ( SELECT 1
   FROM public.document_checklist_templates t
  WHERE ((t.organization_id = document_checklist_items.organization_id) AND (t.id = document_checklist_items.template_id) AND (t.status = 'draft'::text)))))) WITH CHECK ((public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]) AND (EXISTS ( SELECT 1
   FROM public.document_checklist_templates t
  WHERE ((t.organization_id = document_checklist_items.organization_id) AND (t.id = document_checklist_items.template_id) AND (t.status = 'draft'::text))))));


--
-- Name: document_checklist_templates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.document_checklist_templates ENABLE ROW LEVEL SECURITY;

--
-- Name: document_checklist_templates document_checklist_templates_insert_supervisor; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY document_checklist_templates_insert_supervisor ON public.document_checklist_templates FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: document_checklist_templates document_checklist_templates_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY document_checklist_templates_select_member ON public.document_checklist_templates FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: document_checklist_templates document_checklist_templates_update_supervisor; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY document_checklist_templates_update_supervisor ON public.document_checklist_templates FOR UPDATE TO authenticated USING (((status = ANY (ARRAY['draft'::text, 'published'::text])) AND public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]))) WITH CHECK (((status = ANY (ARRAY['draft'::text, 'published'::text, 'superseded'::text])) AND public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text])));


--
-- Name: document_types; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.document_types ENABLE ROW LEVEL SECURITY;

--
-- Name: document_types document_types_authenticated_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY document_types_authenticated_read ON public.document_types FOR SELECT TO authenticated USING (true);


--
-- Name: financial_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.financial_events ENABLE ROW LEVEL SECURITY;

--
-- Name: financial_events financial_events_insert_guarded_actor; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY financial_events_insert_guarded_actor ON public.financial_events FOR INSERT TO authenticated WITH CHECK ((public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]) AND (created_by = ( SELECT auth.uid() AS uid))));


--
-- Name: financial_events financial_events_select_scoped; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY financial_events_select_scoped ON public.financial_events FOR SELECT TO authenticated USING ((public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]) OR (public.has_active_organization_role(organization_id, ARRAY['supervisor'::text]) AND (proposal_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM public.proposals_v2 p
  WHERE ((p.organization_id = financial_events.organization_id) AND (p.id = financial_events.proposal_id) AND (p.seller_id IS NOT NULL) AND public.can_view_seller_commission(p.organization_id, p.seller_id)))))));


--
-- Name: financial_evidence_links; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.financial_evidence_links ENABLE ROW LEVEL SECURITY;

--
-- Name: financial_evidence_links financial_evidence_links_insert_guarded_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY financial_evidence_links_insert_guarded_member ON public.financial_evidence_links FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: financial_evidence_links financial_evidence_links_select_supervisor_plus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY financial_evidence_links_select_supervisor_plus ON public.financial_evidence_links FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: financial_reconciliation_cases; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.financial_reconciliation_cases ENABLE ROW LEVEL SECURITY;

--
-- Name: financial_reconciliation_cases financial_reconciliation_cases_insert_guarded; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY financial_reconciliation_cases_insert_guarded ON public.financial_reconciliation_cases FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: financial_reconciliation_cases financial_reconciliation_cases_select_scoped; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY financial_reconciliation_cases_select_scoped ON public.financial_reconciliation_cases FOR SELECT TO authenticated USING ((public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]) OR (public.has_active_organization_role(organization_id, ARRAY['supervisor'::text]) AND (proposal_id IS NOT NULL) AND (EXISTS ( SELECT 1
   FROM public.proposals_v2 p
  WHERE ((p.organization_id = financial_reconciliation_cases.organization_id) AND (p.id = financial_reconciliation_cases.proposal_id) AND (p.seller_id IS NOT NULL) AND public.can_view_seller_commission(p.organization_id, p.seller_id)))))));


--
-- Name: financial_reconciliation_cases financial_reconciliation_cases_update_guarded; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY financial_reconciliation_cases_update_guarded ON public.financial_reconciliation_cases FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: import_applied_decisions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.import_applied_decisions ENABLE ROW LEVEL SECURITY;

--
-- Name: import_applied_decisions import_applied_decisions_insert_supervisor_plus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_applied_decisions_insert_supervisor_plus ON public.import_applied_decisions FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: import_applied_decisions import_applied_decisions_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_applied_decisions_select_member ON public.import_applied_decisions FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: import_batches; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.import_batches ENABLE ROW LEVEL SECURITY;

--
-- Name: import_batches import_batches_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_batches_insert_member ON public.import_batches FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: import_batches import_batches_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_batches_select_member ON public.import_batches FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: import_conflict_rows; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.import_conflict_rows ENABLE ROW LEVEL SECURITY;

--
-- Name: import_conflict_rows import_conflict_rows_insert_supervisor_plus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_conflict_rows_insert_supervisor_plus ON public.import_conflict_rows FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: import_conflict_rows import_conflict_rows_select_supervisor_plus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_conflict_rows_select_supervisor_plus ON public.import_conflict_rows FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: import_conflicts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.import_conflicts ENABLE ROW LEVEL SECURITY;

--
-- Name: import_conflicts import_conflicts_insert_supervisor_plus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_conflicts_insert_supervisor_plus ON public.import_conflicts FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: import_conflicts import_conflicts_select_supervisor_plus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_conflicts_select_supervisor_plus ON public.import_conflicts FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: import_conflicts import_conflicts_update_supervisor_plus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_conflicts_update_supervisor_plus ON public.import_conflicts FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: import_decisions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.import_decisions ENABLE ROW LEVEL SECURITY;

--
-- Name: import_decisions import_decisions_insert_supervisor; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_decisions_insert_supervisor ON public.import_decisions FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: import_decisions import_decisions_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_decisions_select_member ON public.import_decisions FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: import_jobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.import_jobs ENABLE ROW LEVEL SECURITY;

--
-- Name: import_jobs import_jobs_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_jobs_insert_member ON public.import_jobs FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: import_jobs import_jobs_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_jobs_select_member ON public.import_jobs FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: import_jobs import_jobs_update_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_jobs_update_member ON public.import_jobs FOR UPDATE TO authenticated USING (public.is_active_organization_member(organization_id)) WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: import_layout_mappings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.import_layout_mappings ENABLE ROW LEVEL SECURITY;

--
-- Name: import_layout_mappings import_layout_mappings_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_layout_mappings_insert ON public.import_layout_mappings FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: import_layout_mappings import_layout_mappings_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_layout_mappings_select ON public.import_layout_mappings FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: import_layout_mappings import_layout_mappings_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_layout_mappings_update ON public.import_layout_mappings FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: import_match_candidates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.import_match_candidates ENABLE ROW LEVEL SECURITY;

--
-- Name: import_match_candidates import_match_candidates_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_match_candidates_insert_member ON public.import_match_candidates FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: import_match_candidates import_match_candidates_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_match_candidates_select_member ON public.import_match_candidates FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: import_normalized_rows; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.import_normalized_rows ENABLE ROW LEVEL SECURITY;

--
-- Name: import_normalized_rows import_normalized_rows_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_normalized_rows_insert_member ON public.import_normalized_rows FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: import_normalized_rows import_normalized_rows_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_normalized_rows_select_member ON public.import_normalized_rows FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: import_raw_rows; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.import_raw_rows ENABLE ROW LEVEL SECURITY;

--
-- Name: import_raw_rows import_raw_rows_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_raw_rows_insert_member ON public.import_raw_rows FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: import_raw_rows import_raw_rows_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_raw_rows_select_member ON public.import_raw_rows FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: import_sources; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.import_sources ENABLE ROW LEVEL SECURITY;

--
-- Name: import_sources import_sources_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_sources_insert_manager ON public.import_sources FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: import_sources import_sources_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_sources_select_member ON public.import_sources FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: import_sources import_sources_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY import_sources_update_manager ON public.import_sources FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: integration_adapters; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.integration_adapters ENABLE ROW LEVEL SECURITY;

--
-- Name: integration_adapters integration_adapters_authenticated_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY integration_adapters_authenticated_read ON public.integration_adapters FOR SELECT TO authenticated USING (true);


--
-- Name: integration_field_mappings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.integration_field_mappings ENABLE ROW LEVEL SECURITY;

--
-- Name: integration_field_mappings integration_field_mappings_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY integration_field_mappings_read ON public.integration_field_mappings FOR SELECT TO authenticated USING (true);


--
-- Name: integration_run_artifacts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.integration_run_artifacts ENABLE ROW LEVEL SECURITY;

--
-- Name: integration_run_artifacts integration_run_artifacts_select_supervisor_plus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY integration_run_artifacts_select_supervisor_plus ON public.integration_run_artifacts FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: integration_runs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.integration_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: integration_runs integration_runs_select_supervisor_plus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY integration_runs_select_supervisor_plus ON public.integration_runs FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: integration_source_bindings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.integration_source_bindings ENABLE ROW LEVEL SECURITY;

--
-- Name: integration_source_bindings integration_source_bindings_org_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY integration_source_bindings_org_read ON public.integration_source_bindings FOR SELECT TO authenticated USING ((organization_id IN ( SELECT organization_memberships.organization_id
   FROM public.organization_memberships
  WHERE ((organization_memberships.user_id = ( SELECT auth.uid() AS uid)) AND (organization_memberships.status = 'active'::text)))));


--
-- Name: lead_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.lead_events ENABLE ROW LEVEL SECURITY;

--
-- Name: lead_events lead_events_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lead_events_select_member ON public.lead_events FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: leads; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.leads ENABLE ROW LEVEL SECURITY;

--
-- Name: leads leads_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY leads_select_member ON public.leads FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: modalities; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.modalities ENABLE ROW LEVEL SECURITY;

--
-- Name: modalities modalities_authenticated_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY modalities_authenticated_read ON public.modalities FOR SELECT TO authenticated USING (true);


--
-- Name: national_agreement_templates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.national_agreement_templates ENABLE ROW LEVEL SECURITY;

--
-- Name: national_agreement_templates national_agreement_templates_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY national_agreement_templates_read ON public.national_agreement_templates FOR SELECT TO authenticated USING (true);


--
-- Name: network_split_rule_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.network_split_rule_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: network_split_rule_versions network_split_rule_versions_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY network_split_rule_versions_insert_manager ON public.network_split_rule_versions FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: network_split_rule_versions network_split_rule_versions_select_supervisor_plus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY network_split_rule_versions_select_supervisor_plus ON public.network_split_rule_versions FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: network_split_rule_versions network_split_rule_versions_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY network_split_rule_versions_update_manager ON public.network_split_rule_versions FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: operational_attention_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.operational_attention_events ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_attention_events operational_attention_events_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY operational_attention_events_insert ON public.operational_attention_events FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: operational_attention_events operational_attention_events_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY operational_attention_events_select ON public.operational_attention_events FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: operational_attention_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.operational_attention_items ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_attention_items operational_attention_items_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY operational_attention_items_insert ON public.operational_attention_items FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: operational_attention_items operational_attention_items_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY operational_attention_items_select ON public.operational_attention_items FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: operational_attention_items operational_attention_items_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY operational_attention_items_update ON public.operational_attention_items FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: operational_cases; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.operational_cases ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_cases operational_cases_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY operational_cases_insert_member ON public.operational_cases FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: operational_cases operational_cases_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY operational_cases_select_member ON public.operational_cases FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: operational_cases operational_cases_update_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY operational_cases_update_member ON public.operational_cases FOR UPDATE TO authenticated USING (public.is_active_organization_member(organization_id)) WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: operational_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.operational_events ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_events operational_events_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY operational_events_insert_member ON public.operational_events FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: operational_events operational_events_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY operational_events_select_member ON public.operational_events FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: operational_stages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.operational_stages ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_stages operational_stages_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY operational_stages_insert_manager ON public.operational_stages FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: operational_stages operational_stages_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY operational_stages_select_member ON public.operational_stages FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: operational_stages operational_stages_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY operational_stages_update_manager ON public.operational_stages FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: organization_admin_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.organization_admin_events ENABLE ROW LEVEL SECURITY;

--
-- Name: organization_admin_events organization_admin_events_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_admin_events_insert ON public.organization_admin_events FOR INSERT TO authenticated WITH CHECK (((private.caller_role_in(organization_id) = ANY (ARRAY['admin'::text, 'manager'::text])) AND (actor_user_id = ( SELECT auth.uid() AS uid))));


--
-- Name: organization_admin_events organization_admin_events_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_admin_events_select ON public.organization_admin_events FOR SELECT TO authenticated USING ((private.caller_role_in(organization_id) = ANY (ARRAY['admin'::text, 'manager'::text])));


--
-- Name: organization_agreements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.organization_agreements ENABLE ROW LEVEL SECURITY;

--
-- Name: organization_agreements organization_agreements_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_agreements_insert_manager ON public.organization_agreements FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: organization_agreements organization_agreements_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_agreements_select ON public.organization_agreements FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: organization_agreements organization_agreements_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_agreements_update_manager ON public.organization_agreements FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: organization_ai_limits; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.organization_ai_limits ENABLE ROW LEVEL SECURITY;

--
-- Name: organization_ai_limits organization_ai_limits_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_ai_limits_select ON public.organization_ai_limits FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: organization_banks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.organization_banks ENABLE ROW LEVEL SECURITY;

--
-- Name: organization_banks organization_banks_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_banks_insert_manager ON public.organization_banks FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: organization_banks organization_banks_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_banks_select ON public.organization_banks FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: organization_banks organization_banks_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_banks_update_manager ON public.organization_banks FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: organization_branches; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.organization_branches ENABLE ROW LEVEL SECURITY;

--
-- Name: organization_branches organization_branches_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_branches_select_member ON public.organization_branches FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: organization_branches organization_branches_write_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_branches_write_manager ON public.organization_branches TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: organization_contract_type_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.organization_contract_type_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: organization_contract_type_settings organization_contract_type_settings_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_contract_type_settings_insert_manager ON public.organization_contract_type_settings FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: organization_contract_type_settings organization_contract_type_settings_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_contract_type_settings_select ON public.organization_contract_type_settings FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: organization_contract_type_settings organization_contract_type_settings_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_contract_type_settings_update_manager ON public.organization_contract_type_settings FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: organization_invitations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.organization_invitations ENABLE ROW LEVEL SECURITY;

--
-- Name: organization_invitations organization_invitations_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_invitations_insert ON public.organization_invitations FOR INSERT TO authenticated WITH CHECK ((private.caller_role_in(organization_id) = ANY (ARRAY['admin'::text, 'manager'::text])));


--
-- Name: organization_invitations organization_invitations_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_invitations_select ON public.organization_invitations FOR SELECT TO authenticated USING ((private.caller_role_in(organization_id) = ANY (ARRAY['admin'::text, 'manager'::text])));


--
-- Name: organization_invitations organization_invitations_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_invitations_update ON public.organization_invitations FOR UPDATE TO authenticated USING ((private.caller_role_in(organization_id) = ANY (ARRAY['admin'::text, 'manager'::text]))) WITH CHECK ((private.caller_role_in(organization_id) = ANY (ARRAY['admin'::text, 'manager'::text])));


--
-- Name: organization_memberships; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.organization_memberships ENABLE ROW LEVEL SECURITY;

--
-- Name: organization_memberships organization_memberships_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_memberships_select ON public.organization_memberships FOR SELECT TO authenticated USING ((((user_id = ( SELECT auth.uid() AS uid)) AND (status = 'active'::text)) OR (private.caller_role_in(organization_id) = ANY (ARRAY['admin'::text, 'manager'::text]))));


--
-- Name: organization_memberships organization_memberships_update_team; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_memberships_update_team ON public.organization_memberships FOR UPDATE TO authenticated USING ((private.caller_role_in(organization_id) = ANY (ARRAY['admin'::text, 'manager'::text]))) WITH CHECK ((private.caller_role_in(organization_id) = ANY (ARRAY['admin'::text, 'manager'::text])));


--
-- Name: organization_product_routes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.organization_product_routes ENABLE ROW LEVEL SECURITY;

--
-- Name: organization_product_routes organization_product_routes_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_product_routes_insert_manager ON public.organization_product_routes FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: organization_product_routes organization_product_routes_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_product_routes_select_member ON public.organization_product_routes FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: organization_product_routes organization_product_routes_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_product_routes_update_manager ON public.organization_product_routes FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: organization_providers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.organization_providers ENABLE ROW LEVEL SECURITY;

--
-- Name: organization_providers organization_providers_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_providers_insert_manager ON public.organization_providers FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: organization_providers organization_providers_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_providers_select ON public.organization_providers FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: organization_providers organization_providers_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organization_providers_update_manager ON public.organization_providers FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: organizations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;

--
-- Name: organizations organizations_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY organizations_select_member ON public.organizations FOR SELECT TO authenticated USING (public.is_active_organization_member(id));


--
-- Name: payout_policies; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.payout_policies ENABLE ROW LEVEL SECURITY;

--
-- Name: payout_policies payout_policies_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY payout_policies_insert ON public.payout_policies FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: payout_policies payout_policies_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY payout_policies_select ON public.payout_policies FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: payout_policies payout_policies_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY payout_policies_update ON public.payout_policies FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: payout_policy_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.payout_policy_items ENABLE ROW LEVEL SECURITY;

--
-- Name: payout_policy_items payout_policy_items_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY payout_policy_items_insert ON public.payout_policy_items FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: payout_policy_items payout_policy_items_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY payout_policy_items_select ON public.payout_policy_items FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: payout_policy_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.payout_policy_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: payout_policy_versions payout_policy_versions_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY payout_policy_versions_insert ON public.payout_policy_versions FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: payout_policy_versions payout_policy_versions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY payout_policy_versions_select ON public.payout_policy_versions FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: platform_admin_audit_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.platform_admin_audit_events ENABLE ROW LEVEL SECURITY;

--
-- Name: platform_administrators; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.platform_administrators ENABLE ROW LEVEL SECURITY;

--
-- Name: product_table_external_identities; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.product_table_external_identities ENABLE ROW LEVEL SECURITY;

--
-- Name: product_table_external_identities product_table_external_identities_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_table_external_identities_insert_manager ON public.product_table_external_identities FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: product_table_external_identities product_table_external_identities_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_table_external_identities_select_member ON public.product_table_external_identities FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: product_table_external_identities product_table_external_identities_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_table_external_identities_update_manager ON public.product_table_external_identities FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: product_table_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.product_table_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: product_table_versions product_table_versions_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_table_versions_insert_manager ON public.product_table_versions FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: product_table_versions product_table_versions_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_table_versions_select_member ON public.product_table_versions FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: product_table_versions product_table_versions_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_table_versions_update_manager ON public.product_table_versions FOR UPDATE TO authenticated USING (((status = ANY (ARRAY['draft'::text, 'published'::text])) AND public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]))) WITH CHECK (((status = ANY (ARRAY['draft'::text, 'published'::text, 'superseded'::text])) AND public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])));


--
-- Name: product_tables; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.product_tables ENABLE ROW LEVEL SECURITY;

--
-- Name: product_tables product_tables_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_tables_insert_manager ON public.product_tables FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: product_tables product_tables_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_tables_select_member ON public.product_tables FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: product_tables product_tables_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_tables_update_manager ON public.product_tables FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: products; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

--
-- Name: products products_authenticated_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY products_authenticated_read ON public.products FOR SELECT TO authenticated USING (true);


--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles profiles_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_select_member ON public.profiles FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: proposal_commercial_component_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.proposal_commercial_component_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: proposal_commercial_component_snapshots proposal_commercial_component_snapshots_select_scoped; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposal_commercial_component_snapshots_select_scoped ON public.proposal_commercial_component_snapshots FOR SELECT TO authenticated USING ((public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]) OR (public.has_active_organization_role(organization_id, ARRAY['supervisor'::text]) AND (seller_id IS NOT NULL) AND public.can_view_seller_commission(organization_id, seller_id))));


--
-- Name: proposal_commercial_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.proposal_commercial_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: proposal_commercial_snapshots proposal_commercial_snapshots_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposal_commercial_snapshots_insert_member ON public.proposal_commercial_snapshots FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: proposal_commercial_snapshots proposal_commercial_snapshots_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposal_commercial_snapshots_select_member ON public.proposal_commercial_snapshots FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: proposal_commercial_component_snapshots proposal_component_snapshot_insert_guarded; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposal_component_snapshot_insert_guarded ON public.proposal_commercial_component_snapshots FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: proposal_document_links; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.proposal_document_links ENABLE ROW LEVEL SECURITY;

--
-- Name: proposal_document_links proposal_document_links_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposal_document_links_insert_member ON public.proposal_document_links FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: proposal_document_links proposal_document_links_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposal_document_links_select_member ON public.proposal_document_links FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: proposal_document_requirements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.proposal_document_requirements ENABLE ROW LEVEL SECURITY;

--
-- Name: proposal_document_requirements proposal_document_requirements_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposal_document_requirements_insert_member ON public.proposal_document_requirements FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: proposal_document_requirements proposal_document_requirements_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposal_document_requirements_select_member ON public.proposal_document_requirements FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: proposal_document_requirements proposal_document_requirements_update_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposal_document_requirements_update_member ON public.proposal_document_requirements FOR UPDATE TO authenticated USING (public.is_active_organization_member(organization_id)) WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: proposal_external_identities; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.proposal_external_identities ENABLE ROW LEVEL SECURITY;

--
-- Name: proposal_external_identities proposal_external_identities_insert_supervisor_plus; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposal_external_identities_insert_supervisor_plus ON public.proposal_external_identities FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: proposal_external_identities proposal_external_identities_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposal_external_identities_select_member ON public.proposal_external_identities FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: proposal_seller_commission_snapshots proposal_seller_commission_insert_governed; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposal_seller_commission_insert_governed ON public.proposal_seller_commission_snapshots FOR INSERT TO authenticated WITH CHECK ((public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]) AND (current_setting('corban.seller_commission_snapshot'::text, true) = 'on'::text)));


--
-- Name: proposal_seller_commission_snapshots proposal_seller_commission_select_scoped; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposal_seller_commission_select_scoped ON public.proposal_seller_commission_snapshots FOR SELECT TO authenticated USING (public.can_view_seller_commission(organization_id, seller_id));


--
-- Name: proposal_seller_commission_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.proposal_seller_commission_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: proposal_status_evidence; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.proposal_status_evidence ENABLE ROW LEVEL SECURITY;

--
-- Name: proposal_status_evidence proposal_status_evidence_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposal_status_evidence_insert ON public.proposal_status_evidence FOR INSERT TO authenticated WITH CHECK ((public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]) AND (created_by = ( SELECT auth.uid() AS uid))));


--
-- Name: proposal_status_evidence proposal_status_evidence_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposal_status_evidence_select ON public.proposal_status_evidence FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: proposals_v2; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.proposals_v2 ENABLE ROW LEVEL SECURITY;

--
-- Name: proposals_v2 proposals_v2_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposals_v2_insert_member ON public.proposals_v2 FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: proposals_v2 proposals_v2_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposals_v2_select_member ON public.proposals_v2 FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: proposals_v2 proposals_v2_update_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY proposals_v2_update_member ON public.proposals_v2 FOR UPDATE TO authenticated USING (public.is_active_organization_member(organization_id)) WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: providers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.providers ENABLE ROW LEVEL SECURITY;

--
-- Name: providers providers_authenticated_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY providers_authenticated_read ON public.providers FOR SELECT TO authenticated USING (true);


--
-- Name: seller_addresses; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.seller_addresses ENABLE ROW LEVEL SECURITY;

--
-- Name: seller_addresses seller_addresses_select_scoped; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_addresses_select_scoped ON public.seller_addresses FOR SELECT TO authenticated USING (public.can_view_seller_profile(organization_id, seller_id));


--
-- Name: seller_addresses seller_addresses_write_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_addresses_write_manager ON public.seller_addresses TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: seller_bank_aliases; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.seller_bank_aliases ENABLE ROW LEVEL SECURITY;

--
-- Name: seller_bank_aliases seller_bank_aliases_select_scoped; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_bank_aliases_select_scoped ON public.seller_bank_aliases FOR SELECT TO authenticated USING ((public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]) OR public.can_view_seller_profile(organization_id, seller_id)));


--
-- Name: seller_bank_aliases seller_bank_aliases_write_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_bank_aliases_write_manager ON public.seller_bank_aliases TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: seller_certifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.seller_certifications ENABLE ROW LEVEL SECURITY;

--
-- Name: seller_certifications seller_certifications_select_scoped; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_certifications_select_scoped ON public.seller_certifications FOR SELECT TO authenticated USING (public.can_view_seller_profile(organization_id, seller_id));


--
-- Name: seller_certifications seller_certifications_write_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_certifications_write_manager ON public.seller_certifications TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: seller_groups; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.seller_groups ENABLE ROW LEVEL SECURITY;

--
-- Name: seller_groups seller_groups_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_groups_insert_manager ON public.seller_groups FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: seller_groups seller_groups_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_groups_select_member ON public.seller_groups FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: seller_groups seller_groups_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_groups_update_manager ON public.seller_groups FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: seller_payment_accounts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.seller_payment_accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: seller_payment_accounts seller_payment_accounts_select_scoped; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_payment_accounts_select_scoped ON public.seller_payment_accounts FOR SELECT TO authenticated USING (public.can_view_seller_payment(organization_id, seller_id));


--
-- Name: seller_payment_accounts seller_payment_accounts_write_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_payment_accounts_write_manager ON public.seller_payment_accounts TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: seller_profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.seller_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: seller_profiles seller_profiles_select_scoped; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_profiles_select_scoped ON public.seller_profiles FOR SELECT TO authenticated USING (public.can_view_seller_profile(organization_id, seller_id));


--
-- Name: seller_profiles seller_profiles_write_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_profiles_write_manager ON public.seller_profiles TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: seller_sub_rule_versions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.seller_sub_rule_versions ENABLE ROW LEVEL SECURITY;

--
-- Name: seller_sub_rule_versions seller_sub_rule_versions_delete_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_sub_rule_versions_delete_manager ON public.seller_sub_rule_versions FOR DELETE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: seller_sub_rule_versions seller_sub_rule_versions_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_sub_rule_versions_insert_manager ON public.seller_sub_rule_versions FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: seller_sub_rule_versions seller_sub_rule_versions_select_supervisor; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_sub_rule_versions_select_supervisor ON public.seller_sub_rule_versions FOR SELECT TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text, 'supervisor'::text]));


--
-- Name: seller_sub_rule_versions seller_sub_rule_versions_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_sub_rule_versions_update_manager ON public.seller_sub_rule_versions FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: seller_supervisions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.seller_supervisions ENABLE ROW LEVEL SECURITY;

--
-- Name: seller_supervisions seller_supervisions_insert_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_supervisions_insert_manager ON public.seller_supervisions FOR INSERT TO authenticated WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: seller_supervisions seller_supervisions_select_scoped; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_supervisions_select_scoped ON public.seller_supervisions FOR SELECT TO authenticated USING ((public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]) OR (public.has_active_organization_role(organization_id, ARRAY['supervisor'::text]) AND (supervisor_user_id = auth.uid()))));


--
-- Name: seller_supervisions seller_supervisions_update_manager; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY seller_supervisions_update_manager ON public.seller_supervisions FOR UPDATE TO authenticated USING (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text])) WITH CHECK (public.has_active_organization_role(organization_id, ARRAY['admin'::text, 'manager'::text]));


--
-- Name: simulations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.simulations ENABLE ROW LEVEL SECURITY;

--
-- Name: simulations simulations_insert_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY simulations_insert_member ON public.simulations FOR INSERT TO authenticated WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: simulations simulations_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY simulations_select_member ON public.simulations FOR SELECT TO authenticated USING (public.is_active_organization_member(organization_id));


--
-- Name: simulations simulations_update_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY simulations_update_member ON public.simulations FOR UPDATE TO authenticated USING (public.is_active_organization_member(organization_id)) WITH CHECK (public.is_active_organization_member(organization_id));


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION accept_organization_invitations(p_user_id uuid, p_email text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.accept_organization_invitations(p_user_id uuid, p_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.accept_organization_invitations(p_user_id uuid, p_email text) TO service_role;


--
-- Name: FUNCTION ai_credit_balance(p_organization uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.ai_credit_balance(p_organization uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.ai_credit_balance(p_organization uuid) TO authenticated;
GRANT ALL ON FUNCTION public.ai_credit_balance(p_organization uuid) TO service_role;


--
-- Name: FUNCTION apply_approved_import_match(p_decision_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.apply_approved_import_match(p_decision_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.apply_approved_import_match(p_decision_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.apply_approved_import_match(p_decision_id uuid) TO service_role;


--
-- Name: FUNCTION apply_smart_commercial_remittance(p_organization uuid, p_production_origin text, p_provider uuid, p_policy_version uuid, p_rows jsonb, p_mode text, p_remittance_effective_from timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.apply_smart_commercial_remittance(p_organization uuid, p_production_origin text, p_provider uuid, p_policy_version uuid, p_rows jsonb, p_mode text, p_remittance_effective_from timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.apply_smart_commercial_remittance(p_organization uuid, p_production_origin text, p_provider uuid, p_policy_version uuid, p_rows jsonb, p_mode text, p_remittance_effective_from timestamp with time zone) TO authenticated;
GRANT ALL ON FUNCTION public.apply_smart_commercial_remittance(p_organization uuid, p_production_origin text, p_provider uuid, p_policy_version uuid, p_rows jsonb, p_mode text, p_remittance_effective_from timestamp with time zone) TO service_role;


--
-- Name: FUNCTION assert_same_organization_reference(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.assert_same_organization_reference() FROM PUBLIC;
GRANT ALL ON FUNCTION public.assert_same_organization_reference() TO service_role;


--
-- Name: FUNCTION assign_attention_item(p_item uuid, p_assignee uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.assign_attention_item(p_item uuid, p_assignee uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.assign_attention_item(p_item uuid, p_assignee uuid) TO authenticated;
GRANT ALL ON FUNCTION public.assign_attention_item(p_item uuid, p_assignee uuid) TO service_role;


--
-- Name: FUNCTION assign_proposal_seller(p_proposal_id uuid, p_seller_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.assign_proposal_seller(p_proposal_id uuid, p_seller_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.assign_proposal_seller(p_proposal_id uuid, p_seller_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.assign_proposal_seller(p_proposal_id uuid, p_seller_id uuid) TO service_role;


--
-- Name: FUNCTION attach_import_batch_adapter(p_batch_id uuid, p_adapter_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.attach_import_batch_adapter(p_batch_id uuid, p_adapter_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.attach_import_batch_adapter(p_batch_id uuid, p_adapter_key text) TO authenticated;
GRANT ALL ON FUNCTION public.attach_import_batch_adapter(p_batch_id uuid, p_adapter_key text) TO service_role;


--
-- Name: FUNCTION bootstrap_organization_admin(p_platform_actor_user_id uuid, p_user_id uuid, p_organization_name text, p_organization_document text, p_plan_type text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.bootstrap_organization_admin(p_platform_actor_user_id uuid, p_user_id uuid, p_organization_name text, p_organization_document text, p_plan_type text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.bootstrap_organization_admin(p_platform_actor_user_id uuid, p_user_id uuid, p_organization_name text, p_organization_document text, p_plan_type text) TO service_role;


--
-- Name: FUNCTION can_manage_member_role(p_actor text, p_target_current text, p_target_new text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.can_manage_member_role(p_actor text, p_target_current text, p_target_new text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.can_manage_member_role(p_actor text, p_target_current text, p_target_new text) TO authenticated;
GRANT ALL ON FUNCTION public.can_manage_member_role(p_actor text, p_target_current text, p_target_new text) TO service_role;


--
-- Name: FUNCTION can_view_seller_commission(p_organization_id uuid, p_seller_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.can_view_seller_commission(p_organization_id uuid, p_seller_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.can_view_seller_commission(p_organization_id uuid, p_seller_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.can_view_seller_commission(p_organization_id uuid, p_seller_id uuid) TO service_role;


--
-- Name: FUNCTION can_view_seller_payment(p_org uuid, p_seller uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.can_view_seller_payment(p_org uuid, p_seller uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.can_view_seller_payment(p_org uuid, p_seller uuid) TO authenticated;
GRANT ALL ON FUNCTION public.can_view_seller_payment(p_org uuid, p_seller uuid) TO service_role;


--
-- Name: FUNCTION can_view_seller_profile(p_org uuid, p_seller uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.can_view_seller_profile(p_org uuid, p_seller uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.can_view_seller_profile(p_org uuid, p_seller uuid) TO authenticated;
GRANT ALL ON FUNCTION public.can_view_seller_profile(p_org uuid, p_seller uuid) TO service_role;


--
-- Name: FUNCTION cancel_integration_run(p_org uuid, p_run uuid, p_actor uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cancel_integration_run(p_org uuid, p_run uuid, p_actor uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cancel_integration_run(p_org uuid, p_run uuid, p_actor uuid) TO service_role;


--
-- Name: FUNCTION claim_integration_run(p_org uuid, p_binding uuid, p_capability text, p_fingerprint text, p_actor uuid, p_max_attempts integer, p_lease_seconds integer, p_request jsonb, p_correlation text, p_now timestamp with time zone, p_adapter_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.claim_integration_run(p_org uuid, p_binding uuid, p_capability text, p_fingerprint text, p_actor uuid, p_max_attempts integer, p_lease_seconds integer, p_request jsonb, p_correlation text, p_now timestamp with time zone, p_adapter_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.claim_integration_run(p_org uuid, p_binding uuid, p_capability text, p_fingerprint text, p_actor uuid, p_max_attempts integer, p_lease_seconds integer, p_request jsonb, p_correlation text, p_now timestamp with time zone, p_adapter_key text) TO service_role;


--
-- Name: FUNCTION close_simulation(p_simulation_id uuid, p_target_status text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.close_simulation(p_simulation_id uuid, p_target_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.close_simulation(p_simulation_id uuid, p_target_status text) TO authenticated;
GRANT ALL ON FUNCTION public.close_simulation(p_simulation_id uuid, p_target_status text) TO service_role;


--
-- Name: FUNCTION complete_integration_run(p_org uuid, p_run uuid, p_token uuid, p_external_request_id text, p_artifacts jsonb, p_now timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.complete_integration_run(p_org uuid, p_run uuid, p_token uuid, p_external_request_id text, p_artifacts jsonb, p_now timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.complete_integration_run(p_org uuid, p_run uuid, p_token uuid, p_external_request_id text, p_artifacts jsonb, p_now timestamp with time zone) TO service_role;


--
-- Name: FUNCTION confirm_import_mapping(p_organization uuid, p_source_label text, p_fingerprint text, p_mapping jsonb, p_unknown jsonb, p_confidence numeric, p_provider text, p_model text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.confirm_import_mapping(p_organization uuid, p_source_label text, p_fingerprint text, p_mapping jsonb, p_unknown jsonb, p_confidence numeric, p_provider text, p_model text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.confirm_import_mapping(p_organization uuid, p_source_label text, p_fingerprint text, p_mapping jsonb, p_unknown jsonb, p_confidence numeric, p_provider text, p_model text) TO authenticated;
GRANT ALL ON FUNCTION public.confirm_import_mapping(p_organization uuid, p_source_label text, p_fingerprint text, p_mapping jsonb, p_unknown jsonb, p_confidence numeric, p_provider text, p_model text) TO service_role;


--
-- Name: FUNCTION confirm_proposal_paid_from_import(p_decision_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.confirm_proposal_paid_from_import(p_decision_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.confirm_proposal_paid_from_import(p_decision_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.confirm_proposal_paid_from_import(p_decision_id uuid) TO service_role;


--
-- Name: FUNCTION convert_lead_to_customer(p_lead_id uuid, p_cpf text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.convert_lead_to_customer(p_lead_id uuid, p_cpf text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.convert_lead_to_customer(p_lead_id uuid, p_cpf text) TO authenticated;
GRANT ALL ON FUNCTION public.convert_lead_to_customer(p_lead_id uuid, p_cpf text) TO service_role;


--
-- Name: FUNCTION create_and_publish_commission_rule(p_channel_id uuid, p_product_table_id uuid, p_component_type text, p_percentage numeric, p_fixed_amount numeric, p_anticipation_factor numeric, p_calculation_base text, p_effective_from timestamp with time zone, p_operation_type text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_and_publish_commission_rule(p_channel_id uuid, p_product_table_id uuid, p_component_type text, p_percentage numeric, p_fixed_amount numeric, p_anticipation_factor numeric, p_calculation_base text, p_effective_from timestamp with time zone, p_operation_type text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_and_publish_commission_rule(p_channel_id uuid, p_product_table_id uuid, p_component_type text, p_percentage numeric, p_fixed_amount numeric, p_anticipation_factor numeric, p_calculation_base text, p_effective_from timestamp with time zone, p_operation_type text) TO authenticated;
GRANT ALL ON FUNCTION public.create_and_publish_commission_rule(p_channel_id uuid, p_product_table_id uuid, p_component_type text, p_percentage numeric, p_fixed_amount numeric, p_anticipation_factor numeric, p_calculation_base text, p_effective_from timestamp with time zone, p_operation_type text) TO service_role;


--
-- Name: FUNCTION create_and_publish_split_rule(p_relationship_id uuid, p_bank_id uuid, p_product_table_id uuid, p_component_type text, p_downstream_share numeric, p_payment_flow text, p_effective_from timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_and_publish_split_rule(p_relationship_id uuid, p_bank_id uuid, p_product_table_id uuid, p_component_type text, p_downstream_share numeric, p_payment_flow text, p_effective_from timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_and_publish_split_rule(p_relationship_id uuid, p_bank_id uuid, p_product_table_id uuid, p_component_type text, p_downstream_share numeric, p_payment_flow text, p_effective_from timestamp with time zone) TO authenticated;
GRANT ALL ON FUNCTION public.create_and_publish_split_rule(p_relationship_id uuid, p_bank_id uuid, p_product_table_id uuid, p_component_type text, p_downstream_share numeric, p_payment_flow text, p_effective_from timestamp with time zone) TO service_role;


--
-- Name: FUNCTION create_customer_with_timeline(p_full_name text, p_cpf text, p_phone text, p_email text, p_original_source text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_customer_with_timeline(p_full_name text, p_cpf text, p_phone text, p_email text, p_original_source text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_customer_with_timeline(p_full_name text, p_cpf text, p_phone text, p_email text, p_original_source text) TO authenticated;
GRANT ALL ON FUNCTION public.create_customer_with_timeline(p_full_name text, p_cpf text, p_phone text, p_email text, p_original_source text) TO service_role;


--
-- Name: FUNCTION create_customer_with_timeline(p_organization_id uuid, p_full_name text, p_cpf text, p_phone text, p_email text, p_original_source text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_customer_with_timeline(p_organization_id uuid, p_full_name text, p_cpf text, p_phone text, p_email text, p_original_source text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_customer_with_timeline(p_organization_id uuid, p_full_name text, p_cpf text, p_phone text, p_email text, p_original_source text) TO authenticated;
GRANT ALL ON FUNCTION public.create_customer_with_timeline(p_organization_id uuid, p_full_name text, p_cpf text, p_phone text, p_email text, p_original_source text) TO service_role;


--
-- Name: FUNCTION create_integration_reexecution(p_org uuid, p_parent uuid, p_actor uuid, p_reason text, p_correlation text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_integration_reexecution(p_org uuid, p_parent uuid, p_actor uuid, p_reason text, p_correlation text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_integration_reexecution(p_org uuid, p_parent uuid, p_actor uuid, p_reason text, p_correlation text) TO service_role;


--
-- Name: FUNCTION create_lead(p_organization_id uuid, p_channel text, p_full_name text, p_phone text, p_email text, p_campaign text, p_external_ref text, p_metadata jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_lead(p_organization_id uuid, p_channel text, p_full_name text, p_phone text, p_email text, p_campaign text, p_external_ref text, p_metadata jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_lead(p_organization_id uuid, p_channel text, p_full_name text, p_phone text, p_email text, p_campaign text, p_external_ref text, p_metadata jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.create_lead(p_organization_id uuid, p_channel text, p_full_name text, p_phone text, p_email text, p_campaign text, p_external_ref text, p_metadata jsonb) TO service_role;


--
-- Name: FUNCTION create_organization_invitation(p_org uuid, p_email text, p_role text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_organization_invitation(p_org uuid, p_email text, p_role text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_organization_invitation(p_org uuid, p_email text, p_role text) TO authenticated;
GRANT ALL ON FUNCTION public.create_organization_invitation(p_org uuid, p_email text, p_role text) TO service_role;


--
-- Name: FUNCTION create_proposal_from_simulation(p_simulation_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_proposal_from_simulation(p_simulation_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_proposal_from_simulation(p_simulation_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.create_proposal_from_simulation(p_simulation_id uuid) TO service_role;


--
-- Name: FUNCTION create_seller_with_access(p_org uuid, p_name text, p_seller_category text, p_tax_id text, p_seller_group_id uuid, p_commission_group_id uuid, p_email text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_seller_with_access(p_org uuid, p_name text, p_seller_category text, p_tax_id text, p_seller_group_id uuid, p_commission_group_id uuid, p_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_seller_with_access(p_org uuid, p_name text, p_seller_category text, p_tax_id text, p_seller_group_id uuid, p_commission_group_id uuid, p_email text) TO authenticated;
GRANT ALL ON FUNCTION public.create_seller_with_access(p_org uuid, p_name text, p_seller_category text, p_tax_id text, p_seller_group_id uuid, p_commission_group_id uuid, p_email text) TO service_role;


--
-- Name: FUNCTION create_simulation(p_customer_id uuid, p_table_version_id uuid, p_requested_amount numeric, p_term integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_simulation(p_customer_id uuid, p_table_version_id uuid, p_requested_amount numeric, p_term integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_simulation(p_customer_id uuid, p_table_version_id uuid, p_requested_amount numeric, p_term integer) TO authenticated;
GRANT ALL ON FUNCTION public.create_simulation(p_customer_id uuid, p_table_version_id uuid, p_requested_amount numeric, p_term integer) TO service_role;


--
-- Name: FUNCTION create_simulation_for_condition(p_customer_id uuid, p_table_version_id uuid, p_contract_type_id uuid, p_requested_amount numeric, p_term integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_simulation_for_condition(p_customer_id uuid, p_table_version_id uuid, p_contract_type_id uuid, p_requested_amount numeric, p_term integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_simulation_for_condition(p_customer_id uuid, p_table_version_id uuid, p_contract_type_id uuid, p_requested_amount numeric, p_term integer) TO authenticated;
GRANT ALL ON FUNCTION public.create_simulation_for_condition(p_customer_id uuid, p_table_version_id uuid, p_contract_type_id uuid, p_requested_amount numeric, p_term integer) TO service_role;


--
-- Name: FUNCTION create_simulation_for_condition(p_customer_id uuid, p_table_version_id uuid, p_contract_type_id uuid, p_requested_amount numeric, p_term integer, p_contract_value numeric); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.create_simulation_for_condition(p_customer_id uuid, p_table_version_id uuid, p_contract_type_id uuid, p_requested_amount numeric, p_term integer, p_contract_value numeric) TO anon;
GRANT ALL ON FUNCTION public.create_simulation_for_condition(p_customer_id uuid, p_table_version_id uuid, p_contract_type_id uuid, p_requested_amount numeric, p_term integer, p_contract_value numeric) TO authenticated;
GRANT ALL ON FUNCTION public.create_simulation_for_condition(p_customer_id uuid, p_table_version_id uuid, p_contract_type_id uuid, p_requested_amount numeric, p_term integer, p_contract_value numeric) TO service_role;


--
-- Name: FUNCTION decide_attention_item(p_item uuid, p_action text, p_note text, p_snooze_until timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.decide_attention_item(p_item uuid, p_action text, p_note text, p_snooze_until timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.decide_attention_item(p_item uuid, p_action text, p_note text, p_snooze_until timestamp with time zone) TO authenticated;
GRANT ALL ON FUNCTION public.decide_attention_item(p_item uuid, p_action text, p_note text, p_snooze_until timestamp with time zone) TO service_role;


--
-- Name: FUNCTION enqueue_integration_run(p_org uuid, p_binding uuid, p_capability text, p_fingerprint text, p_actor uuid, p_max_attempts integer, p_request jsonb, p_correlation text, p_adapter_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.enqueue_integration_run(p_org uuid, p_binding uuid, p_capability text, p_fingerprint text, p_actor uuid, p_max_attempts integer, p_request jsonb, p_correlation text, p_adapter_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.enqueue_integration_run(p_org uuid, p_binding uuid, p_capability text, p_fingerprint text, p_actor uuid, p_max_attempts integer, p_request jsonb, p_correlation text, p_adapter_key text) TO service_role;


--
-- Name: FUNCTION fail_integration_run(p_org uuid, p_run uuid, p_token uuid, p_code text, p_message text, p_retryable boolean, p_backoff_seconds integer, p_now timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.fail_integration_run(p_org uuid, p_run uuid, p_token uuid, p_code text, p_message text, p_retryable boolean, p_backoff_seconds integer, p_now timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fail_integration_run(p_org uuid, p_run uuid, p_token uuid, p_code text, p_message text, p_retryable boolean, p_backoff_seconds integer, p_now timestamp with time zone) TO service_role;


--
-- Name: FUNCTION freeze_import_source_financial_semantic(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.freeze_import_source_financial_semantic() FROM PUBLIC;
GRANT ALL ON FUNCTION public.freeze_import_source_financial_semantic() TO service_role;


--
-- Name: FUNCTION freeze_proposal_commercial_route(p_proposal_id uuid, p_channel_id uuid, p_commission_rule_version_id uuid, p_producer_entity_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.freeze_proposal_commercial_route(p_proposal_id uuid, p_channel_id uuid, p_commission_rule_version_id uuid, p_producer_entity_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.freeze_proposal_commercial_route(p_proposal_id uuid, p_channel_id uuid, p_commission_rule_version_id uuid, p_producer_entity_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.freeze_proposal_commercial_route(p_proposal_id uuid, p_channel_id uuid, p_commission_rule_version_id uuid, p_producer_entity_id uuid) TO service_role;


--
-- Name: FUNCTION freeze_published_commercial_rule(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.freeze_published_commercial_rule() FROM PUBLIC;
GRANT ALL ON FUNCTION public.freeze_published_commercial_rule() TO service_role;


--
-- Name: FUNCTION generate_import_match_candidates(p_batch_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.generate_import_match_candidates(p_batch_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.generate_import_match_candidates(p_batch_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.generate_import_match_candidates(p_batch_id uuid) TO service_role;


--
-- Name: FUNCTION get_commercial_route(p_proposal_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_commercial_route(p_proposal_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_commercial_route(p_proposal_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_commercial_route(p_proposal_id uuid) TO service_role;


--
-- Name: FUNCTION get_user_organization_id(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_user_organization_id() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_user_organization_id() TO service_role;


--
-- Name: FUNCTION guard_admin_event_write(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.guard_admin_event_write() TO anon;
GRANT ALL ON FUNCTION public.guard_admin_event_write() TO authenticated;
GRANT ALL ON FUNCTION public.guard_admin_event_write() TO service_role;


--
-- Name: FUNCTION guard_ai_write(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_ai_write() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_ai_write() TO service_role;


--
-- Name: FUNCTION guard_attention_write(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_attention_write() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_attention_write() TO service_role;


--
-- Name: FUNCTION guard_catalog_publication(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_catalog_publication() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_catalog_publication() TO service_role;


--
-- Name: FUNCTION guard_commission_group_component_limit_write(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_commission_group_component_limit_write() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_commission_group_component_limit_write() TO service_role;


--
-- Name: FUNCTION guard_commission_group_received_basis(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_commission_group_received_basis() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_commission_group_received_basis() TO service_role;


--
-- Name: FUNCTION guard_component_commission_write(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_component_commission_write() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_component_commission_write() TO service_role;


--
-- Name: FUNCTION guard_component_payout_group_limit(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_component_payout_group_limit() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_component_payout_group_limit() TO service_role;


--
-- Name: FUNCTION guard_component_payout_policy_scope(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_component_payout_policy_scope() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_component_payout_policy_scope() TO service_role;


--
-- Name: FUNCTION guard_condition_component_policy(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_condition_component_policy() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_condition_component_policy() TO service_role;


--
-- Name: FUNCTION guard_condition_contract_type_scope(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_condition_contract_type_scope() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_condition_contract_type_scope() TO service_role;


--
-- Name: FUNCTION guard_condition_write(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_condition_write() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_condition_write() TO service_role;


--
-- Name: FUNCTION guard_contract_type_catalog(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_contract_type_catalog() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_contract_type_catalog() TO service_role;


--
-- Name: FUNCTION guard_contract_type_setting(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_contract_type_setting() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_contract_type_setting() TO service_role;


--
-- Name: FUNCTION guard_customer_document_evidence_immutable(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_customer_document_evidence_immutable() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_customer_document_evidence_immutable() TO service_role;


--
-- Name: FUNCTION guard_customer_timeline_write(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_customer_timeline_write() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_customer_timeline_write() TO service_role;


--
-- Name: FUNCTION guard_digitization_job_documents_ready(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_digitization_job_documents_ready() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_digitization_job_documents_ready() TO service_role;


--
-- Name: FUNCTION guard_document_checklist_item_draft_parent(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_document_checklist_item_draft_parent() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_document_checklist_item_draft_parent() TO service_role;


--
-- Name: FUNCTION guard_document_checklist_template_immutable(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_document_checklist_template_immutable() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_document_checklist_template_immutable() TO service_role;


--
-- Name: FUNCTION guard_factor_batch(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_factor_batch() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_factor_batch() TO service_role;


--
-- Name: FUNCTION guard_factor_entry(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_factor_entry() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_factor_entry() TO service_role;


--
-- Name: FUNCTION guard_factor_profile(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_factor_profile() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_factor_profile() TO service_role;


--
-- Name: FUNCTION guard_financial_event_insert(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_financial_event_insert() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_financial_event_insert() TO service_role;


--
-- Name: FUNCTION guard_import_batch_adapter_contract(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_import_batch_adapter_contract() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_import_batch_adapter_contract() TO service_role;


--
-- Name: FUNCTION guard_import_batch_adapter_write_once(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_import_batch_adapter_write_once() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_import_batch_adapter_write_once() TO service_role;


--
-- Name: FUNCTION guard_import_conflict_row_write(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_import_conflict_row_write() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_import_conflict_row_write() TO service_role;


--
-- Name: FUNCTION guard_import_conflict_write(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_import_conflict_write() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_import_conflict_write() TO service_role;


--
-- Name: FUNCTION guard_import_layout_mapping(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_import_layout_mapping() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_import_layout_mapping() TO service_role;


--
-- Name: FUNCTION guard_import_match_candidate_insert(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_import_match_candidate_insert() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_import_match_candidate_insert() TO service_role;


--
-- Name: FUNCTION guard_import_normalized_row_consistency(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_import_normalized_row_consistency() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_import_normalized_row_consistency() TO service_role;


--
-- Name: FUNCTION guard_import_raw_row_immutable(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_import_raw_row_immutable() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_import_raw_row_immutable() TO service_role;


--
-- Name: FUNCTION guard_integration_artifact_consistency(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_integration_artifact_consistency() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_integration_artifact_consistency() TO service_role;


--
-- Name: FUNCTION guard_integration_artifact_write(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_integration_artifact_write() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_integration_artifact_write() TO service_role;


--
-- Name: FUNCTION guard_integration_binding_no_secrets(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_integration_binding_no_secrets() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_integration_binding_no_secrets() TO service_role;


--
-- Name: FUNCTION guard_integration_run_consistency(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_integration_run_consistency() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_integration_run_consistency() TO service_role;


--
-- Name: FUNCTION guard_integration_run_state(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_integration_run_state() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_integration_run_state() TO service_role;


--
-- Name: FUNCTION guard_invitation_write(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.guard_invitation_write() TO anon;
GRANT ALL ON FUNCTION public.guard_invitation_write() TO authenticated;
GRANT ALL ON FUNCTION public.guard_invitation_write() TO service_role;


--
-- Name: FUNCTION guard_membership_write(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.guard_membership_write() TO anon;
GRANT ALL ON FUNCTION public.guard_membership_write() TO authenticated;
GRANT ALL ON FUNCTION public.guard_membership_write() TO service_role;


--
-- Name: FUNCTION guard_operational_pipeline_write(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_operational_pipeline_write() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_operational_pipeline_write() TO service_role;


--
-- Name: FUNCTION guard_org_catalog_row(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_org_catalog_row() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_org_catalog_row() TO service_role;


--
-- Name: FUNCTION guard_payout_write(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_payout_write() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_payout_write() TO service_role;


--
-- Name: FUNCTION guard_product_table_version_immutable(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_product_table_version_immutable() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_product_table_version_immutable() TO service_role;


--
-- Name: FUNCTION guard_proposal_commercial_route_insert(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_proposal_commercial_route_insert() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_proposal_commercial_route_insert() TO service_role;


--
-- Name: FUNCTION guard_proposal_commercial_snapshot(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_proposal_commercial_snapshot() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_proposal_commercial_snapshot() TO service_role;


--
-- Name: FUNCTION guard_proposal_document_requirement_snapshot(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_proposal_document_requirement_snapshot() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_proposal_document_requirement_snapshot() TO service_role;


--
-- Name: FUNCTION guard_proposal_document_requirement_workflow(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_proposal_document_requirement_workflow() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_proposal_document_requirement_workflow() TO service_role;


--
-- Name: FUNCTION guard_proposal_status_transition(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_proposal_status_transition() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_proposal_status_transition() TO service_role;


--
-- Name: FUNCTION guard_proposal_write(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_proposal_write() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_proposal_write() TO service_role;


--
-- Name: FUNCTION guard_reconciliation_case_write(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_reconciliation_case_write() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_reconciliation_case_write() TO service_role;


--
-- Name: FUNCTION guard_seller_bank_alias(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_seller_bank_alias() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_seller_bank_alias() TO service_role;


--
-- Name: FUNCTION guard_seller_catalog_row(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_seller_catalog_row() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_seller_catalog_row() TO service_role;


--
-- Name: FUNCTION guard_seller_commission_snapshot(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_seller_commission_snapshot() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_seller_commission_snapshot() TO service_role;


--
-- Name: FUNCTION guard_seller_profile_write(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_seller_profile_write() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_seller_profile_write() TO service_role;


--
-- Name: FUNCTION guard_seller_sub_rule(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_seller_sub_rule() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_seller_sub_rule() TO service_role;


--
-- Name: FUNCTION guard_seller_supervision(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_seller_supervision() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_seller_supervision() TO service_role;


--
-- Name: FUNCTION guard_simulation_selected_immutable(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_simulation_selected_immutable() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_simulation_selected_immutable() TO service_role;


--
-- Name: FUNCTION guard_simulation_write(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_simulation_write() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_simulation_write() TO service_role;


--
-- Name: FUNCTION has_active_organization_role(p_organization_id uuid, p_roles text[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.has_active_organization_role(p_organization_id uuid, p_roles text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.has_active_organization_role(p_organization_id uuid, p_roles text[]) TO service_role;
GRANT ALL ON FUNCTION public.has_active_organization_role(p_organization_id uuid, p_roles text[]) TO authenticated;


--
-- Name: FUNCTION import_commercial_conditions(p_version uuid, p_rows jsonb, p_policy_version uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.import_commercial_conditions(p_version uuid, p_rows jsonb, p_policy_version uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.import_commercial_conditions(p_version uuid, p_rows jsonb, p_policy_version uuid) TO authenticated;
GRANT ALL ON FUNCTION public.import_commercial_conditions(p_version uuid, p_rows jsonb, p_policy_version uuid) TO service_role;


--
-- Name: FUNCTION import_smart_commercial_rows(p_organization uuid, p_production_origin text, p_provider uuid, p_policy_version uuid, p_rows jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.import_smart_commercial_rows(p_organization uuid, p_production_origin text, p_provider uuid, p_policy_version uuid, p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.import_smart_commercial_rows(p_organization uuid, p_production_origin text, p_provider uuid, p_policy_version uuid, p_rows jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.import_smart_commercial_rows(p_organization uuid, p_production_origin text, p_provider uuid, p_policy_version uuid, p_rows jsonb) TO service_role;


--
-- Name: FUNCTION ingest_normalized_import_batch(p_source_id uuid, p_original_filename text, p_content_sha256 text, p_mime_type text, p_parser_key text, p_parser_version text, p_rows jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.ingest_normalized_import_batch(p_source_id uuid, p_original_filename text, p_content_sha256 text, p_mime_type text, p_parser_key text, p_parser_version text, p_rows jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.ingest_normalized_import_batch(p_source_id uuid, p_original_filename text, p_content_sha256 text, p_mime_type text, p_parser_key text, p_parser_version text, p_rows jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.ingest_normalized_import_batch(p_source_id uuid, p_original_filename text, p_content_sha256 text, p_mime_type text, p_parser_key text, p_parser_version text, p_rows jsonb) TO service_role;


--
-- Name: FUNCTION integration_content_has_secret(p_value text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.integration_content_has_secret(p_value text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.integration_content_has_secret(p_value text) TO authenticated;
GRANT ALL ON FUNCTION public.integration_content_has_secret(p_value text) TO service_role;


--
-- Name: FUNCTION is_active_organization_member(target_organization_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_active_organization_member(target_organization_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_active_organization_member(target_organization_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.is_active_organization_member(target_organization_id uuid) TO service_role;


--
-- Name: FUNCTION list_dispatchable_integration_runs(p_limit integer, p_now timestamp with time zone, p_adapter_keys text[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.list_dispatchable_integration_runs(p_limit integer, p_now timestamp with time zone, p_adapter_keys text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.list_dispatchable_integration_runs(p_limit integer, p_now timestamp with time zone, p_adapter_keys text[]) TO service_role;


--
-- Name: FUNCTION list_import_rows(p_batch_id uuid, p_numbers text[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.list_import_rows(p_batch_id uuid, p_numbers text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.list_import_rows(p_batch_id uuid, p_numbers text[]) TO authenticated;
GRANT ALL ON FUNCTION public.list_import_rows(p_batch_id uuid, p_numbers text[]) TO service_role;


--
-- Name: FUNCTION normalize_external_user(p_value text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.normalize_external_user(p_value text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.normalize_external_user(p_value text) TO authenticated;
GRANT ALL ON FUNCTION public.normalize_external_user(p_value text) TO service_role;


--
-- Name: FUNCTION platform_grant_ai_credits(p_organization uuid, p_credits numeric, p_idempotency_key text, p_note text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.platform_grant_ai_credits(p_organization uuid, p_credits numeric, p_idempotency_key text, p_note text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.platform_grant_ai_credits(p_organization uuid, p_credits numeric, p_idempotency_key text, p_note text) TO service_role;


--
-- Name: FUNCTION platform_set_ai_limits(p_organization uuid, p_enabled boolean, p_monthly_limit numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.platform_set_ai_limits(p_organization uuid, p_enabled boolean, p_monthly_limit numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION public.platform_set_ai_limits(p_organization uuid, p_enabled boolean, p_monthly_limit numeric) TO service_role;


--
-- Name: FUNCTION prepare_proposal_documents(p_proposal_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.prepare_proposal_documents(p_proposal_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.prepare_proposal_documents(p_proposal_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.prepare_proposal_documents(p_proposal_id uuid) TO service_role;


--
-- Name: FUNCTION publish_commercial_factor_batch(p_batch uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.publish_commercial_factor_batch(p_batch uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.publish_commercial_factor_batch(p_batch uuid) TO authenticated;
GRANT ALL ON FUNCTION public.publish_commercial_factor_batch(p_batch uuid) TO service_role;


--
-- Name: FUNCTION publish_document_checklist_template(p_template_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.publish_document_checklist_template(p_template_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.publish_document_checklist_template(p_template_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.publish_document_checklist_template(p_template_id uuid) TO service_role;


--
-- Name: FUNCTION publish_expected_commission(p_proposal_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.publish_expected_commission(p_proposal_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.publish_expected_commission(p_proposal_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.publish_expected_commission(p_proposal_id uuid) TO service_role;


--
-- Name: FUNCTION publish_financial_evidence_event(p_proposal_id uuid, p_event_type text, p_component_type text, p_amount numeric, p_occurred_at timestamp with time zone, p_source_kind text, p_source_reference text, p_import_batch_id uuid, p_import_raw_row_id uuid, p_import_decision_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.publish_financial_evidence_event(p_proposal_id uuid, p_event_type text, p_component_type text, p_amount numeric, p_occurred_at timestamp with time zone, p_source_kind text, p_source_reference text, p_import_batch_id uuid, p_import_raw_row_id uuid, p_import_decision_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.publish_financial_evidence_event(p_proposal_id uuid, p_event_type text, p_component_type text, p_amount numeric, p_occurred_at timestamp with time zone, p_source_kind text, p_source_reference text, p_import_batch_id uuid, p_import_raw_row_id uuid, p_import_decision_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.publish_financial_evidence_event(p_proposal_id uuid, p_event_type text, p_component_type text, p_amount numeric, p_occurred_at timestamp with time zone, p_source_kind text, p_source_reference text, p_import_batch_id uuid, p_import_raw_row_id uuid, p_import_decision_id uuid) TO service_role;


--
-- Name: FUNCTION publish_financial_fact_from_import_decision(p_decision_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.publish_financial_fact_from_import_decision(p_decision_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.publish_financial_fact_from_import_decision(p_decision_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.publish_financial_fact_from_import_decision(p_decision_id uuid) TO service_role;


--
-- Name: FUNCTION publish_financial_reversal(p_event_id uuid, p_amount numeric, p_reason text, p_source_kind text, p_source_reference text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.publish_financial_reversal(p_event_id uuid, p_amount numeric, p_reason text, p_source_kind text, p_source_reference text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.publish_financial_reversal(p_event_id uuid, p_amount numeric, p_reason text, p_source_kind text, p_source_reference text) TO authenticated;
GRANT ALL ON FUNCTION public.publish_financial_reversal(p_event_id uuid, p_amount numeric, p_reason text, p_source_kind text, p_source_reference text) TO service_role;


--
-- Name: FUNCTION publish_product_table_version(p_version_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.publish_product_table_version(p_version_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.publish_product_table_version(p_version_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.publish_product_table_version(p_version_id uuid) TO service_role;


--
-- Name: FUNCTION publish_seller_sub_rule(p_rule uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.publish_seller_sub_rule(p_rule uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.publish_seller_sub_rule(p_rule uuid) TO authenticated;
GRANT ALL ON FUNCTION public.publish_seller_sub_rule(p_rule uuid) TO service_role;


--
-- Name: FUNCTION record_import_conflicts(p_batch_id uuid, p_findings jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_import_conflicts(p_batch_id uuid, p_findings jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_import_conflicts(p_batch_id uuid, p_findings jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.record_import_conflicts(p_batch_id uuid, p_findings jsonb) TO service_role;


--
-- Name: FUNCTION refresh_financial_reconciliation(p_proposal_id uuid, p_component_type text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.refresh_financial_reconciliation(p_proposal_id uuid, p_component_type text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.refresh_financial_reconciliation(p_proposal_id uuid, p_component_type text) TO authenticated;
GRANT ALL ON FUNCTION public.refresh_financial_reconciliation(p_proposal_id uuid, p_component_type text) TO service_role;


--
-- Name: FUNCTION replace_commercial_condition_components(p_condition uuid, p_components jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.replace_commercial_condition_components(p_condition uuid, p_components jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.replace_commercial_condition_components(p_condition uuid, p_components jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.replace_commercial_condition_components(p_condition uuid, p_components jsonb) TO service_role;


--
-- Name: FUNCTION replace_seller_address(p_seller_id uuid, p_postal_code text, p_street text, p_number text, p_complement text, p_neighborhood text, p_city text, p_state text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.replace_seller_address(p_seller_id uuid, p_postal_code text, p_street text, p_number text, p_complement text, p_neighborhood text, p_city text, p_state text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.replace_seller_address(p_seller_id uuid, p_postal_code text, p_street text, p_number text, p_complement text, p_neighborhood text, p_city text, p_state text) TO authenticated;
GRANT ALL ON FUNCTION public.replace_seller_address(p_seller_id uuid, p_postal_code text, p_street text, p_number text, p_complement text, p_neighborhood text, p_city text, p_state text) TO service_role;


--
-- Name: FUNCTION reserve_ai_job(p_organization uuid, p_capability text, p_provider text, p_model text, p_estimated_credits numeric, p_estimated_cost numeric, p_source_ref text, p_idempotency_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reserve_ai_job(p_organization uuid, p_capability text, p_provider text, p_model text, p_estimated_credits numeric, p_estimated_cost numeric, p_source_ref text, p_idempotency_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reserve_ai_job(p_organization uuid, p_capability text, p_provider text, p_model text, p_estimated_credits numeric, p_estimated_cost numeric, p_source_ref text, p_idempotency_key text) TO authenticated;
GRANT ALL ON FUNCTION public.reserve_ai_job(p_organization uuid, p_capability text, p_provider text, p_model text, p_estimated_credits numeric, p_estimated_cost numeric, p_source_ref text, p_idempotency_key text) TO service_role;


--
-- Name: FUNCTION resolve_commercial_factor(p_org_bank uuid, p_org_agreement uuid, p_product_table uuid, p_contract_type uuid, p_term integer, p_on date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.resolve_commercial_factor(p_org_bank uuid, p_org_agreement uuid, p_product_table uuid, p_contract_type uuid, p_term integer, p_on date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resolve_commercial_factor(p_org_bank uuid, p_org_agreement uuid, p_product_table uuid, p_contract_type uuid, p_term integer, p_on date) TO authenticated;
GRANT ALL ON FUNCTION public.resolve_commercial_factor(p_org_bank uuid, p_org_agreement uuid, p_product_table uuid, p_contract_type uuid, p_term integer, p_on date) TO service_role;


--
-- Name: FUNCTION resolve_component_payout_policy(p_organization uuid, p_bank uuid, p_agreement uuid, p_table uuid, p_at timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.resolve_component_payout_policy(p_organization uuid, p_bank uuid, p_agreement uuid, p_table uuid, p_at timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resolve_component_payout_policy(p_organization uuid, p_bank uuid, p_agreement uuid, p_table uuid, p_at timestamp with time zone) TO authenticated;
GRANT ALL ON FUNCTION public.resolve_component_payout_policy(p_organization uuid, p_bank uuid, p_agreement uuid, p_table uuid, p_at timestamp with time zone) TO service_role;


--
-- Name: FUNCTION resolve_import_conflict(p_conflict_id uuid, p_status text, p_note text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.resolve_import_conflict(p_conflict_id uuid, p_status text, p_note text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resolve_import_conflict(p_conflict_id uuid, p_status text, p_note text) TO authenticated;
GRANT ALL ON FUNCTION public.resolve_import_conflict(p_conflict_id uuid, p_status text, p_note text) TO service_role;


--
-- Name: FUNCTION resolve_seller_bank_alias(p_org uuid, p_source_key text, p_external_user text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.resolve_seller_bank_alias(p_org uuid, p_source_key text, p_external_user text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resolve_seller_bank_alias(p_org uuid, p_source_key text, p_external_user text) TO authenticated;
GRANT ALL ON FUNCTION public.resolve_seller_bank_alias(p_org uuid, p_source_key text, p_external_user text) TO service_role;


--
-- Name: FUNCTION resolve_seller_sub_rule(p_seller uuid, p_component text, p_at timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.resolve_seller_sub_rule(p_seller uuid, p_component text, p_at timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.resolve_seller_sub_rule(p_seller uuid, p_component text, p_at timestamp with time zone) TO authenticated;
GRANT ALL ON FUNCTION public.resolve_seller_sub_rule(p_seller uuid, p_component text, p_at timestamp with time zone) TO service_role;


--
-- Name: FUNCTION revoke_organization_invitation(p_invitation_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.revoke_organization_invitation(p_invitation_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.revoke_organization_invitation(p_invitation_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.revoke_organization_invitation(p_invitation_id uuid) TO service_role;


--
-- Name: FUNCTION save_commercial_condition(p_version uuid, p_contract_type uuid, p_term integer, p_coefficient numeric, p_rate numeric, p_received numeric, p_shares jsonb, p_condition uuid, p_policy_version uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.save_commercial_condition(p_version uuid, p_contract_type uuid, p_term integer, p_coefficient numeric, p_rate numeric, p_received numeric, p_shares jsonb, p_condition uuid, p_policy_version uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_commercial_condition(p_version uuid, p_contract_type uuid, p_term integer, p_coefficient numeric, p_rate numeric, p_received numeric, p_shares jsonb, p_condition uuid, p_policy_version uuid) TO authenticated;
GRANT ALL ON FUNCTION public.save_commercial_condition(p_version uuid, p_contract_type uuid, p_term integer, p_coefficient numeric, p_rate numeric, p_received numeric, p_shares jsonb, p_condition uuid, p_policy_version uuid) TO service_role;


--
-- Name: FUNCTION save_commercial_condition_range(p_version uuid, p_contract_type uuid, p_term_min integer, p_term_max integer, p_coefficient numeric, p_rate numeric, p_received numeric, p_shares jsonb, p_condition uuid, p_policy_version uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.save_commercial_condition_range(p_version uuid, p_contract_type uuid, p_term_min integer, p_term_max integer, p_coefficient numeric, p_rate numeric, p_received numeric, p_shares jsonb, p_condition uuid, p_policy_version uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_commercial_condition_range(p_version uuid, p_contract_type uuid, p_term_min integer, p_term_max integer, p_coefficient numeric, p_rate numeric, p_received numeric, p_shares jsonb, p_condition uuid, p_policy_version uuid) TO authenticated;
GRANT ALL ON FUNCTION public.save_commercial_condition_range(p_version uuid, p_contract_type uuid, p_term_min integer, p_term_max integer, p_coefficient numeric, p_rate numeric, p_received numeric, p_shares jsonb, p_condition uuid, p_policy_version uuid) TO service_role;


--
-- Name: FUNCTION save_commercial_condition_range(p_version uuid, p_contract_type uuid, p_term_min integer, p_term_max integer, p_coefficient numeric, p_rate numeric, p_received numeric, p_shares jsonb, p_condition uuid, p_policy_version uuid, p_amount_min numeric, p_amount_max numeric); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.save_commercial_condition_range(p_version uuid, p_contract_type uuid, p_term_min integer, p_term_max integer, p_coefficient numeric, p_rate numeric, p_received numeric, p_shares jsonb, p_condition uuid, p_policy_version uuid, p_amount_min numeric, p_amount_max numeric) TO anon;
GRANT ALL ON FUNCTION public.save_commercial_condition_range(p_version uuid, p_contract_type uuid, p_term_min integer, p_term_max integer, p_coefficient numeric, p_rate numeric, p_received numeric, p_shares jsonb, p_condition uuid, p_policy_version uuid, p_amount_min numeric, p_amount_max numeric) TO authenticated;
GRANT ALL ON FUNCTION public.save_commercial_condition_range(p_version uuid, p_contract_type uuid, p_term_min integer, p_term_max integer, p_coefficient numeric, p_rate numeric, p_received numeric, p_shares jsonb, p_condition uuid, p_policy_version uuid, p_amount_min numeric, p_amount_max numeric) TO service_role;


--
-- Name: FUNCTION save_commission_group_configuration(p_organization uuid, p_group uuid, p_name text, p_items jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.save_commission_group_configuration(p_organization uuid, p_group uuid, p_name text, p_items jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_commission_group_configuration(p_organization uuid, p_group uuid, p_name text, p_items jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.save_commission_group_configuration(p_organization uuid, p_group uuid, p_name text, p_items jsonb) TO service_role;


--
-- Name: FUNCTION save_component_payout_policy(p_organization uuid, p_name text, p_bank uuid, p_agreement uuid, p_table uuid, p_discount numeric, p_effective_from timestamp with time zone, p_items jsonb, p_policy uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.save_component_payout_policy(p_organization uuid, p_name text, p_bank uuid, p_agreement uuid, p_table uuid, p_discount numeric, p_effective_from timestamp with time zone, p_items jsonb, p_policy uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_component_payout_policy(p_organization uuid, p_name text, p_bank uuid, p_agreement uuid, p_table uuid, p_discount numeric, p_effective_from timestamp with time zone, p_items jsonb, p_policy uuid) TO authenticated;
GRANT ALL ON FUNCTION public.save_component_payout_policy(p_organization uuid, p_name text, p_bank uuid, p_agreement uuid, p_table uuid, p_discount numeric, p_effective_from timestamp with time zone, p_items jsonb, p_policy uuid) TO service_role;


--
-- Name: FUNCTION save_payout_policy(p_organization uuid, p_name text, p_base_kind text, p_discount numeric, p_items jsonb, p_policy uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.save_payout_policy(p_organization uuid, p_name text, p_base_kind text, p_discount numeric, p_items jsonb, p_policy uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_payout_policy(p_organization uuid, p_name text, p_base_kind text, p_discount numeric, p_items jsonb, p_policy uuid) TO authenticated;
GRANT ALL ON FUNCTION public.save_payout_policy(p_organization uuid, p_name text, p_base_kind text, p_discount numeric, p_items jsonb, p_policy uuid) TO service_role;


--
-- Name: FUNCTION send_proposal_to_digitization(p_proposal_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.send_proposal_to_digitization(p_proposal_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.send_proposal_to_digitization(p_proposal_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.send_proposal_to_digitization(p_proposal_id uuid) TO service_role;


--
-- Name: FUNCTION set_lead_status(p_lead_id uuid, p_status text, p_lost_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_lead_status(p_lead_id uuid, p_status text, p_lost_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_lead_status(p_lead_id uuid, p_status text, p_lost_reason text) TO authenticated;
GRANT ALL ON FUNCTION public.set_lead_status(p_lead_id uuid, p_status text, p_lost_reason text) TO service_role;


--
-- Name: FUNCTION set_member_role(p_membership_id uuid, p_role text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_member_role(p_membership_id uuid, p_role text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_member_role(p_membership_id uuid, p_role text) TO authenticated;
GRANT ALL ON FUNCTION public.set_member_role(p_membership_id uuid, p_role text) TO service_role;


--
-- Name: FUNCTION set_member_status(p_membership_id uuid, p_status text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_member_status(p_membership_id uuid, p_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_member_status(p_membership_id uuid, p_status text) TO authenticated;
GRANT ALL ON FUNCTION public.set_member_status(p_membership_id uuid, p_status text) TO service_role;


--
-- Name: FUNCTION set_seller_payment_account(p_seller_id uuid, p_bank_id uuid, p_branch text, p_account_number text, p_account_digit text, p_account_type text, p_holder_name text, p_holder_document text, p_pix_key_type text, p_pix_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_seller_payment_account(p_seller_id uuid, p_bank_id uuid, p_branch text, p_account_number text, p_account_digit text, p_account_type text, p_holder_name text, p_holder_document text, p_pix_key_type text, p_pix_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_seller_payment_account(p_seller_id uuid, p_bank_id uuid, p_branch text, p_account_number text, p_account_digit text, p_account_type text, p_holder_name text, p_holder_document text, p_pix_key_type text, p_pix_key text) TO authenticated;
GRANT ALL ON FUNCTION public.set_seller_payment_account(p_seller_id uuid, p_bank_id uuid, p_branch text, p_account_number text, p_account_digit text, p_account_type text, p_holder_name text, p_holder_document text, p_pix_key_type text, p_pix_key text) TO service_role;


--
-- Name: FUNCTION set_seller_supervision(p_seller_id uuid, p_supervisor_user_id uuid, p_active boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_seller_supervision(p_seller_id uuid, p_supervisor_user_id uuid, p_active boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_seller_supervision(p_seller_id uuid, p_supervisor_user_id uuid, p_active boolean) TO authenticated;
GRANT ALL ON FUNCTION public.set_seller_supervision(p_seller_id uuid, p_supervisor_user_id uuid, p_active boolean) TO service_role;


--
-- Name: FUNCTION set_seller_user(p_seller_id uuid, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_seller_user(p_seller_id uuid, p_user_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_seller_user(p_seller_id uuid, p_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.set_seller_user(p_seller_id uuid, p_user_id uuid) TO service_role;


--
-- Name: FUNCTION settle_ai_job(p_job uuid, p_outcome text, p_credits_charged numeric, p_actual_cost numeric, p_input_units bigint, p_output_units bigint); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.settle_ai_job(p_job uuid, p_outcome text, p_credits_charged numeric, p_actual_cost numeric, p_input_units bigint, p_output_units bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION public.settle_ai_job(p_job uuid, p_outcome text, p_credits_charged numeric, p_actual_cost numeric, p_input_units bigint, p_output_units bigint) TO authenticated;
GRANT ALL ON FUNCTION public.settle_ai_job(p_job uuid, p_outcome text, p_credits_charged numeric, p_actual_cost numeric, p_input_units bigint, p_output_units bigint) TO service_role;


--
-- Name: FUNCTION snapshot_seller_commission(p_proposal_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.snapshot_seller_commission(p_proposal_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.snapshot_seller_commission(p_proposal_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.snapshot_seller_commission(p_proposal_id uuid) TO service_role;


--
-- Name: FUNCTION snapshot_seller_commission_after_component(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.snapshot_seller_commission_after_component() FROM PUBLIC;
GRANT ALL ON FUNCTION public.snapshot_seller_commission_after_component() TO service_role;


--
-- Name: FUNCTION sweep_orphaned_integration_runs(p_limit integer, p_now timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sweep_orphaned_integration_runs(p_limit integer, p_now timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sweep_orphaned_integration_runs(p_limit integer, p_now timestamp with time zone) TO service_role;


--
-- Name: FUNCTION sync_attention_items(p_organization uuid, p_rule_keys text[], p_items jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_attention_items(p_organization uuid, p_rule_keys text[], p_items jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_attention_items(p_organization uuid, p_rule_keys text[], p_items jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.sync_attention_items(p_organization uuid, p_rule_keys text[], p_items jsonb) TO service_role;


--
-- Name: FUNCTION transition_operational_case(p_case_id uuid, p_to_state text, p_raw_external_status text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.transition_operational_case(p_case_id uuid, p_to_state text, p_raw_external_status text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.transition_operational_case(p_case_id uuid, p_to_state text, p_raw_external_status text) TO authenticated;
GRANT ALL ON FUNCTION public.transition_operational_case(p_case_id uuid, p_to_state text, p_raw_external_status text) TO service_role;


--
-- Name: FUNCTION upsert_seller_certification(p_id uuid, p_seller_id uuid, p_name text, p_issuer text, p_certificate_number text, p_issued_at date, p_expires_at date, p_status text, p_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.upsert_seller_certification(p_id uuid, p_seller_id uuid, p_name text, p_issuer text, p_certificate_number text, p_issued_at date, p_expires_at date, p_status text, p_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.upsert_seller_certification(p_id uuid, p_seller_id uuid, p_name text, p_issuer text, p_certificate_number text, p_issued_at date, p_expires_at date, p_status text, p_notes text) TO authenticated;
GRANT ALL ON FUNCTION public.upsert_seller_certification(p_id uuid, p_seller_id uuid, p_name text, p_issuer text, p_certificate_number text, p_issued_at date, p_expires_at date, p_status text, p_notes text) TO service_role;


--
-- Name: FUNCTION upsert_seller_profile(p_seller_id uuid, p_legal_name text, p_trade_name text, p_email text, p_phone text, p_whatsapp text, p_birth_or_opening_date date, p_identity_or_registration_number text, p_identity_issuer text, p_occupation text, p_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.upsert_seller_profile(p_seller_id uuid, p_legal_name text, p_trade_name text, p_email text, p_phone text, p_whatsapp text, p_birth_or_opening_date date, p_identity_or_registration_number text, p_identity_issuer text, p_occupation text, p_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.upsert_seller_profile(p_seller_id uuid, p_legal_name text, p_trade_name text, p_email text, p_phone text, p_whatsapp text, p_birth_or_opening_date date, p_identity_or_registration_number text, p_identity_issuer text, p_occupation text, p_notes text) TO authenticated;
GRANT ALL ON FUNCTION public.upsert_seller_profile(p_seller_id uuid, p_legal_name text, p_trade_name text, p_email text, p_phone text, p_whatsapp text, p_birth_or_opening_date date, p_identity_or_registration_number text, p_identity_issuer text, p_occupation text, p_notes text) TO service_role;


--
-- Name: TABLE agreements; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.agreements TO service_role;
GRANT SELECT ON TABLE public.agreements TO authenticated;


--
-- Name: TABLE ai_credit_ledger; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ai_credit_ledger TO service_role;
GRANT SELECT,INSERT ON TABLE public.ai_credit_ledger TO authenticated;


--
-- Name: TABLE ai_usage_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ai_usage_events TO service_role;
GRANT SELECT,INSERT ON TABLE public.ai_usage_events TO authenticated;


--
-- Name: TABLE ai_usage_jobs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ai_usage_jobs TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.ai_usage_jobs TO authenticated;


--
-- Name: TABLE banks; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.banks TO service_role;
GRANT SELECT ON TABLE public.banks TO authenticated;


--
-- Name: TABLE channel_commission_rule_versions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.channel_commission_rule_versions TO authenticated;
GRANT ALL ON TABLE public.channel_commission_rule_versions TO service_role;


--
-- Name: TABLE clients; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.clients TO authenticated;
GRANT ALL ON TABLE public.clients TO service_role;


--
-- Name: TABLE commercial_channels; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.commercial_channels TO authenticated;
GRANT ALL ON TABLE public.commercial_channels TO service_role;


--
-- Name: TABLE commercial_condition_commissions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.commercial_condition_commissions TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.commercial_condition_commissions TO authenticated;


--
-- Name: TABLE commercial_condition_component_policy; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.commercial_condition_component_policy TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.commercial_condition_component_policy TO authenticated;


--
-- Name: TABLE commercial_condition_components; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.commercial_condition_components TO service_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.commercial_condition_components TO authenticated;


--
-- Name: TABLE commercial_condition_shares; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.commercial_condition_shares TO service_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.commercial_condition_shares TO authenticated;


--
-- Name: TABLE commercial_conditions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.commercial_conditions TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.commercial_conditions TO authenticated;


--
-- Name: TABLE commercial_entities; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.commercial_entities TO authenticated;
GRANT ALL ON TABLE public.commercial_entities TO service_role;


--
-- Name: TABLE commercial_factor_batches; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.commercial_factor_batches TO service_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.commercial_factor_batches TO authenticated;


--
-- Name: TABLE commercial_factor_entries; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.commercial_factor_entries TO service_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.commercial_factor_entries TO authenticated;


--
-- Name: TABLE commercial_factor_profiles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.commercial_factor_profiles TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.commercial_factor_profiles TO authenticated;


--
-- Name: TABLE commercial_relationships; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.commercial_relationships TO authenticated;
GRANT ALL ON TABLE public.commercial_relationships TO service_role;


--
-- Name: TABLE commercial_sellers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.commercial_sellers TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.commercial_sellers TO authenticated;


--
-- Name: TABLE commission_component_types; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.commission_component_types TO service_role;
GRANT SELECT ON TABLE public.commission_component_types TO authenticated;


--
-- Name: TABLE commission_group_component_limits; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.commission_group_component_limits TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.commission_group_component_limits TO authenticated;


--
-- Name: TABLE commission_groups; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.commission_groups TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.commission_groups TO authenticated;


--
-- Name: TABLE commission_rule_components; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.commission_rule_components TO authenticated;
GRANT ALL ON TABLE public.commission_rule_components TO service_role;


--
-- Name: TABLE component_payout_policies; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.component_payout_policies TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.component_payout_policies TO authenticated;


--
-- Name: TABLE component_payout_policy_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.component_payout_policy_items TO service_role;
GRANT SELECT,INSERT ON TABLE public.component_payout_policy_items TO authenticated;


--
-- Name: TABLE component_payout_policy_versions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.component_payout_policy_versions TO service_role;
GRANT SELECT,INSERT ON TABLE public.component_payout_policy_versions TO authenticated;


--
-- Name: TABLE contract_types; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.contract_types TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.contract_types TO authenticated;


--
-- Name: TABLE contracts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.contracts TO authenticated;
GRANT ALL ON TABLE public.contracts TO service_role;


--
-- Name: TABLE customer_addresses; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.customer_addresses TO authenticated;
GRANT ALL ON TABLE public.customer_addresses TO service_role;


--
-- Name: TABLE customer_bank_accounts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.customer_bank_accounts TO authenticated;
GRANT ALL ON TABLE public.customer_bank_accounts TO service_role;


--
-- Name: TABLE customer_documents; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.customer_documents TO authenticated;
GRANT ALL ON TABLE public.customer_documents TO service_role;


--
-- Name: TABLE customer_pix_keys; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.customer_pix_keys TO authenticated;
GRANT ALL ON TABLE public.customer_pix_keys TO service_role;


--
-- Name: TABLE customer_timeline_events; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,MAINTAIN ON TABLE public.customer_timeline_events TO authenticated;
GRANT ALL ON TABLE public.customer_timeline_events TO service_role;


--
-- Name: TABLE digitization_jobs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,MAINTAIN,UPDATE ON TABLE public.digitization_jobs TO authenticated;
GRANT ALL ON TABLE public.digitization_jobs TO service_role;


--
-- Name: TABLE document_checklist_items; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.document_checklist_items TO authenticated;
GRANT ALL ON TABLE public.document_checklist_items TO service_role;


--
-- Name: TABLE document_checklist_templates; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.document_checklist_templates TO authenticated;
GRANT ALL ON TABLE public.document_checklist_templates TO service_role;


--
-- Name: TABLE document_types; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.document_types TO service_role;
GRANT SELECT ON TABLE public.document_types TO authenticated;


--
-- Name: TABLE financial_events; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,MAINTAIN ON TABLE public.financial_events TO authenticated;
GRANT ALL ON TABLE public.financial_events TO service_role;


--
-- Name: TABLE financial_evidence_links; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,MAINTAIN ON TABLE public.financial_evidence_links TO authenticated;
GRANT ALL ON TABLE public.financial_evidence_links TO service_role;


--
-- Name: TABLE financial_reconciliation_cases; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,MAINTAIN,UPDATE ON TABLE public.financial_reconciliation_cases TO authenticated;
GRANT ALL ON TABLE public.financial_reconciliation_cases TO service_role;


--
-- Name: TABLE import_applied_decisions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.import_applied_decisions TO authenticated;
GRANT ALL ON TABLE public.import_applied_decisions TO service_role;


--
-- Name: TABLE import_batches; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.import_batches TO authenticated;
GRANT ALL ON TABLE public.import_batches TO service_role;


--
-- Name: TABLE import_conflict_rows; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.import_conflict_rows TO service_role;
GRANT SELECT,INSERT ON TABLE public.import_conflict_rows TO authenticated;


--
-- Name: TABLE import_conflicts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.import_conflicts TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.import_conflicts TO authenticated;


--
-- Name: TABLE import_decisions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.import_decisions TO authenticated;
GRANT ALL ON TABLE public.import_decisions TO service_role;


--
-- Name: TABLE import_jobs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.import_jobs TO authenticated;
GRANT ALL ON TABLE public.import_jobs TO service_role;


--
-- Name: TABLE import_layout_mappings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.import_layout_mappings TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.import_layout_mappings TO authenticated;


--
-- Name: TABLE import_match_candidates; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.import_match_candidates TO authenticated;
GRANT ALL ON TABLE public.import_match_candidates TO service_role;


--
-- Name: TABLE import_normalized_rows; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.import_normalized_rows TO authenticated;
GRANT ALL ON TABLE public.import_normalized_rows TO service_role;


--
-- Name: COLUMN import_normalized_rows.id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(id) ON TABLE public.import_normalized_rows TO authenticated;


--
-- Name: COLUMN import_normalized_rows.organization_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(organization_id) ON TABLE public.import_normalized_rows TO authenticated;


--
-- Name: COLUMN import_normalized_rows.raw_row_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(raw_row_id) ON TABLE public.import_normalized_rows TO authenticated;


--
-- Name: COLUMN import_normalized_rows.record_kind; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(record_kind) ON TABLE public.import_normalized_rows TO authenticated;


--
-- Name: COLUMN import_normalized_rows.bank_key; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(bank_key) ON TABLE public.import_normalized_rows TO authenticated;


--
-- Name: COLUMN import_normalized_rows.external_proposal_number; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(external_proposal_number) ON TABLE public.import_normalized_rows TO authenticated;


--
-- Name: COLUMN import_normalized_rows.producer_tax_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(producer_tax_id) ON TABLE public.import_normalized_rows TO authenticated;


--
-- Name: COLUMN import_normalized_rows.external_table_code; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(external_table_code) ON TABLE public.import_normalized_rows TO authenticated;


--
-- Name: COLUMN import_normalized_rows.external_table_name; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(external_table_name) ON TABLE public.import_normalized_rows TO authenticated;


--
-- Name: COLUMN import_normalized_rows.operation_type; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(operation_type) ON TABLE public.import_normalized_rows TO authenticated;


--
-- Name: COLUMN import_normalized_rows.term; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(term) ON TABLE public.import_normalized_rows TO authenticated;


--
-- Name: COLUMN import_normalized_rows.rate; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(rate) ON TABLE public.import_normalized_rows TO authenticated;


--
-- Name: COLUMN import_normalized_rows.normalization_version; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(normalization_version) ON TABLE public.import_normalized_rows TO authenticated;


--
-- Name: COLUMN import_normalized_rows.created_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(created_at) ON TABLE public.import_normalized_rows TO authenticated;


--
-- Name: TABLE import_raw_rows; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.import_raw_rows TO authenticated;
GRANT ALL ON TABLE public.import_raw_rows TO service_role;


--
-- Name: TABLE import_sources; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.import_sources TO authenticated;
GRANT ALL ON TABLE public.import_sources TO service_role;


--
-- Name: TABLE integration_adapters; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.integration_adapters TO service_role;
GRANT SELECT ON TABLE public.integration_adapters TO authenticated;


--
-- Name: TABLE integration_field_mappings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.integration_field_mappings TO service_role;
GRANT SELECT ON TABLE public.integration_field_mappings TO authenticated;


--
-- Name: TABLE integration_run_artifacts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.integration_run_artifacts TO service_role;
GRANT SELECT ON TABLE public.integration_run_artifacts TO authenticated;


--
-- Name: TABLE integration_runs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.integration_runs TO service_role;
GRANT SELECT ON TABLE public.integration_runs TO authenticated;


--
-- Name: TABLE integration_source_bindings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.integration_source_bindings TO service_role;
GRANT SELECT ON TABLE public.integration_source_bindings TO authenticated;


--
-- Name: TABLE lead_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.lead_events TO service_role;
GRANT SELECT ON TABLE public.lead_events TO authenticated;


--
-- Name: TABLE leads; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.leads TO service_role;
GRANT SELECT ON TABLE public.leads TO authenticated;


--
-- Name: TABLE modalities; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.modalities TO service_role;
GRANT SELECT ON TABLE public.modalities TO authenticated;


--
-- Name: TABLE national_agreement_templates; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.national_agreement_templates TO service_role;
GRANT SELECT ON TABLE public.national_agreement_templates TO authenticated;


--
-- Name: TABLE network_split_rule_versions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.network_split_rule_versions TO authenticated;
GRANT ALL ON TABLE public.network_split_rule_versions TO service_role;


--
-- Name: TABLE operational_attention_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.operational_attention_events TO service_role;
GRANT SELECT,INSERT ON TABLE public.operational_attention_events TO authenticated;


--
-- Name: TABLE operational_attention_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.operational_attention_items TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.operational_attention_items TO authenticated;


--
-- Name: TABLE operational_cases; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,MAINTAIN,UPDATE ON TABLE public.operational_cases TO authenticated;
GRANT ALL ON TABLE public.operational_cases TO service_role;


--
-- Name: TABLE operational_events; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,MAINTAIN ON TABLE public.operational_events TO authenticated;
GRANT ALL ON TABLE public.operational_events TO service_role;


--
-- Name: TABLE operational_stages; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.operational_stages TO authenticated;
GRANT ALL ON TABLE public.operational_stages TO service_role;


--
-- Name: TABLE organization_admin_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.organization_admin_events TO service_role;
GRANT SELECT,INSERT ON TABLE public.organization_admin_events TO authenticated;


--
-- Name: TABLE organization_agreements; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.organization_agreements TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.organization_agreements TO authenticated;


--
-- Name: TABLE organization_ai_limits; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.organization_ai_limits TO service_role;
GRANT SELECT ON TABLE public.organization_ai_limits TO authenticated;


--
-- Name: TABLE organization_banks; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.organization_banks TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.organization_banks TO authenticated;


--
-- Name: TABLE organization_branches; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.organization_branches TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.organization_branches TO authenticated;


--
-- Name: TABLE organization_contract_type_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.organization_contract_type_settings TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.organization_contract_type_settings TO authenticated;


--
-- Name: TABLE organization_invitations; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.organization_invitations TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.organization_invitations TO authenticated;


--
-- Name: TABLE organization_memberships; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.organization_memberships TO authenticated;
GRANT ALL ON TABLE public.organization_memberships TO service_role;


--
-- Name: COLUMN organization_memberships.role; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(role) ON TABLE public.organization_memberships TO authenticated;


--
-- Name: COLUMN organization_memberships.status; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(status) ON TABLE public.organization_memberships TO authenticated;


--
-- Name: COLUMN organization_memberships.updated_at; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(updated_at) ON TABLE public.organization_memberships TO authenticated;


--
-- Name: TABLE organization_product_routes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.organization_product_routes TO authenticated;
GRANT ALL ON TABLE public.organization_product_routes TO service_role;


--
-- Name: TABLE organization_providers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.organization_providers TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.organization_providers TO authenticated;


--
-- Name: TABLE organizations; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.organizations TO authenticated;
GRANT ALL ON TABLE public.organizations TO service_role;


--
-- Name: TABLE payout_policies; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.payout_policies TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.payout_policies TO authenticated;


--
-- Name: TABLE payout_policy_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.payout_policy_items TO service_role;
GRANT SELECT,INSERT ON TABLE public.payout_policy_items TO authenticated;


--
-- Name: TABLE payout_policy_versions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.payout_policy_versions TO service_role;
GRANT SELECT,INSERT ON TABLE public.payout_policy_versions TO authenticated;


--
-- Name: TABLE platform_admin_audit_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.platform_admin_audit_events TO service_role;


--
-- Name: TABLE platform_administrators; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.platform_administrators TO service_role;


--
-- Name: TABLE product_table_external_identities; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.product_table_external_identities TO authenticated;
GRANT ALL ON TABLE public.product_table_external_identities TO service_role;


--
-- Name: TABLE product_table_versions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.product_table_versions TO authenticated;
GRANT ALL ON TABLE public.product_table_versions TO service_role;


--
-- Name: TABLE product_tables; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.product_tables TO authenticated;
GRANT ALL ON TABLE public.product_tables TO service_role;


--
-- Name: TABLE products; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.products TO service_role;
GRANT SELECT ON TABLE public.products TO authenticated;


--
-- Name: TABLE profiles; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.profiles TO authenticated;
GRANT ALL ON TABLE public.profiles TO service_role;


--
-- Name: TABLE proposal_commercial_component_snapshots; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,MAINTAIN ON TABLE public.proposal_commercial_component_snapshots TO authenticated;
GRANT ALL ON TABLE public.proposal_commercial_component_snapshots TO service_role;


--
-- Name: TABLE proposal_commercial_snapshots; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT,MAINTAIN ON TABLE public.proposal_commercial_snapshots TO authenticated;
GRANT ALL ON TABLE public.proposal_commercial_snapshots TO service_role;


--
-- Name: COLUMN proposal_commercial_snapshots.proposal_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(proposal_id) ON TABLE public.proposal_commercial_snapshots TO authenticated;


--
-- Name: COLUMN proposal_commercial_snapshots.organization_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(organization_id) ON TABLE public.proposal_commercial_snapshots TO authenticated;


--
-- Name: COLUMN proposal_commercial_snapshots.channel_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(channel_id) ON TABLE public.proposal_commercial_snapshots TO authenticated;


--
-- Name: COLUMN proposal_commercial_snapshots.producer_entity_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(producer_entity_id) ON TABLE public.proposal_commercial_snapshots TO authenticated;


--
-- Name: COLUMN proposal_commercial_snapshots.payer_entity_id; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(payer_entity_id) ON TABLE public.proposal_commercial_snapshots TO authenticated;


--
-- Name: COLUMN proposal_commercial_snapshots.created_at; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT(created_at) ON TABLE public.proposal_commercial_snapshots TO authenticated;


--
-- Name: TABLE proposal_document_links; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.proposal_document_links TO authenticated;
GRANT ALL ON TABLE public.proposal_document_links TO service_role;


--
-- Name: TABLE proposal_document_requirements; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.proposal_document_requirements TO authenticated;
GRANT ALL ON TABLE public.proposal_document_requirements TO service_role;


--
-- Name: TABLE proposal_external_identities; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.proposal_external_identities TO authenticated;
GRANT ALL ON TABLE public.proposal_external_identities TO service_role;


--
-- Name: TABLE proposal_seller_commission_snapshots; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.proposal_seller_commission_snapshots TO service_role;
GRANT SELECT,INSERT ON TABLE public.proposal_seller_commission_snapshots TO authenticated;


--
-- Name: TABLE proposal_status_evidence; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLE public.proposal_status_evidence TO authenticated;
GRANT ALL ON TABLE public.proposal_status_evidence TO service_role;


--
-- Name: TABLE proposals_v2; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,MAINTAIN,UPDATE ON TABLE public.proposals_v2 TO authenticated;
GRANT ALL ON TABLE public.proposals_v2 TO service_role;


--
-- Name: TABLE providers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.providers TO service_role;
GRANT SELECT ON TABLE public.providers TO authenticated;


--
-- Name: TABLE seller_addresses; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.seller_addresses TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.seller_addresses TO authenticated;


--
-- Name: TABLE seller_bank_aliases; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.seller_bank_aliases TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.seller_bank_aliases TO authenticated;


--
-- Name: TABLE seller_certifications; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.seller_certifications TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.seller_certifications TO authenticated;


--
-- Name: TABLE seller_groups; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.seller_groups TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.seller_groups TO authenticated;


--
-- Name: TABLE seller_payment_accounts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.seller_payment_accounts TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.seller_payment_accounts TO authenticated;


--
-- Name: TABLE seller_profiles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.seller_profiles TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.seller_profiles TO authenticated;


--
-- Name: TABLE seller_sub_rule_versions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.seller_sub_rule_versions TO service_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.seller_sub_rule_versions TO authenticated;


--
-- Name: TABLE seller_supervisions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.seller_supervisions TO service_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.seller_supervisions TO authenticated;


--
-- Name: TABLE simulations; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,MAINTAIN ON TABLE public.simulations TO authenticated;
GRANT ALL ON TABLE public.simulations TO service_role;


--
-- Name: COLUMN simulations.organization_id; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(organization_id) ON TABLE public.simulations TO authenticated;


--
-- Name: COLUMN simulations.customer_id; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(customer_id) ON TABLE public.simulations TO authenticated;


--
-- Name: COLUMN simulations.product_table_version_id; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(product_table_version_id) ON TABLE public.simulations TO authenticated;


--
-- Name: COLUMN simulations.status; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(status),UPDATE(status) ON TABLE public.simulations TO authenticated;


--
-- Name: COLUMN simulations.requested_amount; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(requested_amount) ON TABLE public.simulations TO authenticated;


--
-- Name: COLUMN simulations.installment_amount; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(installment_amount) ON TABLE public.simulations TO authenticated;


--
-- Name: COLUMN simulations.term; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(term) ON TABLE public.simulations TO authenticated;


--
-- Name: COLUMN simulations.rate; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(rate) ON TABLE public.simulations TO authenticated;


--
-- Name: COLUMN simulations.coefficient; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(coefficient) ON TABLE public.simulations TO authenticated;


--
-- Name: COLUMN simulations.input_snapshot; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(input_snapshot) ON TABLE public.simulations TO authenticated;


--
-- Name: COLUMN simulations.result_snapshot; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(result_snapshot) ON TABLE public.simulations TO authenticated;


--
-- Name: COLUMN simulations.created_by; Type: ACL; Schema: public; Owner: -
--

GRANT INSERT(created_by) ON TABLE public.simulations TO authenticated;


--
-- Name: COLUMN simulations.updated_at; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(updated_at) ON TABLE public.simulations TO authenticated;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--



--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--



--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,INSERT,DELETE,MAINTAIN,UPDATE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--



--
-- PostgreSQL database dump complete
--


