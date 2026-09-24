-- Storage setup of production (bucket and object policies), exported on 2026-09-24 from project nhjfrcttzxnphhizlnmc.
-- The schema baseline covers only public and private, so a local database rebuilt from it has no document bucket;
-- load this file right after the baseline. Idempotent.
--
-- Documents live under <organization_id>/<client_id>/...; a member reads and uploads only inside their own
-- organization and only for an existing client. There is no UPDATE or DELETE policy: evidence is never overwritten.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('corban-documents', 'corban-documents', false, 15728640, array['application/pdf','image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

drop policy if exists corban_documents_select_tenant_member on storage.objects;
create policy corban_documents_select_tenant_member on storage.objects for select to authenticated
  using (bucket_id = 'corban-documents'
         and exists (select 1 from public.organization_memberships m
                     where m.user_id = (select auth.uid()) and m.status = 'active' and m.organization_id::text = (storage.foldername(objects.name))[1])
         and exists (select 1 from public.clients c
                     where c.organization_id::text = (storage.foldername(objects.name))[1] and c.id::text = (storage.foldername(objects.name))[2] and c.deleted_at is null));

drop policy if exists corban_documents_insert_tenant_member on storage.objects;
create policy corban_documents_insert_tenant_member on storage.objects for insert to authenticated
  with check (bucket_id = 'corban-documents'
              and owner_id = (select auth.uid()::text)
              and exists (select 1 from public.organization_memberships m
                          where m.user_id = (select auth.uid()) and m.status = 'active' and m.organization_id::text = (storage.foldername(objects.name))[1])
              and exists (select 1 from public.clients c
                          where c.organization_id::text = (storage.foldername(objects.name))[1] and c.id::text = (storage.foldername(objects.name))[2] and c.deleted_at is null));
