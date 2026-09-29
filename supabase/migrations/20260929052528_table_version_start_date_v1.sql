-- Start date of a vigência chosen when publishing (owner request 29/09/2026).
--
-- Until now a table published from the screen always started on the day of publication, because a draft had no start
-- date field. This overload takes the day the vigência starts (midnight in Brasília), writes it on the draft and
-- publishes it through public.publish_product_table_version in the same call, so every rule of publication still
-- applies: only admin or manager, only a draft, lines or rate required, earlier versions closed at the new start,
-- refused when a published version already starts later. The one-argument form keeps starting today.

create or replace function public.publish_product_table_version(p_version_id uuid, p_effective_from date)
returns uuid
language plpgsql
set search_path to ''
as $$
declare
  v public.product_table_versions%rowtype;
begin
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if p_effective_from is null then raise exception 'effective_from_required'; end if;
  -- A typo such as 2062 or 1926 would silently move the whole history; keep the date near today.
  if p_effective_from < date '2000-01-01' or p_effective_from > (now() at time zone 'America/Sao_Paulo')::date + 366 then
    raise exception 'effective_from_out_of_range';
  end if;

  select * into v from public.product_table_versions x where x.id = p_version_id for update;
  if not found then raise exception 'version_not_found'; end if;
  if not public.has_active_organization_role(v.organization_id, array['admin', 'manager']) then raise exception 'not_authorized'; end if;
  if v.status <> 'draft' then raise exception 'version_not_draft'; end if;

  update public.product_table_versions
     set effective_from = p_effective_from::timestamp at time zone 'America/Sao_Paulo'
   where id = v.id;
  return public.publish_product_table_version(v.id);
end
$$;

revoke all on function public.publish_product_table_version(uuid, date) from public, anon;
grant execute on function public.publish_product_table_version(uuid, date) to authenticated;
