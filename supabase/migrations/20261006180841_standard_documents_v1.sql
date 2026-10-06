-- Standard documents for every bank (owner request 06/10/2026): Contracheque, RG ou CNH, Comprovante de endereço,
-- Extrato bancário, Selfie, Extrato de consignação and Outros. None is required: each company owner decides, bank by
-- bank, in Cadastros > Documentos por banco, which ones become required. Each document takes more than one file.
--   * two document types the catalog lacked: "RG ou CNH" and "Extrato de consignação" (global catalog, like the others);
--   * Smart Promotora: the list is published for every active bank/convênio route that has no list yet, through
--     public.save_route_checklist, as the company's first administrator. Contracts already created keep theirs.

insert into public.document_types (code, name, is_active)
values ('rg_ou_cnh', 'RG ou CNH', true), ('extrato_consignacao', 'Extrato de consignação', true)
on conflict (code) do nothing;

do $$
declare
  v_org uuid;
  v_admin uuid;
  v_routes uuid[];
  v_items jsonb;
begin
  select o.id into v_org from public.organizations o where o.name = 'Smart Promotora Ltda.';
  if v_org is null then raise notice 'standard documents: company not here, nothing to do'; return; end if;
  select array_agg(r.id) into v_routes from public.organization_product_routes r
  where r.organization_id = v_org and r.status = 'active'
    and not exists (select 1 from public.document_checklist_templates t where t.route_id = r.id and t.status = 'published');
  if v_routes is null then raise notice 'standard documents: every route already has a list'; return; end if;
  select m.user_id into v_admin from public.organization_memberships m
  where m.organization_id = v_org and m.role = 'admin' and m.status = 'active' order by m.created_at limit 1;
  select jsonb_agg(jsonb_build_object('document_type_id', d.id, 'label', x.label, 'required', false) order by x.pos)
  into v_items
  from (values (1, 'contracheque', 'Contracheque'), (2, 'rg_ou_cnh', 'RG ou CNH'), (3, 'comprovante_residencia', 'Comprovante de endereço'),
               (4, 'extrato_bancario', 'Extrato bancário'), (5, 'selfie', 'Selfie'), (6, 'extrato_consignacao', 'Extrato de consignação'),
               (7, 'outro', 'Outros')) as x(pos, code, label)
  join public.document_types d on d.code = x.code and d.is_active;
  if jsonb_array_length(v_items) <> 7 then raise exception 'standard_documents_missing_type'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  perform public.save_route_checklist(v_org, v_routes, v_items);
  perform set_config('request.jwt.claims', '', true);
end
$$;
