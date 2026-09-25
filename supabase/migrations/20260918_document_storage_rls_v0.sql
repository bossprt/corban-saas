-- CORBAN OS V2 — Document Storage RLS V0
-- PREPARED ONLY. Human Gate required before applying live.
-- Object convention: <organization_id>/<customer_id>/<opaque-uuid>/<filename>
-- Private evidence: authenticated SELECT/INSERT only; no authenticated UPDATE/DELETE/upsert.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'corban-documents',
  'corban-documents',
  false,
  15728640,
  array['application/pdf','image/jpeg','image/png','image/webp']
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists corban_documents_select_tenant_member on storage.objects;
create policy corban_documents_select_tenant_member
on storage.objects
for select
to authenticated
using (
  bucket_id = 'corban-documents'
  and exists (
    select 1
    from public.organization_memberships m
    where m.user_id = (select auth.uid())
      and m.status = 'active'
      and m.organization_id::text = (storage.foldername(name))[1]
  )
  and exists (
    select 1
    from public.clients c
    where c.organization_id::text = (storage.foldername(name))[1]
      and c.id::text = (storage.foldername(name))[2]
      and c.deleted_at is null
  )
);

drop policy if exists corban_documents_insert_tenant_member on storage.objects;
create policy corban_documents_insert_tenant_member
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'corban-documents'
  and owner_id = (select auth.uid()::text)
  and exists (
    select 1
    from public.organization_memberships m
    where m.user_id = (select auth.uid())
      and m.status = 'active'
      and m.organization_id::text = (storage.foldername(name))[1]
  )
  and exists (
    select 1
    from public.clients c
    where c.organization_id::text = (storage.foldername(name))[1]
      and c.id::text = (storage.foldername(name))[2]
      and c.deleted_at is null
  )
);

-- Intentionally no authenticated UPDATE/DELETE policies:
-- evidence is versioned in customer_documents; replacement creates a new object/version.
