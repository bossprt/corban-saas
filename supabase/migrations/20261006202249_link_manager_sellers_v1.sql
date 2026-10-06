-- Smart Promotora: GERDEAN FERREIRA NASCIMENTO (Gerente) and FRANCISCO JUNIOR DA SILVA BRAGA (Administrador) each have a
-- team login and a seller record with the same e-mail (owner request 06/10/2026). Each seller record is linked to the
-- login whose e-mail is the seller's e-mail, through public.set_seller_user, as the company's first administrator.
-- Roles do not change. Only a seller without a link and a member not linked yet; elsewhere it does nothing.

do $$
declare
  v_org uuid;
  v_admin uuid;
  r record;
  v_done int := 0;
begin
  select o.id into v_org from public.organizations o where o.name = 'Smart Promotora Ltda.';
  if v_org is null then raise notice 'link sellers: company not here'; return; end if;
  select m.user_id into v_admin from public.organization_memberships m
  where m.organization_id = v_org and m.role = 'admin' and m.status = 'active' order by m.created_at limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  for r in
    select s.id as seller_id, m.user_id
    from public.commercial_sellers s
    join public.seller_profiles sp on sp.seller_id = s.id
    join auth.users u on lower(u.email) = lower(sp.email)
    join public.organization_memberships m on m.organization_id = s.organization_id and m.user_id = u.id and m.status = 'active'
    where s.organization_id = v_org and s.user_id is null and s.is_active
      and s.name in ('GERDEAN FERREIRA NASCIMENTO', 'FRANCISCO JUNIOR DA SILVA BRAGA')
      and not exists (select 1 from public.commercial_sellers x where x.organization_id = v_org and x.user_id = m.user_id)
  loop
    perform public.set_seller_user(r.seller_id, r.user_id);
    v_done := v_done + 1;
  end loop;
  perform set_config('request.jwt.claims', '', true);
  raise notice 'link sellers: % linked', v_done;
end
$$;
