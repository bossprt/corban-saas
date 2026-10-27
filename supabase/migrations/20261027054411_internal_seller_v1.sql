-- Internal seller (owner, 27/10/2026): a seller of the company itself, such as "TRAFEGO PAGO - SMART PROMOTORA", so a sales
-- channel shows apart in ranking and reports. It has no CPF/CNPJ of its own (the company's CNPJ already belongs to another
-- seller and documents never repeat), and mobile and e-mail are optional. Every other rule of save_seller is unchanged.

alter table public.commercial_sellers add column is_internal boolean not null default false;
comment on column public.commercial_sellers.is_internal is 'Seller of the company itself (a channel such as paid traffic): no CPF/CNPJ of its own; mobile and e-mail optional.';

create or replace function public.save_seller(p_org uuid, p_seller uuid, p_data jsonb)
 returns uuid
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_seller uuid;
  v_name text := btrim(coalesce(p_data->>'name', ''));
  v_tax text := regexp_replace(coalesce(p_data->>'tax_id', ''), '\D', '', 'g');
  v_cat text := p_data->>'category';
  v_internal boolean := coalesce((p_data->>'internal')::boolean, false);
  v_group uuid;
  v_branch uuid;
  p jsonb := coalesce(p_data->'profile', '{}'::jsonb);
  v_mobile text;
  v_whats text;
  v_email text := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
  a jsonb;
  c jsonb;
  v_acc public.seller_bank_accounts%rowtype;
  v_new public.seller_bank_accounts%rowtype;
  v_id uuid;
  v_primary uuid;
  v_key text;
  v_doc text;
  v_email_re constant text := '^[^\s@]+@[^\s@]+\.[^\s@]+$';
begin
  if auth.uid() is null or p_org is null or not public.has_active_organization_role(p_org, array['admin', 'manager']) then
    raise exception 'not_authorized';
  end if;

  -- Required: name, CPF/CNPJ, mobile, e-mail. An internal seller has no document of its own; mobile and e-mail optional.
  if length(v_name) not between 1 and 160 then raise exception 'seller_name_required'; end if;
  if v_internal then
    if v_tax <> '' then raise exception 'seller_internal_no_tax_id'; end if;
  elsif not ((length(v_tax) = 11 and private.is_valid_cpf(v_tax)) or (length(v_tax) = 14 and private.is_valid_cnpj(v_tax))) then
    raise exception 'seller_tax_id_invalid';
  end if;
  if coalesce(v_cat, '') not in ('pf', 'pj', 'sub') then raise exception 'seller_category_invalid'; end if;
  if nullif(btrim(coalesce(p->>'mobile', '')), '') is not null or not v_internal then
    v_mobile := private.normalize_phone(coalesce(p->>'mobile', ''));
    if v_mobile is null then raise exception 'seller_mobile_required'; end if;
  end if;
  if (v_email is null and not v_internal) or v_email !~ v_email_re then raise exception 'seller_email_required'; end if;
  if nullif(btrim(coalesce(p->>'whatsapp', '')), '') is not null then
    v_whats := private.normalize_phone(p->>'whatsapp');
    if v_whats is null then raise exception 'seller_phone_invalid'; end if;
  end if;
  begin
    v_group := (p_data->>'group_id')::uuid;
    v_branch := nullif(p_data->>'branch_id', '')::uuid;
  exception when others then
    raise exception 'seller_group_invalid';
  end;
  if v_group is null or not exists (select 1 from public.commission_groups g where g.id = v_group and g.organization_id = p_org and g.is_active) then
    raise exception 'seller_group_invalid';
  end if;
  if v_branch is not null and not exists (select 1 from public.organization_branches b where b.id = v_branch and b.organization_id = p_org and b.is_active) then
    raise exception 'seller_branch_invalid';
  end if;
  if v_tax <> '' and exists (select 1 from public.commercial_sellers s where s.organization_id = p_org and regexp_replace(s.tax_id, '[^0-9]', '', 'g') = v_tax and s.id is distinct from p_seller) then
    raise exception 'seller_tax_id_exists';
  end if;

  if p_seller is null then
    insert into public.commercial_sellers (organization_id, name, seller_category, tax_id, commission_group_id, branch_id, is_internal, created_by)
    values (p_org, v_name, v_cat, nullif(v_tax, ''), v_group, v_branch, v_internal, auth.uid())
    returning id into v_seller;
  else
    select s.id into v_seller from public.commercial_sellers s where s.id = p_seller and s.organization_id = p_org for update;
    if v_seller is null then raise exception 'seller_not_found'; end if;
    update public.commercial_sellers
    set name = v_name, seller_category = v_cat, tax_id = nullif(v_tax, ''), commission_group_id = v_group,
        branch_id = coalesce(v_branch, branch_id), is_internal = v_internal, updated_at = now()
    where id = v_seller;
  end if;
  -- Part C3: how often the seller is paid and whether they receive the deferred (month by month).
  if p_data ? 'payment_frequency' then
    if coalesce(p_data->>'payment_frequency', '') not in ('daily', 'weekly', 'biweekly', 'monthly') then raise exception 'seller_frequency_invalid'; end if;
    update public.commercial_sellers set commission_payment_frequency = p_data->>'payment_frequency' where id = v_seller;
  end if;
  if p_data ? 'receives_deferred' then
    update public.commercial_sellers set receives_deferred = coalesce((p_data->>'receives_deferred')::boolean, false) where id = v_seller;
  end if;

  perform set_config('corban.seller_profile_rpc', 'on', true);
  insert into public.seller_profiles (organization_id, seller_id, legal_name, trade_name, email, phone, whatsapp, other_phones,
    birth_or_opening_date, identity_or_registration_number, identity_issuer, rg_issued_on, mother_name, father_name,
    zip, street, number, complement, district, city, state,
    business_zip, business_street, business_number, business_complement, business_district, business_city, business_state,
    created_by, updated_by)
  values (p_org, v_seller, v_name, nullif(btrim(p->>'trade_name'), ''), v_email, v_mobile, v_whats, nullif(btrim(p->>'other_phones'), ''),
    nullif(p->>'birth_date', '')::date, nullif(btrim(p->>'rg'), ''), nullif(upper(btrim(p->>'rg_issuer')), ''), nullif(p->>'rg_issued_on', '')::date,
    nullif(btrim(p->>'mother_name'), ''), nullif(btrim(p->>'father_name'), ''),
    nullif(regexp_replace(coalesce(p->>'zip', ''), '\D', '', 'g'), ''), nullif(btrim(p->>'street'), ''), nullif(btrim(p->>'number'), ''),
    nullif(btrim(p->>'complement'), ''), nullif(btrim(p->>'district'), ''), nullif(btrim(p->>'city'), ''), nullif(upper(btrim(p->>'state')), ''),
    nullif(regexp_replace(coalesce(p->>'business_zip', ''), '\D', '', 'g'), ''), nullif(btrim(p->>'business_street'), ''), nullif(btrim(p->>'business_number'), ''),
    nullif(btrim(p->>'business_complement'), ''), nullif(btrim(p->>'business_district'), ''), nullif(btrim(p->>'business_city'), ''),
    nullif(upper(btrim(p->>'business_state')), ''),
    auth.uid(), auth.uid())
  on conflict (organization_id, seller_id) do update set
    legal_name = excluded.legal_name, trade_name = excluded.trade_name, email = excluded.email, phone = excluded.phone,
    whatsapp = excluded.whatsapp, other_phones = excluded.other_phones, birth_or_opening_date = excluded.birth_or_opening_date,
    identity_or_registration_number = excluded.identity_or_registration_number, identity_issuer = excluded.identity_issuer,
    rg_issued_on = excluded.rg_issued_on, mother_name = excluded.mother_name, father_name = excluded.father_name,
    zip = excluded.zip, street = excluded.street, number = excluded.number, complement = excluded.complement,
    district = excluded.district, city = excluded.city, state = excluded.state,
    business_zip = excluded.business_zip, business_street = excluded.business_street, business_number = excluded.business_number,
    business_complement = excluded.business_complement, business_district = excluded.business_district,
    business_city = excluded.business_city, business_state = excluded.business_state,
    updated_by = auth.uid(), updated_at = now();

  perform set_config('corban.seller_rpc', 'on', true);

  -- Bank accounts: existing rows are changed or removed (kept with removed_at); new rows are added. Every change is logged.
  if jsonb_typeof(coalesce(p_data->'accounts', '[]'::jsonb)) <> 'array' then raise exception 'seller_account_invalid'; end if;
  update public.seller_bank_accounts set is_primary = false, updated_at = now() where seller_id = v_seller and is_primary and removed_at is null;
  for a in select * from jsonb_array_elements(coalesce(p_data->'accounts', '[]'::jsonb)) loop
    v_id := nullif(a->>'id', '')::uuid;
    if v_id is not null then
      select * into v_acc from public.seller_bank_accounts x where x.id = v_id and x.seller_id = v_seller and x.removed_at is null;
      if v_acc.id is null then raise exception 'seller_account_not_found'; end if;
      if coalesce((a->>'remove')::boolean, false) then
        update public.seller_bank_accounts set removed_at = now(), removed_by = auth.uid(), is_primary = false, updated_at = now() where id = v_id;
        insert into public.seller_bank_account_events (organization_id, seller_id, account_id, action, before, actor)
        values (p_org, v_seller, v_id, 'removed', to_jsonb(v_acc) - 'is_primary' - 'updated_at', auth.uid());
        continue;
      end if;
    end if;

    v_key := nullif(btrim(coalesce(a->>'pix_key', '')), '');
    if a->>'transfer_method' = 'pix' then
      case a->>'pix_key_type'
        when 'cpf_cnpj' then
          v_key := regexp_replace(coalesce(v_key, ''), '\D', '', 'g');
          if not ((length(v_key) = 11 and private.is_valid_cpf(v_key)) or (length(v_key) = 14 and private.is_valid_cnpj(v_key))) then raise exception 'seller_pix_key_invalid'; end if;
        when 'phone' then
          v_key := private.normalize_phone(coalesce(v_key, ''));
          if v_key is null then raise exception 'seller_pix_key_invalid'; end if;
          v_key := '+' || v_key;
        when 'email' then
          v_key := lower(coalesce(v_key, ''));
          if v_key !~ v_email_re then raise exception 'seller_pix_key_invalid'; end if;
        when 'random' then
          v_key := lower(coalesce(v_key, ''));
          if v_key !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then raise exception 'seller_pix_key_invalid'; end if;
        else raise exception 'seller_pix_key_invalid';
      end case;
    elsif a->>'transfer_method' = 'ted' then
      v_key := null;
    else
      raise exception 'seller_account_invalid';
    end if;
    v_doc := nullif(regexp_replace(coalesce(a->>'holder_document', ''), '\D', '', 'g'), '');
    if v_doc is not null and not ((length(v_doc) = 11 and private.is_valid_cpf(v_doc)) or (length(v_doc) = 14 and private.is_valid_cnpj(v_doc))) then
      raise exception 'seller_holder_invalid';
    end if;

    begin
      if v_id is null then
        insert into public.seller_bank_accounts (organization_id, seller_id, transfer_method, account_type, bank_code, bank_name, branch,
          account_number, account_digit, pix_key_type, pix_key, holder_name, holder_document, note, created_by)
        values (p_org, v_seller, a->>'transfer_method', nullif(a->>'account_type', ''), nullif(btrim(a->>'bank_code'), ''), nullif(btrim(a->>'bank_name'), ''),
          nullif(btrim(a->>'branch'), ''), nullif(btrim(a->>'account_number'), ''), nullif(upper(btrim(a->>'account_digit')), ''),
          case when a->>'transfer_method' = 'pix' then a->>'pix_key_type' end, v_key,
          nullif(btrim(a->>'holder_name'), ''), v_doc, nullif(btrim(a->>'note'), ''), auth.uid())
        returning * into v_new;
        insert into public.seller_bank_account_events (organization_id, seller_id, account_id, action, after, actor)
        values (p_org, v_seller, v_new.id, 'added', to_jsonb(v_new) - 'is_primary' - 'updated_at', auth.uid());
      else
        update public.seller_bank_accounts set
          transfer_method = a->>'transfer_method', account_type = nullif(a->>'account_type', ''), bank_code = nullif(btrim(a->>'bank_code'), ''),
          bank_name = nullif(btrim(a->>'bank_name'), ''), branch = nullif(btrim(a->>'branch'), ''), account_number = nullif(btrim(a->>'account_number'), ''),
          account_digit = nullif(upper(btrim(a->>'account_digit')), ''), pix_key_type = case when a->>'transfer_method' = 'pix' then a->>'pix_key_type' end,
          pix_key = v_key, holder_name = nullif(btrim(a->>'holder_name'), ''), holder_document = v_doc, note = nullif(btrim(a->>'note'), ''), updated_at = now()
        where id = v_id
        returning * into v_new;
        if (to_jsonb(v_new) - 'is_primary' - 'updated_at') is distinct from (to_jsonb(v_acc) - 'is_primary' - 'updated_at') then
          insert into public.seller_bank_account_events (organization_id, seller_id, account_id, action, before, after, actor)
          values (p_org, v_seller, v_id, 'changed', to_jsonb(v_acc) - 'is_primary' - 'updated_at', to_jsonb(v_new) - 'is_primary' - 'updated_at', auth.uid());
        end if;
      end if;
    exception when check_violation then
      raise exception 'seller_account_invalid';
    end;
    if coalesce((a->>'primary')::boolean, false) and v_primary is null then v_primary := v_new.id; end if;
  end loop;
  -- Exactly one primary among the active accounts: the one marked, else the oldest.
  if v_primary is null then
    select x.id into v_primary from public.seller_bank_accounts x where x.seller_id = v_seller and x.removed_at is null order by x.created_at, x.id limit 1;
  end if;
  if v_primary is not null then update public.seller_bank_accounts set is_primary = true where id = v_primary; end if;

  -- Contacts: the list sent replaces the previous one.
  if jsonb_typeof(coalesce(p_data->'contacts', '[]'::jsonb)) <> 'array' then raise exception 'seller_contact_invalid'; end if;
  delete from public.seller_contacts where seller_id = v_seller;
  for c in select * from jsonb_array_elements(coalesce(p_data->'contacts', '[]'::jsonb)) loop
    v_doc := nullif(regexp_replace(coalesce(c->>'cpf', ''), '\D', '', 'g'), '');
    if v_doc is not null and not private.is_valid_cpf(v_doc) then raise exception 'seller_contact_invalid'; end if;
    if nullif(btrim(coalesce(c->>'email', '')), '') is not null and lower(btrim(c->>'email')) !~ v_email_re then raise exception 'seller_contact_invalid'; end if;
    begin
      insert into public.seller_contacts (organization_id, seller_id, name, cpf, role, mobile, email)
      values (p_org, v_seller, btrim(coalesce(c->>'name', '')), v_doc, nullif(btrim(c->>'role'), ''),
        case when nullif(btrim(coalesce(c->>'mobile', '')), '') is null then null else coalesce(private.normalize_phone(c->>'mobile'), 'x') end,
        nullif(lower(btrim(c->>'email')), ''));
    exception when check_violation then
      raise exception 'seller_contact_invalid';
    end;
  end loop;
  perform set_config('corban.seller_rpc', 'off', true);
  perform set_config('corban.seller_profile_rpc', 'off', true);

  return v_seller;
end
$function$;
