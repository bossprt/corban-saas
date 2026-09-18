-- CORBAN OS V2 — Document Vault / Checklist V0
-- Prepared only. Depends on Customer 360 + Product Catalog + Proposal V0.

create table if not exists public.document_types (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Physical/logical customer document record. Storage object path is opaque; bucket rules are separate.
create table if not exists public.customer_documents (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  customer_id uuid not null,
  document_type_id uuid not null references public.document_types(id) on delete restrict,
  version integer not null default 1,
  storage_bucket text not null,
  storage_path text not null,
  original_file_name text not null,
  mime_type text,
  file_size_bytes bigint,
  sha256 text not null,
  status text not null default 'active',
  issued_at date,
  expires_at date,
  uploaded_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint customer_documents_customer_tenant_fk foreign key (organization_id, customer_id)
    references public.clients (organization_id, id) on delete restrict,
  constraint customer_documents_version_check check (version > 0),
  constraint customer_documents_size_check check (file_size_bytes is null or file_size_bytes >= 0),
  constraint customer_documents_status_check check (status in ('active','superseded','invalid')),
  constraint customer_documents_path_key unique (organization_id, storage_bucket, storage_path),
  constraint customer_documents_customer_hash_key unique (organization_id, customer_id, sha256)
);

create unique index if not exists customer_documents_org_id_key on public.customer_documents (organization_id, id);
create index if not exists customer_documents_org_customer_idx on public.customer_documents (organization_id, customer_id, created_at desc);

-- Versioned checklist template by exact tenant route. A proposal snapshots requirements through links below.
create table if not exists public.document_checklist_templates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  route_id uuid not null,
  version integer not null,
  status text not null default 'draft',
  name text not null,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  constraint document_checklist_templates_status_check check (status in ('draft','published','superseded')),
  constraint document_checklist_templates_version_check check (version > 0),
  constraint document_checklist_templates_route_tenant_fk foreign key (organization_id, route_id)
    references public.organization_product_routes (organization_id, id) on delete restrict,
  constraint document_checklist_templates_route_version_key unique (route_id, version)
);

create unique index if not exists document_checklist_templates_org_id_key on public.document_checklist_templates (organization_id, id);

create table if not exists public.document_checklist_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  template_id uuid not null,
  document_type_id uuid not null references public.document_types(id) on delete restrict,
  label text not null,
  is_required boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  constraint document_checklist_items_template_tenant_fk foreign key (organization_id, template_id)
    references public.document_checklist_templates (organization_id, id) on delete restrict,
  constraint document_checklist_items_sort_check check (sort_order >= 0),
  constraint document_checklist_items_type_key unique (template_id, document_type_id)
);

create unique index if not exists document_checklist_items_org_id_key on public.document_checklist_items (organization_id, id);

-- Proposal V0 owns the composite tenant identity used by child FKs.

-- Proposal requirement is immutable evidence of what was required at that moment.
create table if not exists public.proposal_document_requirements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  proposal_id uuid not null,
  checklist_item_id uuid,
  document_type_id uuid not null references public.document_types(id) on delete restrict,
  label_snapshot text not null,
  required_snapshot boolean not null,
  status text not null default 'missing',
  exception_reason text,
  exception_approved_by uuid references auth.users(id) on delete set null,
  exception_approved_at timestamptz,
  created_at timestamptz not null default now(),
  constraint proposal_document_requirements_proposal_tenant_fk foreign key (organization_id, proposal_id)
    references public.proposals_v2 (organization_id, id) on delete restrict,
  constraint proposal_document_requirements_item_tenant_fk foreign key (organization_id, checklist_item_id)
    references public.document_checklist_items (organization_id, id) on delete restrict,
  constraint proposal_document_requirements_status_check check (status in ('missing','attached','validated','rejected','waived')),
  constraint proposal_document_requirements_exception_check check (
    (status <> 'waived') or (exception_reason is not null and exception_approved_by is not null and exception_approved_at is not null)
  ),
  constraint proposal_document_requirements_exception_scope_check check (
    status = 'waived' or (exception_reason is null and exception_approved_by is null and exception_approved_at is null)
  )
);

create unique index if not exists proposal_document_requirements_org_id_key on public.proposal_document_requirements (organization_id, id);
create index if not exists proposal_document_requirements_proposal_status_idx on public.proposal_document_requirements (organization_id, proposal_id, status);

create table if not exists public.proposal_document_links (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  requirement_id uuid not null,
  customer_document_id uuid not null,
  linked_by uuid references auth.users(id) on delete set null,
  linked_at timestamptz not null default now(),
  constraint proposal_document_links_requirement_tenant_fk foreign key (organization_id, requirement_id)
    references public.proposal_document_requirements (organization_id, id) on delete restrict,
  constraint proposal_document_links_document_tenant_fk foreign key (organization_id, customer_document_id)
    references public.customer_documents (organization_id, id) on delete restrict,
  constraint proposal_document_links_unique unique (requirement_id, customer_document_id)
);

-- RLS tenant tables
alter table public.customer_documents enable row level security;
alter table public.document_checklist_templates enable row level security;
alter table public.document_checklist_items enable row level security;
alter table public.proposal_document_requirements enable row level security;
alter table public.proposal_document_links enable row level security;

revoke all on table public.document_types from anon, authenticated;
grant select on table public.document_types to authenticated;

revoke all on table public.customer_documents, public.document_checklist_templates, public.document_checklist_items, public.proposal_document_requirements, public.proposal_document_links from anon;
grant select, insert, update on table public.customer_documents, public.document_checklist_templates, public.document_checklist_items, public.proposal_document_requirements to authenticated;
grant select, insert on table public.proposal_document_links to authenticated;

create policy customer_documents_select_member on public.customer_documents for select to authenticated using (public.is_active_organization_member(organization_id));
create policy customer_documents_insert_member on public.customer_documents for insert to authenticated with check (public.is_active_organization_member(organization_id));
create policy customer_documents_update_member on public.customer_documents for update to authenticated using (public.is_active_organization_member(organization_id)) with check (public.is_active_organization_member(organization_id));

create policy document_checklist_templates_select_member on public.document_checklist_templates for select to authenticated using (public.is_active_organization_member(organization_id));
create policy document_checklist_templates_insert_member on public.document_checklist_templates for insert to authenticated with check (public.is_active_organization_member(organization_id));
create policy document_checklist_templates_update_draft_member on public.document_checklist_templates for update to authenticated using (public.is_active_organization_member(organization_id) and status='draft') with check (public.is_active_organization_member(organization_id) and status='draft');

create policy document_checklist_items_select_member on public.document_checklist_items for select to authenticated using (public.is_active_organization_member(organization_id));
create policy document_checklist_items_insert_draft_member on public.document_checklist_items for insert to authenticated
  with check (
    public.is_active_organization_member(organization_id)
    and exists (
      select 1 from public.document_checklist_templates t
      where t.organization_id=document_checklist_items.organization_id
        and t.id=document_checklist_items.template_id
        and t.status='draft'
    )
  );
create policy document_checklist_items_update_draft_member on public.document_checklist_items for update to authenticated
  using (
    public.is_active_organization_member(organization_id)
    and exists (
      select 1 from public.document_checklist_templates t
      where t.organization_id=document_checklist_items.organization_id
        and t.id=document_checklist_items.template_id
        and t.status='draft'
    )
  )
  with check (
    public.is_active_organization_member(organization_id)
    and exists (
      select 1 from public.document_checklist_templates t
      where t.organization_id=document_checklist_items.organization_id
        and t.id=document_checklist_items.template_id
        and t.status='draft'
    )
  );

create policy proposal_document_requirements_select_member on public.proposal_document_requirements for select to authenticated using (public.is_active_organization_member(organization_id));
create policy proposal_document_requirements_insert_member on public.proposal_document_requirements for insert to authenticated with check (public.is_active_organization_member(organization_id));
create policy proposal_document_requirements_update_member on public.proposal_document_requirements for update to authenticated using (public.is_active_organization_member(organization_id)) with check (public.is_active_organization_member(organization_id));

-- Snapshot identity/evidence cannot be rewritten after creation; only workflow fields may change.
create or replace function public.guard_proposal_document_requirement_snapshot()
returns trigger
language plpgsql
set search_path = ''
as $function$
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
$function$;

drop trigger if exists proposal_document_requirements_snapshot_guard on public.proposal_document_requirements;
create trigger proposal_document_requirements_snapshot_guard
before update on public.proposal_document_requirements
for each row execute function public.guard_proposal_document_requirement_snapshot();

revoke all on function public.guard_proposal_document_requirement_snapshot() from public, anon, authenticated;

create policy proposal_document_links_select_member on public.proposal_document_links for select to authenticated using (public.is_active_organization_member(organization_id));
create policy proposal_document_links_insert_member on public.proposal_document_links for insert to authenticated with check (public.is_active_organization_member(organization_id));

-- Explicit service maintenance grants.
grant select, insert, update, delete on table public.document_types, public.customer_documents,
  public.document_checklist_templates, public.document_checklist_items,
  public.proposal_document_requirements, public.proposal_document_links to service_role;

-- No authenticated DELETE. Storage object policies and tighter proposal-requirement
-- transition guards remain required before production.
