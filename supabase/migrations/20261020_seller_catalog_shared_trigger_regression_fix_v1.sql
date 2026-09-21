-- CORBAN OS — Seller catalog shared trigger regression fix V1
-- Standing Owner authorization: same seller commission/access-governance wave.
-- guard_seller_catalog_row is shared by seller_groups and commercial_sellers.
-- Never dereference NEW.user_id directly on seller_groups because that column does not exist.

create or replace function public.guard_seller_catalog_row()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if tg_op='INSERT' then
    if current_user in ('authenticated','anon') then
      new.created_by:=auth.uid();

      if tg_table_name='commercial_sellers'
         and nullif(to_jsonb(new)->>'user_id','') is not null
         and current_setting('corban.seller_access_rpc',true) is distinct from 'on' then
        raise exception 'seller_user_binding_requires_governed_rpc';
      end if;
    end if;
  else
    if new.id is distinct from old.id
       or new.organization_id is distinct from old.organization_id
       or new.tech_key is distinct from old.tech_key
       or new.created_at is distinct from old.created_at
       or new.created_by is distinct from old.created_by
    then raise exception 'seller_identity_is_immutable'; end if;

    if tg_table_name='commercial_sellers'
       and (to_jsonb(new)->>'user_id') is distinct from (to_jsonb(old)->>'user_id')
       and current_user in ('authenticated','anon')
       and current_setting('corban.seller_access_rpc',true) is distinct from 'on' then
      raise exception 'seller_user_binding_requires_governed_rpc';
    end if;

    new.updated_at:=now();
  end if;
  return new;
end
$$;

revoke all on function public.guard_seller_catalog_row() from public,anon,authenticated;
