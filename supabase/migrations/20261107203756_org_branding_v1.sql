-- Company look (owner, 07/11/2026): each company chooses its primary color, accent color and logo.
-- Only an active admin of the company changes them (set_org_branding). Logos are public brand images in the
-- 'org-branding' bucket under <organization_id>/<uuid>.<ext>; raster only (no SVG), at most 1 MB.

alter table public.organizations
  add column if not exists brand_color text,
  add column if not exists accent_color text,
  add column if not exists logo_path text;

alter table public.organizations drop constraint if exists organizations_brand_color_hex;
alter table public.organizations add constraint organizations_brand_color_hex check (brand_color is null or brand_color ~ '^#[0-9a-f]{6}$');
alter table public.organizations drop constraint if exists organizations_accent_color_hex;
alter table public.organizations add constraint organizations_accent_color_hex check (accent_color is null or accent_color ~ '^#[0-9a-f]{6}$');
alter table public.organizations drop constraint if exists organizations_logo_path_own;
alter table public.organizations add constraint organizations_logo_path_own check (
  logo_path is null or logo_path ~ ('^' || id::text || '/[0-9a-f-]{36}\.(png|jpg|webp)$')
);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('org-branding', 'org-branding', true, 1048576, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do update
set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- Upload: only an active admin, only into the company's own folder. No UPDATE/DELETE: a new logo is a new file.
drop policy if exists org_branding_insert_admin on storage.objects;
create policy org_branding_insert_admin on storage.objects for insert to authenticated
with check (
  bucket_id = 'org-branding'
  and owner_id = (select auth.uid()::text)
  and name ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(png|jpg|webp)$'
  and exists (
    select 1 from public.organization_memberships m
    where m.user_id = (select auth.uid()) and m.status = 'active' and m.role = 'admin'
      and m.organization_id::text = (storage.foldername(name))[1]
  )
);

create or replace function public.set_org_branding(p_org uuid, p_brand text, p_accent text, p_logo text default null, p_remove_logo boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_brand text := lower(nullif(btrim(p_brand), ''));
  v_accent text := lower(nullif(btrim(p_accent), ''));
  v_logo text := nullif(btrim(p_logo), '');
begin
  if (select auth.uid()) is null or not exists (
    select 1 from public.organization_memberships m
    where m.organization_id = p_org and m.user_id = (select auth.uid()) and m.status = 'active' and m.role = 'admin'
  ) then
    raise exception 'org_branding_forbidden' using errcode = '42501';
  end if;
  if v_brand is not null and v_brand !~ '^#[0-9a-f]{6}$' then raise exception 'org_branding_invalid_color'; end if;
  if v_accent is not null and v_accent !~ '^#[0-9a-f]{6}$' then raise exception 'org_branding_invalid_color'; end if;
  if v_logo is not null and (
    v_logo !~ ('^' || p_org::text || '/[0-9a-f-]{36}\.(png|jpg|webp)$')
    or not exists (select 1 from storage.objects o where o.bucket_id = 'org-branding' and o.name = v_logo)
  ) then
    raise exception 'org_branding_invalid_logo';
  end if;

  update public.organizations
  set brand_color = v_brand,
      accent_color = v_accent,
      logo_path = case when p_remove_logo then null when v_logo is not null then v_logo else logo_path end
  where id = p_org;
end;
$$;

revoke all on function public.set_org_branding(uuid, text, text, text, boolean) from public, anon;
grant execute on function public.set_org_branding(uuid, text, text, text, boolean) to authenticated;
