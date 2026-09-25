-- F7: broker portal (MAPA-OPERACAO §1, owner decisions of 24/09/2026).
--
-- A broker or partner (a registered seller with a login, usually with the 'corretor' role) sends proposals through the
-- portal. A sent proposal waits for validation by someone who may edit the pipeline, never by whoever sent it; only a
-- validated proposal enters the pipeline and may have its commission calculated. A refusal always carries a reason the
-- broker sees.
--
-- Privacy: when the CPF is already a client of the company (maybe of another seller), the proposal links to that client
-- but the broker never sees the existing record. The existing client is not changed until validation; what the broker
-- typed stays in the proposal snapshot; the internal queue shows "client already exists, portfolio of X".
--
-- Documents sent with the proposal live under <org>/portal/<proposal>/ in the private bucket: only the sender and whoever
-- sees the proposal read them.

-- Submissions ------------------------------------------------------------------------------------------------------------

create table public.proposal_submissions (
  proposal_id uuid primary key,
  organization_id uuid not null,
  seller_id uuid not null,
  submitted_by uuid not null,
  status text not null check (status in ('pending','validated','rejected')),
  decided_by uuid,
  decided_at timestamptz,
  decision_reason text check (length(decision_reason) <= 300),
  created_at timestamptz not null default now(),
  unique (organization_id, proposal_id),
  constraint submission_decision_shape check ((status = 'pending') = (decided_at is null)),
  constraint submission_rejection_reason check (status <> 'rejected' or length(btrim(coalesce(decision_reason, ''))) >= 3),
  foreign key (organization_id, proposal_id) references public.proposals_v2 (organization_id, id) on delete restrict,
  foreign key (organization_id, seller_id) references public.commercial_sellers (organization_id, id) on delete restrict
);

create index proposal_submissions_pending_idx on public.proposal_submissions (organization_id, created_at) where status = 'pending';
create index proposal_submissions_submitter_idx on public.proposal_submissions (submitted_by);

create table public.proposal_submission_documents (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  proposal_id uuid not null,
  label text not null check (length(btrim(label)) between 2 and 60),
  storage_path text not null unique check (length(storage_path) <= 400),
  original_file_name text not null check (length(original_file_name) between 1 and 160),
  mime_type text not null check (mime_type in ('application/pdf','image/jpeg','image/png','image/webp')),
  file_size_bytes integer not null check (file_size_bytes between 1 and 4194304),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  uploaded_by uuid not null,
  created_at timestamptz not null default now(),
  unique (proposal_id, sha256),
  foreign key (organization_id, proposal_id) references public.proposal_submissions (organization_id, proposal_id) on delete restrict
);

create or replace function public.guard_submission_write()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if current_setting('corban.submission_rpc', true) is distinct from 'on' then raise exception 'submission_write_requires_governed_rpc'; end if;
  if tg_op = 'DELETE' then raise exception 'submission_records_are_not_deletable'; end if;
  if tg_op = 'UPDATE' then
    if tg_table_name <> 'proposal_submissions' then raise exception 'submission_document_is_immutable'; end if;
    if old.status <> 'pending' then raise exception 'submission_already_decided'; end if;
    if (to_jsonb(new) - array['status','decided_by','decided_at','decision_reason'])
       is distinct from (to_jsonb(old) - array['status','decided_by','decided_at','decision_reason']) then
      raise exception 'submission_is_immutable';
    end if;
  end if;
  return new;
end
$$;

revoke all on function public.guard_submission_write() from public, anon, authenticated;
create trigger proposal_submissions_00_guard before insert or update or delete on public.proposal_submissions for each row execute function public.guard_submission_write();
create trigger proposal_submission_documents_00_guard before insert or update or delete on public.proposal_submission_documents for each row execute function public.guard_submission_write();

alter table public.proposal_submissions enable row level security;
alter table public.proposal_submission_documents enable row level security;
revoke all on table public.proposal_submissions, public.proposal_submission_documents from anon, authenticated;
grant select on public.proposal_submissions, public.proposal_submission_documents to authenticated;

-- Whoever sees the proposal (the broker their own; the team by visibility scope) sees its submission and documents.
create policy proposal_submissions_select on public.proposal_submissions for select to authenticated
  using (public.is_active_organization_member(organization_id) and exists (select 1 from public.proposals_v2 p where p.id = proposal_id));
create policy proposal_submission_documents_select on public.proposal_submission_documents for select to authenticated
  using (public.is_active_organization_member(organization_id) and exists (select 1 from public.proposals_v2 p where p.id = proposal_id));

-- A proposal sent through the portal gives no view of its client until it is validated.
create or replace function private.can_see_client_row(p_org uuid, p_client_id uuid, p_owner uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select private.can_see_owner(p_org, p_owner)
      or exists (select 1 from public.leads l
                 where l.organization_id = p_org and l.customer_id = p_client_id
                   and private.can_see_owner(p_org, coalesce(l.owner_user_id, l.created_by)))
      or exists (select 1 from public.proposals_v2 p
                 where p.organization_id = p_org and p.customer_id = p_client_id
                   and private.can_see_proposal_row(p_org, p.seller_id, p.created_by)
                   and not exists (select 1 from public.proposal_submissions s where s.proposal_id = p.id and s.status <> 'validated'))
$$;

-- No commission is calculated for a proposal that is waiting for validation or was refused.
create or replace function public.guard_commission_submission()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if exists (select 1 from public.proposal_submissions s where s.proposal_id = new.proposal_id and s.status <> 'validated') then
    raise exception 'proposal_pending_validation';
  end if;
  return new;
end
$$;

revoke all on function public.guard_commission_submission() from public, anon, authenticated;
create trigger proposal_commission_calcs_05_submission before insert on public.proposal_commission_calcs for each row execute function public.guard_commission_submission();

-- Portal RPCs ------------------------------------------------------------------------------------------------------------

-- The broker sends a client and a proposal. The caller must be a registered, active seller of the company.
create or replace function public.submit_broker_proposal(p_org uuid, p_cpf text, p_full_name text, p_phone text, p_email text,
  p_table_version_id uuid, p_requested_amount numeric, p_released_amount numeric, p_installment_amount numeric, p_term integer, p_ade text)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_seller uuid;
  v_cpf text := regexp_replace(coalesce(p_cpf, ''), '[^0-9]', '', 'g');
  v_name text := btrim(coalesce(p_full_name, ''));
  v_phone text := private.normalize_phone(p_phone);
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_ade text := nullif(btrim(coalesce(p_ade, '')), '');
  v_client uuid;
  v_bank_key text; v_bank_name text; v_table_name text;
  v_id uuid;
begin
  if auth.uid() is null or not public.is_active_organization_member(p_org) or not public.has_permission(p_org, 'propostas.create') then
    raise exception 'not_authorized';
  end if;
  select s.id into v_seller from public.commercial_sellers s where s.organization_id = p_org and s.user_id = auth.uid() and s.is_active;
  if v_seller is null then raise exception 'seller_profile_required'; end if;
  if not private.is_valid_cpf(v_cpf) then raise exception 'invalid_cpf'; end if;
  if length(v_name) < 3 or length(v_name) > 160 then raise exception 'full_name_required'; end if;
  if v_email is not null and v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'invalid_email'; end if;
  if v_ade is not null and (length(v_ade) > 60 or v_ade !~ '^[A-Za-z0-9./-]+$') then raise exception 'invalid_ade'; end if;
  if coalesce(p_requested_amount, 0) < 0 or coalesce(p_released_amount, 0) < 0 or coalesce(p_installment_amount, 0) < 0 then raise exception 'invalid_amount'; end if;
  if p_released_amount is null and p_requested_amount is null then raise exception 'amount_required'; end if;
  if p_term is not null and (p_term < 1 or p_term > 420) then raise exception 'invalid_term'; end if;

  select coalesce(ob.tech_key, b.code, b.name), coalesce(ob.name, b.name), t.name into v_bank_key, v_bank_name, v_table_name
  from public.product_table_versions v
  join public.product_tables t on t.id = v.product_table_id and t.organization_id = v.organization_id
  join public.organization_product_routes r on r.id = t.route_id and r.organization_id = t.organization_id
  left join public.organization_banks ob on ob.id = r.org_bank_id and ob.organization_id = r.organization_id
  left join public.banks b on b.id = r.bank_id
  where v.organization_id = p_org and v.id = p_table_version_id and v.status = 'published';
  if v_bank_key is null then raise exception 'table_not_found'; end if;

  if v_ade is not null then
    perform pg_advisory_xact_lock(hashtext(p_org::text || ':' || lower(v_bank_key) || ':' || v_ade));
    if exists (select 1 from public.proposal_external_identities e
               where e.organization_id = p_org and lower(e.institution_key) = lower(v_bank_key) and e.external_proposal_number = v_ade) then
      raise exception 'proposal_already_exists';
    end if;
  end if;

  -- An existing client is linked as is (nothing of it is changed or returned); a new one is created for the broker.
  perform pg_advisory_xact_lock(hashtext(p_org::text || ':' || v_cpf));
  select c.id into v_client from public.clients c where c.organization_id = p_org and c.cpf = v_cpf and c.deleted_at is null;
  if v_client is null then
    select u.client_id into v_client from private.upsert_client_core(p_org, v_cpf, v_name, v_phone, v_email, 'portal', auth.uid()) u;
  end if;

  perform set_config('corban.proposal_rpc', 'on', true);
  insert into public.proposals_v2 (organization_id, customer_id, simulation_id, product_table_version_id, status, external_proposal_id,
                                   requested_amount, released_amount, installment_amount, term, customer_snapshot, commercial_snapshot, seller_id, created_by)
  values (p_org, v_client, null, p_table_version_id, case when v_ade is null then 'digitization' else 'submitted' end, v_ade,
          p_requested_amount, p_released_amount, p_installment_amount, p_term,
          jsonb_build_object('full_name', v_name, 'cpf', v_cpf, 'phone', v_phone, 'email', v_email),
          jsonb_build_object('origin', 'portal', 'bank', v_bank_name, 'table', v_table_name, 'table_version_id', p_table_version_id),
          v_seller, auth.uid())
  returning id into v_id;
  if v_ade is not null then
    insert into public.proposal_external_identities (organization_id, proposal_id, institution_key, external_proposal_number, source)
    values (p_org, v_id, v_bank_key, v_ade, 'manual');
  end if;
  perform set_config('corban.proposal_rpc', 'off', true);

  perform set_config('corban.submission_rpc', 'on', true);
  insert into public.proposal_submissions (proposal_id, organization_id, seller_id, submitted_by, status)
  values (v_id, p_org, v_seller, auth.uid(), 'pending');
  perform set_config('corban.submission_rpc', 'off', true);
  return v_id;
end
$$;

-- Records a document the broker already uploaded to <org>/portal/<proposal>/ (while the proposal waits for validation).
create or replace function private.can_upload_submission_document(p_org text, p_proposal text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
    select 1 from public.proposal_submissions s
    where s.organization_id::text = p_org and s.proposal_id::text = p_proposal
      and s.submitted_by = auth.uid() and s.status = 'pending'
      and public.is_active_organization_member(s.organization_id))
$$;

revoke all on function private.can_upload_submission_document(text, text) from public, anon;
grant execute on function private.can_upload_submission_document(text, text) to authenticated;

create or replace function public.record_submission_document(p_proposal uuid, p_label text, p_path text, p_file_name text, p_mime text, p_size integer, p_sha256 text)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare s public.proposal_submissions%rowtype; v_id uuid;
begin
  select * into s from public.proposal_submissions where proposal_id = p_proposal;
  if s.proposal_id is null or auth.uid() is null or not private.can_upload_submission_document(s.organization_id::text, s.proposal_id::text) then
    raise exception 'not_authorized';
  end if;
  if p_path is null or left(p_path, length(s.organization_id::text || '/portal/' || s.proposal_id::text || '/')) <> s.organization_id::text || '/portal/' || s.proposal_id::text || '/'
     or p_path like '%..%' then
    raise exception 'invalid_document_path';
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'corban-documents' and o.name = p_path and o.owner_id = auth.uid()::text) then
    raise exception 'document_not_uploaded';
  end if;
  perform set_config('corban.submission_rpc', 'on', true);
  insert into public.proposal_submission_documents (organization_id, proposal_id, label, storage_path, original_file_name, mime_type, file_size_bytes, sha256, uploaded_by)
  values (s.organization_id, s.proposal_id, btrim(p_label), p_path, p_file_name, p_mime, p_size, p_sha256, auth.uid())
  returning id into v_id;
  perform set_config('corban.submission_rpc', 'off', true);
  return v_id;
end
$$;

-- Validation by the team: never by the sender; needs esteira.edit and sight of the proposal.
create or replace function public.decide_broker_proposal(p_proposal uuid, p_approve boolean, p_reason text default null)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  s public.proposal_submissions%rowtype;
  p public.proposals_v2%rowtype;
  v_state text;
  v_stage uuid; v_sla integer;
begin
  select * into s from public.proposal_submissions where proposal_id = p_proposal for update;
  if s.proposal_id is null then raise exception 'submission_not_found'; end if;
  select * into p from public.proposals_v2 where id = p_proposal for update;
  if auth.uid() is null or not public.is_active_organization_member(p.organization_id) or not public.has_permission(p.organization_id, 'esteira.edit')
     or not private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by) then
    raise exception 'not_authorized';
  end if;
  if s.status <> 'pending' then raise exception 'submission_already_decided'; end if;
  if s.submitted_by = auth.uid() then raise exception 'four_eyes_required'; end if;

  if p_approve then
    -- What the broker typed now reaches the client record (new contacts become the main ones; old ones stay in history).
    perform private.upsert_client_core(p.organization_id, p.customer_snapshot->>'cpf', p.customer_snapshot->>'full_name',
                                        p.customer_snapshot->>'phone', p.customer_snapshot->>'email', 'portal', null);
    v_state := case when p.status = 'submitted' then 'submitted' else 'digitization_queue' end;
    select st.id, st.sla_minutes into v_stage, v_sla from public.operational_stages st
    where st.organization_id = p.organization_id and st.canonical_state = v_state and st.is_active order by st.sort_order limit 1;
    if v_stage is null then raise exception 'target_operational_stage_not_configured'; end if;
    perform set_config('corban.operational_rpc', 'on', true);
    insert into public.operational_cases (organization_id, proposal_id, current_stage_id, canonical_state, owner_user_id, entered_stage_at, due_at)
    values (p.organization_id, p.id, v_stage, v_state, auth.uid(), now(), case when v_sla is null then null else now() + make_interval(mins => v_sla) end);
    perform set_config('corban.operational_rpc', 'off', true);
    perform set_config('corban.submission_rpc', 'on', true);
    update public.proposal_submissions set status = 'validated', decided_by = auth.uid(), decided_at = now(), decision_reason = nullif(left(btrim(coalesce(p_reason, '')), 300), '')
    where proposal_id = p.id;
  else
    if p_reason is null or length(btrim(p_reason)) < 3 then raise exception 'reason_required'; end if;
    perform set_config('corban.proposal_rpc', 'on', true);
    update public.proposals_v2 set status = 'cancelled', updated_at = now() where id = p.id;
    perform set_config('corban.proposal_rpc', 'off', true);
    perform set_config('corban.submission_rpc', 'on', true);
    update public.proposal_submissions set status = 'rejected', decided_by = auth.uid(), decided_at = now(), decision_reason = left(btrim(p_reason), 300)
    where proposal_id = p.id;
  end if;
  perform set_config('corban.submission_rpc', 'off', true);
end
$$;

-- The validation queue for the team. client_preexisted: the client belongs to someone other than the sender (the
-- "client already exists, portfolio of X" warning, never shown to the broker).
create or replace function public.broker_submission_queue(p_org uuid)
returns table (proposal_id uuid, created_at timestamptz, seller_name text, client_name text, client_cpf text, bank text, table_name text,
               requested_amount numeric, released_amount numeric, term integer, ade text, client_preexisted boolean, client_owner_name text, documents integer)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or not public.is_active_organization_member(p_org) or not public.has_permission(p_org, 'esteira.edit') then
    raise exception 'not_authorized';
  end if;
  return query
  select p.id, s.created_at, se.name, p.customer_snapshot->>'full_name', p.customer_snapshot->>'cpf',
         p.commercial_snapshot->>'bank', p.commercial_snapshot->>'table', p.requested_amount, p.released_amount, p.term, p.external_proposal_id,
         c.owner_user_id is distinct from s.submitted_by,
         case when c.owner_user_id is distinct from s.submitted_by then
           coalesce((select so.name from public.commercial_sellers so where so.organization_id = p_org and so.user_id = c.owner_user_id limit 1),
                    (select u.email::text from auth.users u where u.id = c.owner_user_id), 'sem responsável')
         end,
         (select count(*)::int from public.proposal_submission_documents d where d.proposal_id = p.id)
  from public.proposal_submissions s
  join public.proposals_v2 p on p.id = s.proposal_id
  join public.commercial_sellers se on se.id = s.seller_id
  join public.clients c on c.id = p.customer_id
  where s.organization_id = p_org and s.status = 'pending'
    and private.can_see_proposal_row(p_org, p.seller_id, p.created_by)
  order by s.created_at;
end
$$;

-- Portal access: an invitation for a registered seller that already carries the portal role.
alter table public.organization_invitations add column access_role_id uuid;
alter table public.organization_invitations add constraint organization_invitations_access_role_fk
  foreign key (organization_id, access_role_id) references public.organization_roles (organization_id, id) on delete restrict;

create or replace function public.invite_seller_to_portal(p_seller uuid, p_email text)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare s public.commercial_sellers%rowtype; v_actor text; v_role uuid; v_inv uuid;
begin
  select * into s from public.commercial_sellers where id = p_seller;
  if s.id is null or auth.uid() is null then raise exception 'not_authorized'; end if;
  v_actor := private.caller_role_in(s.organization_id);
  if v_actor is null or v_actor not in ('admin','manager') then raise exception 'not_authorized'; end if;
  if not s.is_active then raise exception 'seller_not_found'; end if;
  if s.user_id is not null then raise exception 'seller_already_has_access'; end if;
  select r.id into v_role from public.organization_roles r
  where r.organization_id = s.organization_id and r.key = 'corretor' and r.is_active and r.tier = 'agent';
  if v_role is null then raise exception 'portal_role_missing'; end if;
  v_inv := public.create_organization_invitation(s.organization_id, p_email, 'agent');
  perform set_config('corban.membership_rpc', 'on', true);
  -- create_organization_invitation already wrote the 'invite_created' event; acceptance records the access role.
  update public.organization_invitations set seller_id = s.id, access_role_id = v_role where id = v_inv;
  perform set_config('corban.membership_rpc', 'off', true);
  return v_inv;
end
$$;

CREATE OR REPLACE FUNCTION public.accept_organization_invitations(p_user_id uuid, p_email text)
 RETURNS TABLE(organization_id uuid, role text, outcome text)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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

    -- An invitation with an access role (portal) sets that role; otherwise the tier's default role applies.
    if not found then
      insert into public.organization_memberships(organization_id,user_id,role,role_id,status)
      values(i.organization_id,p_user_id,i.role,i.access_role_id,'active');
      v_out:='joined';
    elsif m.status='active' then
      v_out:='already_member';
    else
      update public.organization_memberships
      set role=i.role,role_id=coalesce(i.access_role_id,role_id),status='active',updated_at=now()
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
        'seller_id',i.seller_id,
        'access_role_id',i.access_role_id
      )
    );

    organization_id:=i.organization_id;
    role:=i.role;
    outcome:=v_out;
    return next;
  end loop;

  perform set_config('corban.membership_rpc','off',true);
end
$function$;

-- Storage: portal documents -----------------------------------------------------------------------------------------------

create policy corban_documents_portal_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'corban-documents'
              and owner_id = (select auth.uid()::text)
              and (storage.foldername(name))[2] = 'portal'
              and private.can_upload_submission_document((storage.foldername(name))[1], (storage.foldername(name))[3]));

create policy corban_documents_portal_select on storage.objects for select to authenticated
  using (bucket_id = 'corban-documents'
         and (storage.foldername(name))[2] = 'portal'
         and exists (select 1 from public.proposals_v2 p
                     where p.organization_id::text = (storage.foldername(name))[1] and p.id::text = (storage.foldername(name))[3]));

-- Grants -------------------------------------------------------------------------------------------------------------------

revoke all on function public.submit_broker_proposal(uuid, text, text, text, text, uuid, numeric, numeric, numeric, integer, text) from public, anon;
revoke all on function public.record_submission_document(uuid, text, text, text, text, integer, text) from public, anon;
revoke all on function public.decide_broker_proposal(uuid, boolean, text) from public, anon;
revoke all on function public.broker_submission_queue(uuid) from public, anon;
revoke all on function public.invite_seller_to_portal(uuid, text) from public, anon;
grant execute on function public.submit_broker_proposal(uuid, text, text, text, text, uuid, numeric, numeric, numeric, integer, text) to authenticated;
grant execute on function public.record_submission_document(uuid, text, text, text, text, integer, text) to authenticated;
grant execute on function public.decide_broker_proposal(uuid, boolean, text) to authenticated;
grant execute on function public.broker_submission_queue(uuid) to authenticated;
grant execute on function public.invite_seller_to_portal(uuid, text) to authenticated;
