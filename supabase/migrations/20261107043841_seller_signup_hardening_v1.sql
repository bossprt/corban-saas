-- Seller registration link hardening (audit 06/11/2026, items G1, G2, G4).
-- G1: a second submission with a document that is already waiting no longer replaces the first request (it could swap
--     the PIX/bank data of someone else's request). It is refused with signup_already_pending; nothing else is revealed.
-- G2: at most 20 submissions per link per hour (was 30); the 200 waiting per company cap stays. The queue can be
--     refused in bulk (seller_signup_reject_many), so a flood is cleared in one step.
-- G4: refusing keeps the record (name, document, who refused and when) and erases the data sent (payload), as before;
--     the screen now asks for confirmation and lists the refused requests.

create or replace function public.seller_signup_submit(p_token text, p_data jsonb)
returns void language plpgsql security definer set search_path to '' as $$
declare
  l public.seller_signup_links%rowtype;
  p jsonb := coalesce(p_data->'profile', '{}'::jsonb);
  v_name text := btrim(coalesce(p_data->>'name', ''));
  v_tax text := regexp_replace(coalesce(p_data->>'tax_id', ''), '\D', '', 'g');
  v_email text := lower(btrim(coalesce(p->>'email', '')));
begin
  select * into l from public.seller_signup_links where token = p_token;
  if l.id is null or not l.is_active
     or not exists (select 1 from public.commission_groups g where g.id = l.commission_group_id and g.is_active)
     or not exists (select 1 from public.organizations o where o.id = l.organization_id and o.is_active) then
    raise exception 'signup_link_closed';
  end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' or pg_column_size(p_data) > 32768
     or jsonb_typeof(coalesce(p_data->'accounts', '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_data->'accounts', '[]'::jsonb)) > 5
     or jsonb_typeof(coalesce(p_data->'contacts', '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_data->'contacts', '[]'::jsonb)) > 10
     or jsonb_typeof(p) <> 'object' then
    raise exception 'signup_invalid';
  end if;
  if length(v_name) not between 1 and 160 then raise exception 'seller_name_required'; end if;
  if not ((length(v_tax) = 11 and private.is_valid_cpf(v_tax)) or (length(v_tax) = 14 and private.is_valid_cnpj(v_tax))) then raise exception 'seller_tax_id_invalid'; end if;
  if coalesce(p_data->>'category', '') not in ('pf', 'pj', 'sub') then raise exception 'seller_category_invalid'; end if;
  if private.normalize_phone(coalesce(p->>'mobile', '')) is null then raise exception 'seller_mobile_required'; end if;
  if v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' or length(v_email) > 160 then raise exception 'seller_email_required'; end if;
  if (select count(*) from public.seller_signup_requests r where r.link_id = l.id and r.created_at > now() - interval '1 hour') >= 20
     or (select count(*) from public.seller_signup_requests r where r.organization_id = l.organization_id and r.status = 'pending') >= 200 then
    raise exception 'signup_rate_limited';
  end if;
  if exists (select 1 from public.seller_signup_requests r where r.organization_id = l.organization_id and r.tax_id = v_tax and r.status = 'pending') then
    raise exception 'signup_already_pending';
  end if;
  -- Only the fields of the form travel; group, branch, internal and payment rules are the administrator's.
  p_data := jsonb_build_object('name', v_name, 'tax_id', v_tax, 'category', p_data->>'category', 'profile', p,
    'accounts', coalesce(p_data->'accounts', '[]'::jsonb), 'contacts', coalesce(p_data->'contacts', '[]'::jsonb));
  begin
    insert into public.seller_signup_requests (organization_id, link_id, commission_group_id, name, tax_id, payload)
    values (l.organization_id, l.id, l.commission_group_id, v_name, v_tax, p_data);
  exception when unique_violation then
    -- Two submissions of the same document at the same moment: the second one loses, never overwrites.
    raise exception 'signup_already_pending';
  end;
end $$;

-- Refuse several waiting requests at once (one or many). Every id must belong to a company where the caller is admin or
-- manager; requests already decided are skipped. Returns how many were refused.
create or replace function public.seller_signup_reject_many(p_requests uuid[])
returns integer language plpgsql security definer set search_path to '' as $$
declare v_count integer;
begin
  if auth.uid() is null or p_requests is null or cardinality(p_requests) not between 1 and 200 then raise exception 'not_authorized'; end if;
  if exists (
    select 1 from unnest(p_requests) as x(id)
    left join public.seller_signup_requests r on r.id = x.id
    where r.id is null or not public.has_active_organization_role(r.organization_id, array['admin', 'manager'])
  ) then
    raise exception 'not_authorized';
  end if;
  update public.seller_signup_requests set status = 'rejected', payload = null,
    decided_by = auth.uid(), decided_at = now(), updated_at = now()
  where id = any(p_requests) and status = 'pending';
  get diagnostics v_count = row_count;
  return v_count;
end $$;

revoke all on function public.seller_signup_submit(text, jsonb), public.seller_signup_reject_many(uuid[]) from public, anon, authenticated;
grant execute on function public.seller_signup_submit(text, jsonb) to anon, authenticated;
grant execute on function public.seller_signup_reject_many(uuid[]) to authenticated;
