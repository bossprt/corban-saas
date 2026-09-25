-- Editing an existing client in the same form as the registration (owner decision 25/09/2026, ADR-0033 addendum).
--
-- 1. update_client_identity: name, phone and e-mail, with clientes.edit and sight of the client (private.editable_client).
--    The CPF never changes. A new phone or e-mail becomes the main one; the previous one stays in the contact history.
-- 2. update_client_bank_account: the fields of an existing account (the primary flag keeps its own RPC).

create or replace function public.update_client_identity(p_client uuid, p_full_name text, p_phone text, p_email text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  c public.clients%rowtype := private.editable_client(p_client);
  v_name text := btrim(coalesce(p_full_name, ''));
  v_phone text := nullif(btrim(coalesce(p_phone, '')), '');
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
begin
  if length(v_name) < 3 or length(v_name) > 160 then raise exception 'full_name_required'; end if;
  if v_phone is not null then
    v_phone := private.normalize_phone(v_phone);
    if v_phone is null then raise exception 'invalid_phone'; end if;
  end if;
  if v_email is not null and v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'invalid_email'; end if;

  perform set_config('corban.timeline_rpc', 'on', true);
  if v_phone is not null then perform private.record_client_contact(c.organization_id, c.id, 'phone', v_phone, 'manual'); end if;
  if v_email is not null then perform private.record_client_contact(c.organization_id, c.id, 'email', v_email, 'manual'); end if;
  perform set_config('corban.timeline_rpc', 'off', true);
  update public.clients
  set full_name = v_name, phone = coalesce(v_phone, phone), email = coalesce(v_email, email), updated_at = now()
  where id = c.id;
end
$$;

create or replace function public.update_client_bank_account(p_account uuid, p_bank_code text, p_bank_name text, p_branch text, p_account_number text,
  p_account_digit text, p_account_type text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare a public.customer_bank_accounts%rowtype; c public.clients%rowtype;
begin
  select * into a from public.customer_bank_accounts where id = p_account;
  if a.id is null then raise exception 'not_authorized'; end if;
  c := private.editable_client(a.customer_id);
  if coalesce(p_bank_code, '') !~ '^[0-9]{3}$' then raise exception 'invalid_bank_code'; end if;
  if length(btrim(coalesce(p_bank_name, ''))) not between 2 and 120 then raise exception 'invalid_bank_name'; end if;
  if coalesce(p_branch, '') !~ '^[0-9]{1,6}(-[0-9Xx])?$' then raise exception 'invalid_branch'; end if;
  if coalesce(p_account_number, '') !~ '^[0-9]{1,20}$' then raise exception 'invalid_account'; end if;
  if p_account_digit is not null and p_account_digit <> '' and p_account_digit !~ '^[0-9Xx]{1,2}$' then raise exception 'invalid_account'; end if;
  if p_account_type not in ('checking','savings','salary','payment') then raise exception 'invalid_account_type'; end if;
  update public.customer_bank_accounts
  set bank_code = p_bank_code, bank_name = btrim(p_bank_name), branch = p_branch, account_number = p_account_number,
      account_digit = nullif(upper(p_account_digit), ''), account_type = p_account_type, updated_at = now()
  where id = a.id;
end
$$;

revoke all on function public.update_client_identity(uuid, text, text, text) from public, anon;
revoke all on function public.update_client_bank_account(uuid, text, text, text, text, text, text) from public, anon;
grant execute on function public.update_client_identity(uuid, text, text, text) to authenticated;
grant execute on function public.update_client_bank_account(uuid, text, text, text, text, text, text) to authenticated;
