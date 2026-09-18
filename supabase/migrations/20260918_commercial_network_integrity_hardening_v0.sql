-- CORBAN OS V2 — Commercial Network Integrity Hardening V0
-- PREPARED ONLY. Requires explicit Human Gate before production apply.
-- Closes cross-tenant reference paths and freezes published commercial truth.

create or replace function public.assert_same_organization_reference()
returns trigger language plpgsql set search_path=public as $$
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

do $$ declare t text; begin
 foreach t in array array['commercial_relationships','commercial_channels','product_table_external_identities','proposal_external_identities','proposal_commercial_snapshots','channel_commission_rule_versions','commission_rule_components','network_split_rule_versions']
 loop execute format('drop trigger if exists %I on public.%I',t||'_same_org_guard',t);
 execute format('create trigger %I before insert or update on public.%I for each row execute function public.assert_same_organization_reference()',t||'_same_org_guard',t);
 end loop;
end $$;

create or replace function public.freeze_published_commercial_rule()
returns trigger language plpgsql set search_path=public as $$
begin
 if old.status='published' then raise exception 'published_commercial_rule_is_immutable'; end if;
 return new;
end $$;
drop trigger if exists channel_commission_rule_versions_freeze_published on public.channel_commission_rule_versions;
create trigger channel_commission_rule_versions_freeze_published before update or delete on public.channel_commission_rule_versions for each row execute function public.freeze_published_commercial_rule();
drop trigger if exists network_split_rule_versions_freeze_published on public.network_split_rule_versions;
create trigger network_split_rule_versions_freeze_published before update or delete on public.network_split_rule_versions for each row execute function public.freeze_published_commercial_rule();

revoke all on function public.assert_same_organization_reference() from public,anon,authenticated;
revoke all on function public.freeze_published_commercial_rule() from public,anon,authenticated;
