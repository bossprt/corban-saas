do $$
declare
  def text;
begin
  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='guard_component_payout_group_limit';

  if def is null then raise exception 'component_limit_guard_missing'; end if;
  if position('if new.mode=''exclude'' then' in lower(def))=0 then
    raise exception 'exclude_is_not_unconditionally_allowed';
  end if;
  if position('new.share_pct>v_limit' in lower(def))=0 then
    raise exception 'positive_share_ceiling_missing';
  end if;
end $$;