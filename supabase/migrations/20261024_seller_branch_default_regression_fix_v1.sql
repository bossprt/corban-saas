-- CORBAN OS — Seller branch default regression fix V1
-- Same authorized seller operations identity wave.

create or replace function public.guard_seller_catalog_row()
returns trigger
language plpgsql
set search_path=''
as $$
declare
  v_matrix uuid;
begin
  if tg_op='INSERT' then
    if tg_table_name='commercial_sellers'
       and (to_jsonb(new)->>'branch_id') is null then
      select b.id into v_matrix
      from public.organization_branches b
      where b.organization_id=new.organization_id
        and b.branch_type='matrix'
        and b.is_active
      limit 1;
      if v_matrix is null then raise exception 'active_matrix_required'; end if;
      new.branch_id:=v_matrix;
    end if;

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
