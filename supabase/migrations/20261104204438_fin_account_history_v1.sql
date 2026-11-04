-- Company finance, step 2 of the review (owner approval 04/11/2026):
-- 1. A chart account with open entries cannot be deactivated: those entries could no longer be settled.
-- 2. Bank accounts keep a history. Changing the opening balance or its date asks for a reason, because it moves every
--    past balance of the account; creation, activation and deactivation are recorded too. Nothing is deleted.

create table public.fin_bank_account_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  bank_account_id uuid not null,
  kind text not null check (kind in ('created', 'opening_changed', 'activated', 'deactivated')),
  detail jsonb not null default '{}'::jsonb,
  reason text,
  actor_user_id uuid,
  created_at timestamptz not null default now(),
  foreign key (organization_id, bank_account_id) references public.fin_bank_accounts (organization_id, id)
);
create index fin_bank_account_events_account on public.fin_bank_account_events (bank_account_id, created_at);
alter table public.fin_bank_account_events enable row level security;
create policy fin_bank_account_events_select on public.fin_bank_account_events for select to authenticated
  using (public.has_permission(organization_id, 'financeiro.view'));
revoke all on public.fin_bank_account_events from public, anon, authenticated;
grant select on public.fin_bank_account_events to authenticated;

-- Accounts that already exist start their history with what they have today.
insert into public.fin_bank_account_events (organization_id, bank_account_id, kind, detail, created_at)
select organization_id, id, 'created', jsonb_build_object('opening_balance', opening_balance, 'opening_on', opening_on), created_at
from public.fin_bank_accounts;

-- Same as 20260927204141 (with the São Paulo date of 20261020031521), plus p_reason and the history.
drop function public.fin_save_bank_account(uuid, uuid, text, text, text, text, numeric, date, boolean);
create function public.fin_save_bank_account(p_org uuid, p_id uuid, p_bank_name text, p_label text, p_agency text, p_account_number text,
                                             p_opening_balance numeric, p_opening_on date, p_active boolean, p_reason text default null)
returns uuid
language plpgsql
security definer
set search_path to ''
set timezone to 'America/Sao_Paulo'
as $$
declare v_id uuid; b public.fin_bank_accounts%rowtype; v_on date;
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if p_opening_balance is null or p_opening_balance <> round(p_opening_balance, 2) or abs(p_opening_balance) >= 1e13 then raise exception 'invalid_amount'; end if;
  begin
    if p_id is null then
      insert into public.fin_bank_accounts (organization_id, bank_name, label, agency, account_number, opening_balance, opening_on)
      values (p_org, btrim(p_bank_name), btrim(p_label), nullif(btrim(coalesce(p_agency, '')), ''), nullif(btrim(coalesce(p_account_number, '')), ''),
              p_opening_balance, coalesce(p_opening_on, current_date))
      returning id, opening_on into v_id, v_on;
      insert into public.fin_bank_account_events (organization_id, bank_account_id, kind, detail, actor_user_id)
      values (p_org, v_id, 'created', jsonb_build_object('opening_balance', p_opening_balance, 'opening_on', v_on), auth.uid());
      return v_id;
    end if;
    select * into b from public.fin_bank_accounts where id = p_id and organization_id = p_org for update;
    if b.id is null then raise exception 'not_authorized'; end if;
    v_on := coalesce(p_opening_on, b.opening_on);
    if (p_opening_balance <> b.opening_balance or v_on <> b.opening_on) and length(btrim(coalesce(p_reason, ''))) < 3 then
      raise exception 'reason_required';
    end if;
    update public.fin_bank_accounts
    set bank_name = btrim(p_bank_name), label = btrim(p_label), agency = nullif(btrim(coalesce(p_agency, '')), ''),
        account_number = nullif(btrim(coalesce(p_account_number, '')), ''), opening_balance = p_opening_balance,
        opening_on = v_on, is_active = coalesce(p_active, true)
    where id = b.id;
  exception when check_violation then raise exception 'fin_bank_account_invalid';
  end;
  if p_opening_balance <> b.opening_balance or v_on <> b.opening_on then
    insert into public.fin_bank_account_events (organization_id, bank_account_id, kind, detail, reason, actor_user_id)
    values (p_org, b.id, 'opening_changed', jsonb_build_object(
      'opening_balance', jsonb_build_object('from', b.opening_balance, 'to', p_opening_balance),
      'opening_on', jsonb_build_object('from', b.opening_on, 'to', v_on)), btrim(p_reason), auth.uid());
  end if;
  if coalesce(p_active, true) <> b.is_active then
    insert into public.fin_bank_account_events (organization_id, bank_account_id, kind, reason, actor_user_id)
    values (p_org, b.id, case when coalesce(p_active, true) then 'activated' else 'deactivated' end, nullif(btrim(coalesce(p_reason, '')), ''), auth.uid());
  end if;
  return b.id;
end
$$;
revoke all on function public.fin_save_bank_account(uuid, uuid, text, text, text, text, numeric, date, boolean, text) from public, anon;
grant execute on function public.fin_save_bank_account(uuid, uuid, text, text, text, text, numeric, date, boolean, text) to authenticated;

-- Same as 20260927204141, plus: a chart account with open entries is not deactivated.
create or replace function public.fin_save_chart_account(p_org uuid, p_id uuid, p_code text, p_name text, p_kind text, p_is_group boolean, p_active boolean)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare a public.fin_chart_accounts%rowtype; v_id uuid;
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  perform private.fin_ensure_chart(p_org);
  if p_id is null then
    begin
      insert into public.fin_chart_accounts (organization_id, code, name, kind, is_group)
      values (p_org, btrim(p_code), btrim(p_name), p_kind, coalesce(p_is_group, false)) returning id into v_id;
    exception
      when unique_violation then raise exception 'fin_account_code_exists';
      when check_violation then raise exception 'fin_account_invalid';
    end;
    return v_id;
  end if;
  select * into a from public.fin_chart_accounts where id = p_id and organization_id = p_org for update;
  if a.id is null then raise exception 'not_authorized'; end if;
  if (p_kind is distinct from a.kind or coalesce(p_is_group, false) <> a.is_group)
     and exists (select 1 from public.fin_entries e where e.account_id = a.id) then raise exception 'fin_account_in_use'; end if;
  if a.system_key is not null and coalesce(p_active, true) = false then raise exception 'fin_account_system'; end if;
  if a.is_active and coalesce(p_active, true) = false
     and exists (select 1 from public.fin_entries e where e.account_id = a.id and e.status = 'open') then raise exception 'fin_account_open_entries'; end if;
  begin
    update public.fin_chart_accounts set code = btrim(p_code), name = btrim(p_name), kind = p_kind, is_group = coalesce(p_is_group, false), is_active = coalesce(p_active, true)
    where id = a.id;
  exception
    when unique_violation then raise exception 'fin_account_code_exists';
    when check_violation then raise exception 'fin_account_invalid';
  end;
  return a.id;
end
$$;
revoke all on function public.fin_save_chart_account(uuid, uuid, text, text, text, boolean, boolean) from public, anon;
grant execute on function public.fin_save_chart_account(uuid, uuid, text, text, text, boolean, boolean) to authenticated;
