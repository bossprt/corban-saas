-- CORBAN OS — Seller operations identity V1
-- PREPARED ONLY. Requires explicit Human Gate before LIVE apply.
-- Adds branch/matrix, commission payment frequency and deterministic bank-user aliases.

create table public.organization_branches(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  code text not null,
  name text not null,
  branch_type text not null check(branch_type in ('matrix','branch')),
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,id),
  unique(organization_id,code)
);

create unique index organization_branches_one_matrix
  on public.organization_branches(organization_id)
  where branch_type='matrix';

insert into public.organization_branches(organization_id,code,name,branch_type)
select o.id,'MATRIZ','Matriz','matrix'
from public.organizations o
where not exists(
  select 1 from public.organization_branches b
  where b.organization_id=o.id and b.branch_type='matrix'
);

alter table public.commercial_sellers
  add column branch_id uuid,
  add column commission_payment_frequency text not null default 'monthly'
    check(commission_payment_frequency in ('daily','weekly','monthly'));

update public.commercial_sellers s
set branch_id=b.id
from public.organization_branches b
where b.organization_id=s.organization_id
  and b.branch_type='matrix'
  and s.branch_id is null;

alter table public.commercial_sellers
  alter column branch_id set not null;

alter table public.commercial_sellers
  add constraint commercial_sellers_org_branch_fk
  foreign key(organization_id,branch_id)
  references public.organization_branches(organization_id,id)
  on delete restrict;

create table public.seller_bank_aliases(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  seller_id uuid not null,
  source_key text not null,
  external_user text not null,
  external_user_normalized text not null,
  bank_id uuid references public.banks(id) on delete restrict,
  provider_id uuid references public.providers(id) on delete restrict,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,id),
  foreign key(organization_id,seller_id)
    references public.commercial_sellers(organization_id,id) on delete restrict
);

create unique index seller_bank_aliases_scope_user_key
  on public.seller_bank_aliases(
    organization_id,
    lower(btrim(source_key)),
    external_user_normalized
  )
  where is_active;

create index seller_bank_aliases_seller_idx
  on public.seller_bank_aliases(organization_id,seller_id)
  where is_active;

create or replace function public.normalize_external_user(p_value text)
returns text
language sql immutable
set search_path=''
as $$
  select nullif(lower(regexp_replace(btrim(coalesce(p_value,'')),'[[:space:]]+',' ','g')),'')
$$;

create or replace function public.guard_seller_bank_alias()
returns trigger
language plpgsql
set search_path=''
as $$
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

create trigger seller_bank_aliases_00_guard
before insert or update or delete on public.seller_bank_aliases
for each row execute function public.guard_seller_bank_alias();

create or replace function public.resolve_seller_bank_alias(
  p_org uuid,
  p_source_key text,
  p_external_user text
)
returns uuid
language sql stable
security invoker
set search_path=''
as $$
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

alter table public.import_normalized_rows
  add column producer_external_user text,
  add column resolved_seller_id uuid;

alter table public.import_normalized_rows
  add constraint import_normalized_rows_org_seller_fk
  foreign key(organization_id,resolved_seller_id)
  references public.commercial_sellers(organization_id,id)
  on delete restrict;

alter table public.import_match_candidates
  add column seller_id uuid;

alter table public.import_match_candidates
  add constraint import_match_candidates_org_seller_fk
  foreign key(organization_id,seller_id)
  references public.commercial_sellers(organization_id,id)
  on delete restrict;

create or replace function public.ingest_normalized_import_batch(
  p_source_id uuid,
  p_original_filename text,
  p_content_sha256 text,
  p_mime_type text,
  p_parser_key text,
  p_parser_version text,
  p_rows jsonb
)
returns uuid
language plpgsql
set search_path='public'
as $$
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
$$;

create or replace function public.generate_import_match_candidates(p_batch_id uuid)
returns integer
language plpgsql
set search_path='public'
as $$
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

alter table public.organization_branches enable row level security;
alter table public.seller_bank_aliases enable row level security;

revoke all on public.organization_branches,public.seller_bank_aliases from public,anon,authenticated;
grant select,insert,update on public.organization_branches to authenticated;
grant select,insert,update on public.seller_bank_aliases to authenticated;

create policy organization_branches_select_member on public.organization_branches
for select to authenticated
using(public.is_active_organization_member(organization_id));

create policy organization_branches_write_manager on public.organization_branches
for all to authenticated
using(public.has_active_organization_role(organization_id,array['admin','manager']))
with check(public.has_active_organization_role(organization_id,array['admin','manager']));

create policy seller_bank_aliases_select_scoped on public.seller_bank_aliases
for select to authenticated
using(
  public.has_active_organization_role(organization_id,array['admin','manager'])
  or public.can_view_seller_profile(organization_id,seller_id)
);

create policy seller_bank_aliases_write_manager on public.seller_bank_aliases
for all to authenticated
using(public.has_active_organization_role(organization_id,array['admin','manager']))
with check(public.has_active_organization_role(organization_id,array['admin','manager']));

revoke all on function public.guard_seller_bank_alias() from public,anon,authenticated;
revoke all on function public.normalize_external_user(text) from public,anon;
grant execute on function public.normalize_external_user(text) to authenticated;
revoke all on function public.resolve_seller_bank_alias(uuid,text,text) from public,anon;
grant execute on function public.resolve_seller_bank_alias(uuid,text,text) to authenticated;
