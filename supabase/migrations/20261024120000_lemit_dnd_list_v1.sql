-- Lemit "Não Perturbe SP" list (owner, 24/10/2026). Lemit publishes the São Paulo "Não Perturbe" register as one file
-- of ~16 million phones (phone; created_at; valid_at). The owner chose to keep only the area codes where the company
-- sells (DDD 68: ~21 thousand phones), filtered in the browser before anything is sent. Importing again replaces the
-- previous Lemit list; phones marked by hand or from bank lists are never touched. A phone counts from its validity date.

alter table public.do_not_disturb_phones
  add column valid_from date,
  add column lemit_batch uuid;
create index do_not_disturb_phones_lemit_batch_idx on public.do_not_disturb_phones (organization_id, lemit_batch) where lemit_batch is not null;

-- On the list today: active and already valid (a phone with a future validity date is not counted yet).
create or replace function private.phone_is_dnd(p_org uuid, p_phone text)
returns boolean language sql stable security definer set search_path = '' set timezone to 'America/Sao_Paulo' as $$
  select p_phone is not null and exists (select 1 from public.do_not_disturb_phones d
                                         where d.organization_id = p_org and d.phone = private.normalize_phone(p_phone) and d.removed_at is null
                                           and (d.valid_from is null or d.valid_from <= current_date))
$$;
revoke all on function private.phone_is_dnd(uuid, text) from public, anon;
grant execute on function private.phone_is_dnd(uuid, text) to authenticated;

create or replace function public.dnd_phones_in(p_org uuid, p_phones text[])
returns setof text language sql stable security definer set search_path = '' set timezone to 'America/Sao_Paulo' as $$
  select d.phone from public.do_not_disturb_phones d
  where (select auth.uid()) is not null and public.has_permission(p_org, 'leads.view')
    and d.organization_id = p_org and d.removed_at is null and (d.valid_from is null or d.valid_from <= current_date)
    and d.phone in (select private.normalize_phone(x) from unnest(coalesce(p_phones, '{}')) x)
$$;

-- One chunk of the Lemit list (administrator). Rows: [{"phone": "68999990000", "valid_from": "2026-11-01"}].
-- A phone already on the list by hand or from a bank stays as it is; a phone of an earlier Lemit list joins this batch.
create or replace function public.import_lemit_dnd_chunk(p_org uuid, p_batch uuid, p_file_name text, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_total int := jsonb_array_length(coalesce(p_rows, '[]'::jsonb)); v_valid int; v_written int;
begin
  if v_user is null or not public.has_active_organization_role(p_org, array['admin']) then raise exception 'not_authorized'; end if;
  if p_batch is null or jsonb_typeof(coalesce(p_rows, '[]'::jsonb)) <> 'array' or v_total > 10000 then raise exception 'invalid_rows'; end if;
  with src as (
    select distinct on (private.normalize_phone(r->>'phone')) private.normalize_phone(r->>'phone') as phone,
           case when (r->>'valid_from') ~ '^\d{4}-\d{2}-\d{2}$' then (r->>'valid_from')::date end as valid_from
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r
    where private.normalize_phone(r->>'phone') is not null
    order by private.normalize_phone(r->>'phone'), (r->>'valid_from')
  ),
  w as (
    insert into public.do_not_disturb_phones (organization_id, phone, source, valid_from, lemit_batch, file_name, created_by)
    select p_org, s.phone, 'lemit', s.valid_from, p_batch, nullif(left(btrim(coalesce(p_file_name, '')), 255), ''), v_user from src s
    on conflict (organization_id, phone) where removed_at is null do update
      set valid_from = excluded.valid_from, lemit_batch = excluded.lemit_batch, file_name = excluded.file_name
      where public.do_not_disturb_phones.source = 'lemit'
    returning 1
  )
  select (select count(*) from src), (select count(*) from w) into v_valid, v_written;
  return jsonb_build_object('received', v_total, 'valid', v_valid, 'written', v_written);
end $$;

-- End of an import: the Lemit phones not in this batch leave the list (reference data, replaced by the new file).
create or replace function public.finish_lemit_dnd_import(p_org uuid, p_batch uuid)
returns jsonb language plpgsql security definer set search_path = '' set timezone to 'America/Sao_Paulo' as $$
declare v_user uuid := auth.uid(); v_removed int; v_total int; v_valid_now int;
begin
  if v_user is null or not public.has_active_organization_role(p_org, array['admin']) then raise exception 'not_authorized'; end if;
  if not exists (select 1 from public.do_not_disturb_phones where organization_id = p_org and lemit_batch = p_batch) then raise exception 'empty_batch'; end if;
  delete from public.do_not_disturb_phones
  where organization_id = p_org and source = 'lemit' and removed_at is null and lemit_batch is distinct from p_batch;
  get diagnostics v_removed = row_count;
  select count(*), count(*) filter (where valid_from is null or valid_from <= current_date) into v_total, v_valid_now
  from public.do_not_disturb_phones where organization_id = p_org and lemit_batch = p_batch;
  return jsonb_build_object('total', v_total, 'valid_now', v_valid_now, 'removed', v_removed);
end $$;

revoke all on function public.import_lemit_dnd_chunk(uuid, uuid, text, jsonb), public.finish_lemit_dnd_import(uuid, uuid) from public, anon;
grant execute on function public.import_lemit_dnd_chunk(uuid, uuid, text, jsonb), public.finish_lemit_dnd_import(uuid, uuid) to authenticated;
