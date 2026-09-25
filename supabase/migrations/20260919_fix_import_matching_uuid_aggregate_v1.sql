-- PREPARED, NOT APPLIED (Human Gate: replaces a live production function; logic unchanged except the aggregate).
-- Found by the rollback-only E2E: generate_import_match_candidates used min(uuid), which does not exist in PostgreSQL 17:
--   ERROR 42883: function min(uuid) does not exist
-- It raised for EVERY row with an external proposal number or table code, so import matching never worked live (and the
-- ingestion action reports "Lote ingerido, mas o matching determinístico falhou"). The value is only read when count(*) = 1,
-- so (array_agg(x))[1] is equivalent. The same migration also stops members from forging match candidates:
-- import_match_candidates had an INSERT policy for every member, so anyone could insert an 'exact' candidate pointing at any
-- proposal of the tenant. Candidates are now writable only by this function (transaction-local token + trigger).
-- (The token is defence in depth, not a hard boundary against arbitrary SQL.) Tenant derivation is already resource-based (the batch): unchanged.
create or replace function public.generate_import_match_candidates(p_batch_id uuid)
 returns integer
 language plpgsql
 set search_path to 'public'
as $function$
declare v_user uuid:=auth.uid();v_org uuid;v_count integer:=0;r record;v_proposal uuid;v_proposal_count integer;v_table uuid;v_table_count integer;v_channel uuid;
begin
 select b.organization_id into v_org from public.import_batches b
 where b.id=p_batch_id and public.is_active_organization_member(b.organization_id);
 if v_org is null then raise exception 'batch_not_found_or_forbidden'; end if;
 perform set_config('corban.import_match_rpc','on',true);

 for r in
  select n.* from public.import_normalized_rows n
  join public.import_raw_rows rr on rr.id=n.raw_row_id and rr.organization_id=n.organization_id
  where rr.batch_id=p_batch_id and n.organization_id=v_org
 loop
  if exists(select 1 from public.import_match_candidates c where c.organization_id=v_org and c.normalized_row_id=r.id) then continue; end if;
  v_proposal:=null;v_proposal_count:=0;v_table:=null;v_table_count:=0;v_channel:=null;

  if r.external_proposal_number is not null then
   select count(*),(array_agg(e.proposal_id))[1] into v_proposal_count,v_proposal
   from public.proposal_external_identities e
   where e.organization_id=v_org and e.external_proposal_number=r.external_proposal_number
     and (r.bank_key is null or lower(e.institution_key)=lower(r.bank_key));
  end if;

  if r.external_table_code is not null then
   select count(*),(array_agg(e.product_table_id))[1],(array_agg(e.channel_id))[1] into v_table_count,v_table,v_channel
   from public.product_table_external_identities e
   where e.organization_id=v_org and e.external_code=r.external_table_code
     and (e.effective_until is null or e.effective_until>now());
  end if;

  if v_proposal_count=1 then
   insert into public.import_match_candidates(organization_id,normalized_row_id,proposal_id,product_table_id,channel_id,match_strength,match_basis,status)
   values(v_org,r.id,v_proposal,case when v_table_count=1 then v_table end,case when v_table_count=1 then v_channel end,'exact',
    jsonb_build_object('external_proposal_number',r.external_proposal_number,'bank_key',r.bank_key,'proposal_matches',v_proposal_count,'table_matches',v_table_count),'suggested');
  elsif v_proposal_count>1 then
   insert into public.import_match_candidates(organization_id,normalized_row_id,match_strength,match_basis,status)
   values(v_org,r.id,'ambiguous',jsonb_build_object('external_proposal_number',r.external_proposal_number,'proposal_matches',v_proposal_count),'human_required');
  elsif v_table_count=1 then
   insert into public.import_match_candidates(organization_id,normalized_row_id,product_table_id,channel_id,match_strength,match_basis,status)
   values(v_org,r.id,v_table,v_channel,'strong',jsonb_build_object('external_table_code',r.external_table_code,'table_matches',1),'suggested');
  elsif v_table_count>1 then
   insert into public.import_match_candidates(organization_id,normalized_row_id,match_strength,match_basis,status)
   values(v_org,r.id,'ambiguous',jsonb_build_object('external_table_code',r.external_table_code,'table_matches',v_table_count),'human_required');
  else
   insert into public.import_match_candidates(organization_id,normalized_row_id,match_strength,match_basis,status)
   values(v_org,r.id,'none',jsonb_build_object('external_proposal_number',r.external_proposal_number,'external_table_code',r.external_table_code),'human_required');
  end if;
  v_count:=v_count+1;
 end loop;
 perform set_config('corban.import_match_rpc','off',true);
 update public.import_batches set status='ready_for_review',completed_at=coalesce(completed_at,now()) where id=p_batch_id and organization_id=v_org;
 return v_count;
end $function$;

create or replace function public.guard_import_match_candidate_insert()
returns trigger language plpgsql set search_path='' as $$
begin
 if current_setting('corban.import_match_rpc',true) is distinct from 'on' then raise exception 'match_candidate_requires_governed_rpc'; end if;
 return new;
end $$;
revoke all on function public.guard_import_match_candidate_insert() from public,anon,authenticated;
drop trigger if exists trg_import_match_candidate_insert on public.import_match_candidates;
create trigger trg_import_match_candidate_insert before insert on public.import_match_candidates
for each row execute function public.guard_import_match_candidate_insert();
