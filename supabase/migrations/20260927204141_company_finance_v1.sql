-- F6.5: company finance (map section 9, ADR-0045). Payables and receivables with a chart of accounts and the branch as
-- cost center, company bank accounts, bank statement (OFX) import and reconciliation, cash flow and income statement.
--
-- Owner decisions (27/09/2026): start from a standard chart for a credit correspondent, editable; cost center = branch;
-- the commission received from the banks and the payout paid to the sellers are posted automatically, with a company
-- switch to post them by hand one by one instead; OFX from C6 Bank, Banco do Brasil, Inter and PagSeguro.
--
-- Money is numeric(15,2). History is kept: an entry is never deleted (it is cancelled with a reason) and every change is
-- an event. Writes only through the functions below; reading needs financeiro.view.

-- Chart of accounts. Group lines (is_group) organize; entries go to the other lines. The kind drives the income
-- statement: income - deduction = net revenue; - cost = margin; - expense; +/- financial = result. transfer is outside it.
create table public.fin_chart_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  code text not null check (code ~ '^[0-9]{1,3}(\.[0-9]{1,3}){0,3}$'),
  name text not null check (length(btrim(name)) between 2 and 80),
  kind text not null check (kind in ('income', 'deduction', 'cost', 'expense', 'financial_income', 'financial_expense', 'transfer')),
  is_group boolean not null default false,
  system_key text check (system_key is null or system_key ~ '^[a-z_]{3,40}$'),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (organization_id, code),
  unique (organization_id, id)
);
create unique index fin_chart_accounts_system_key on public.fin_chart_accounts (organization_id, system_key) where system_key is not null;

create table public.fin_bank_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  bank_name text not null check (length(btrim(bank_name)) between 2 and 60),
  label text not null check (length(btrim(label)) between 2 and 60),
  agency text check (agency is null or agency ~ '^[0-9A-Za-z-]{1,10}$'),
  account_number text check (account_number is null or account_number ~ '^[0-9A-Za-z-]{1,20}$'),
  opening_balance numeric(15,2) not null default 0,
  opening_on date not null default current_date,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (organization_id, id)
);

create table public.fin_settings (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  auto_post boolean not null default true,
  updated_by uuid,
  updated_at timestamptz not null default now()
);

-- One payable (out) or receivable (in). Settled = money moved (settled_on); the bank account says where (it can be
-- filled later by the statement reconciliation).
create table public.fin_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  direction text not null check (direction in ('in', 'out')),
  status text not null default 'open' check (status in ('open', 'settled', 'cancelled')),
  description text not null check (length(btrim(description)) between 3 and 200),
  account_id uuid not null,
  branch_id uuid,
  counterpart text check (counterpart is null or length(counterpart) <= 120),
  document text check (document is null or length(document) <= 60),
  amount numeric(15,2) not null check (amount > 0),
  due_on date not null,
  competence_on date not null,
  settled_on date,
  bank_account_id uuid,
  source text not null default 'manual' check (source in ('manual', 'commission_receipt', 'payout', 'statement')),
  source_ref uuid,
  proposal_id uuid,
  installment_group uuid,
  installment_no integer,
  installments integer,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (organization_id, account_id) references public.fin_chart_accounts (organization_id, id),
  foreign key (organization_id, bank_account_id) references public.fin_bank_accounts (organization_id, id),
  foreign key (organization_id, branch_id) references public.organization_branches (organization_id, id),
  unique (organization_id, id),
  check ((status = 'settled') = (settled_on is not null))
);
-- Automatic postings happen once per receipt or payout.
create unique index fin_entries_source_once on public.fin_entries (organization_id, source, source_ref) where source_ref is not null and status <> 'cancelled';
create index fin_entries_org_due on public.fin_entries (organization_id, status, due_on);
create index fin_entries_org_settled on public.fin_entries (organization_id, settled_on) where status = 'settled';
create index fin_entries_org_competence on public.fin_entries (organization_id, competence_on);
create index fin_entries_account on public.fin_entries (account_id);
create index fin_entries_bank on public.fin_entries (bank_account_id) where bank_account_id is not null;
create index fin_entries_branch on public.fin_entries (branch_id) where branch_id is not null;

create table public.fin_entry_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  entry_id uuid not null,
  kind text not null check (kind in ('created', 'edited', 'settled', 'settlement_undone', 'cancelled', 'reconciled')),
  detail jsonb not null default '{}'::jsonb,
  reason text,
  actor_user_id uuid,
  created_at timestamptz not null default now(),
  foreign key (organization_id, entry_id) references public.fin_entries (organization_id, id)
);
create index fin_entry_events_entry on public.fin_entry_events (entry_id, created_at);

-- Bank statements (OFX): each transaction once per account (FITID); matched to an entry or turned into one.
create table public.fin_statement_imports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  bank_account_id uuid not null,
  file_name text not null check (length(btrim(file_name)) between 1 and 200),
  file_sha256 text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  line_count integer not null default 0,
  created_by uuid,
  created_at timestamptz not null default now(),
  foreign key (organization_id, bank_account_id) references public.fin_bank_accounts (organization_id, id),
  unique (organization_id, id),
  unique (bank_account_id, file_sha256)
);
create table public.fin_statement_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  bank_account_id uuid not null,
  import_id uuid not null,
  fitid text not null check (length(fitid) between 1 and 80),
  posted_on date not null,
  amount numeric(15,2) not null check (amount <> 0),
  memo text,
  status text not null default 'pending' check (status in ('pending', 'matched', 'ignored')),
  entry_id uuid,
  foreign key (organization_id, bank_account_id) references public.fin_bank_accounts (organization_id, id),
  foreign key (organization_id, import_id) references public.fin_statement_imports (organization_id, id),
  foreign key (organization_id, entry_id) references public.fin_entries (organization_id, id),
  unique (bank_account_id, fitid),
  check ((status = 'matched') = (entry_id is not null))
);
create index fin_statement_lines_pending on public.fin_statement_lines (organization_id, bank_account_id, status, posted_on);
create unique index fin_statement_lines_entry_once on public.fin_statement_lines (entry_id) where entry_id is not null;

-- Reading: whoever sees the finance; writing only through the functions.
alter table public.fin_chart_accounts enable row level security;
alter table public.fin_bank_accounts enable row level security;
alter table public.fin_settings enable row level security;
alter table public.fin_entries enable row level security;
alter table public.fin_entry_events enable row level security;
alter table public.fin_statement_imports enable row level security;
alter table public.fin_statement_lines enable row level security;
create policy fin_chart_accounts_select on public.fin_chart_accounts for select to authenticated using (public.has_permission(organization_id, 'financeiro.view'));
create policy fin_bank_accounts_select on public.fin_bank_accounts for select to authenticated using (public.has_permission(organization_id, 'financeiro.view'));
create policy fin_settings_select on public.fin_settings for select to authenticated using (public.has_permission(organization_id, 'financeiro.view'));
create policy fin_entries_select on public.fin_entries for select to authenticated using (public.has_permission(organization_id, 'financeiro.view'));
create policy fin_entry_events_select on public.fin_entry_events for select to authenticated using (public.has_permission(organization_id, 'financeiro.view'));
create policy fin_statement_imports_select on public.fin_statement_imports for select to authenticated using (public.has_permission(organization_id, 'financeiro.view'));
create policy fin_statement_lines_select on public.fin_statement_lines for select to authenticated using (public.has_permission(organization_id, 'financeiro.view'));
revoke all on public.fin_chart_accounts, public.fin_bank_accounts, public.fin_settings, public.fin_entries, public.fin_entry_events,
  public.fin_statement_imports, public.fin_statement_lines from public, anon, authenticated;
grant select on public.fin_chart_accounts, public.fin_bank_accounts, public.fin_settings, public.fin_entries, public.fin_entry_events,
  public.fin_statement_imports, public.fin_statement_lines to authenticated;

-- The standard chart of a credit correspondent (created once per company; the owner edits it afterwards).
create or replace function private.fin_ensure_chart(p_org uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
begin
  if exists (select 1 from public.fin_chart_accounts where organization_id = p_org) then return; end if;
  insert into public.fin_chart_accounts (organization_id, code, name, kind, is_group, system_key)
  select p_org, v.code, v.name, v.kind, v.is_group, v.system_key
  from (values
    ('1', 'Receitas', 'income', true, null),
    ('1.1', 'Comissão à vista recebida', 'income', false, 'commission_upfront'),
    ('1.2', 'Comissão diferida recebida', 'income', false, 'commission_deferred'),
    ('1.3', 'Bônus e outras receitas de bancos', 'income', false, null),
    ('1.9', 'Outras receitas', 'income', false, null),
    ('2', 'Deduções da receita', 'deduction', true, null),
    ('2.1', 'Impostos sobre a receita (Simples Nacional)', 'deduction', false, 'tax'),
    ('2.2', 'Estornos de comissão', 'deduction', false, 'chargeback'),
    ('3', 'Custos', 'cost', true, null),
    ('3.1', 'Repasse a vendedores e corretores', 'cost', false, 'payout'),
    ('4', 'Despesas', 'expense', true, null),
    ('4.1', 'Salários e encargos', 'expense', false, null),
    ('4.2', 'Pró-labore', 'expense', false, null),
    ('4.3', 'Aluguel e condomínio', 'expense', false, null),
    ('4.4', 'Energia, água e internet', 'expense', false, null),
    ('4.5', 'Telefonia e sistemas', 'expense', false, null),
    ('4.6', 'Marketing', 'expense', false, null),
    ('4.7', 'Contabilidade e serviços', 'expense', false, null),
    ('4.8', 'Material de escritório', 'expense', false, null),
    ('4.9', 'Outras despesas', 'expense', false, null),
    ('5', 'Resultado financeiro', 'financial_income', true, null),
    ('5.1', 'Rendimentos de aplicações', 'financial_income', false, null),
    ('5.2', 'Tarifas bancárias e juros', 'financial_expense', false, 'bank_fees'),
    ('6', 'Transferências entre contas', 'transfer', false, 'transfer')
  ) v(code, name, kind, is_group, system_key);
end
$$;
revoke all on function private.fin_ensure_chart(uuid) from public, anon, authenticated;

create or replace function private.fin_event(p_org uuid, p_entry uuid, p_kind text, p_detail jsonb, p_reason text)
returns void
language sql
security definer
set search_path to ''
as $$
  insert into public.fin_entry_events (organization_id, entry_id, kind, detail, reason, actor_user_id)
  values (p_org, p_entry, p_kind, coalesce(p_detail, '{}'::jsonb), nullif(btrim(coalesce(p_reason, '')), ''), auth.uid());
$$;
revoke all on function private.fin_event(uuid, uuid, text, jsonb, text) from public, anon, authenticated;

-- Opening the finance: the standard chart and the settings exist (idempotent; the screen calls it).
create or replace function public.fin_setup(p_org uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.view') then raise exception 'not_authorized'; end if;
  perform private.fin_ensure_chart(p_org);
  insert into public.fin_settings (organization_id) values (p_org) on conflict (organization_id) do nothing;
end
$$;
revoke all on function public.fin_setup(uuid) from public, anon;
grant execute on function public.fin_setup(uuid) to authenticated;

create or replace function public.fin_set_auto_post(p_org uuid, p_auto boolean)
returns void
language plpgsql
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or not public.has_active_organization_role(p_org, array['admin']) then raise exception 'not_authorized'; end if;
  insert into public.fin_settings (organization_id, auto_post, updated_by, updated_at) values (p_org, coalesce(p_auto, true), auth.uid(), now())
  on conflict (organization_id) do update set auto_post = excluded.auto_post, updated_by = auth.uid(), updated_at = now();
end
$$;
revoke all on function public.fin_set_auto_post(uuid, boolean) from public, anon;
grant execute on function public.fin_set_auto_post(uuid, boolean) to authenticated;

-- Chart of accounts: add or rename a line (the kind of a used line never changes; unused lines can be switched off).
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

create or replace function public.fin_save_bank_account(p_org uuid, p_id uuid, p_bank_name text, p_label text, p_agency text, p_account_number text,
                                                        p_opening_balance numeric, p_opening_on date, p_active boolean)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare v_id uuid;
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if p_opening_balance is null or p_opening_balance <> round(p_opening_balance, 2) or abs(p_opening_balance) >= 1e13 then raise exception 'invalid_amount'; end if;
  begin
    if p_id is null then
      insert into public.fin_bank_accounts (organization_id, bank_name, label, agency, account_number, opening_balance, opening_on)
      values (p_org, btrim(p_bank_name), btrim(p_label), nullif(btrim(coalesce(p_agency, '')), ''), nullif(btrim(coalesce(p_account_number, '')), ''),
              p_opening_balance, coalesce(p_opening_on, current_date))
      returning id into v_id;
    else
      update public.fin_bank_accounts
      set bank_name = btrim(p_bank_name), label = btrim(p_label), agency = nullif(btrim(coalesce(p_agency, '')), ''),
          account_number = nullif(btrim(coalesce(p_account_number, '')), ''), opening_balance = p_opening_balance,
          opening_on = coalesce(p_opening_on, opening_on), is_active = coalesce(p_active, true)
      where id = p_id and organization_id = p_org returning id into v_id;
      if v_id is null then raise exception 'not_authorized'; end if;
    end if;
  exception when check_violation then raise exception 'fin_bank_account_invalid';
  end;
  return v_id;
end
$$;
revoke all on function public.fin_save_bank_account(uuid, uuid, text, text, text, text, numeric, date, boolean) from public, anon;
grant execute on function public.fin_save_bank_account(uuid, uuid, text, text, text, text, numeric, date, boolean) to authenticated;

-- Checks shared by the entry functions: a usable account and branch of the company.
create or replace function private.fin_check_refs(p_org uuid, p_account uuid, p_branch uuid, p_bank uuid)
returns void
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if not exists (select 1 from public.fin_chart_accounts a where a.id = p_account and a.organization_id = p_org and not a.is_group and a.is_active) then
    raise exception 'fin_account_invalid';
  end if;
  if p_branch is not null and not exists (select 1 from public.organization_branches b where b.id = p_branch and b.organization_id = p_org) then raise exception 'fin_branch_invalid'; end if;
  if p_bank is not null and not exists (select 1 from public.fin_bank_accounts k where k.id = p_bank and k.organization_id = p_org and k.is_active) then raise exception 'fin_bank_account_invalid'; end if;
end
$$;
revoke all on function private.fin_check_refs(uuid, uuid, uuid, uuid) from public, anon, authenticated;

-- New payable or receivable, in 1 to 60 monthly installments (the cents left over go to the last one). Optionally settled
-- at once (money already moved).
create or replace function public.fin_create_entry(p_org uuid, p_direction text, p_description text, p_account uuid, p_branch uuid, p_counterpart text,
                                                   p_document text, p_amount numeric, p_due_on date, p_competence_on date, p_installments integer,
                                                   p_settled_on date, p_bank_account uuid)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_n integer := coalesce(p_installments, 1);
  v_part numeric; v_last numeric; v_group uuid := gen_random_uuid(); v_id uuid; v_first uuid; i integer;
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if p_direction not in ('in', 'out') then raise exception 'fin_entry_invalid'; end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) or p_amount >= 1e13 then raise exception 'invalid_amount'; end if;
  if v_n < 1 or v_n > 60 then raise exception 'fin_installments_invalid'; end if;
  if p_due_on is null then raise exception 'fin_due_required'; end if;
  if p_settled_on is not null and (v_n > 1 or p_settled_on > current_date) then raise exception 'fin_settle_invalid'; end if;
  perform private.fin_check_refs(p_org, p_account, p_branch, p_bank_account);
  v_part := trunc(p_amount / v_n, 2);
  v_last := p_amount - v_part * (v_n - 1);
  if v_part <= 0 then raise exception 'invalid_amount'; end if;
  for i in 1..v_n loop
    begin
      insert into public.fin_entries (organization_id, direction, status, description, account_id, branch_id, counterpart, document, amount, due_on, competence_on,
                                      settled_on, bank_account_id, source, installment_group, installment_no, installments, created_by)
      values (p_org, p_direction, case when p_settled_on is null then 'open' else 'settled' end,
              btrim(p_description) || case when v_n > 1 then ' (' || i || '/' || v_n || ')' else '' end,
              p_account, p_branch, nullif(btrim(coalesce(p_counterpart, '')), ''), nullif(btrim(coalesce(p_document, '')), ''),
              case when i = v_n then v_last else v_part end, (p_due_on + make_interval(months => i - 1))::date,
              (coalesce(p_competence_on, p_due_on) + make_interval(months => i - 1))::date,
              p_settled_on, case when p_settled_on is null then null else p_bank_account end, 'manual',
              case when v_n > 1 then v_group end, case when v_n > 1 then i end, case when v_n > 1 then v_n end, auth.uid())
      returning id into v_id;
    exception when check_violation then raise exception 'fin_entry_invalid';
    end;
    perform private.fin_event(p_org, v_id, 'created', jsonb_build_object('amount', case when i = v_n then v_last else v_part end), null);
    if p_settled_on is not null then perform private.fin_event(p_org, v_id, 'settled', jsonb_build_object('on', p_settled_on, 'bank', p_bank_account), null); end if;
    v_first := coalesce(v_first, v_id);
  end loop;
  return v_first;
end
$$;
revoke all on function public.fin_create_entry(uuid, text, text, uuid, uuid, text, text, numeric, date, date, integer, date, uuid) from public, anon;
grant execute on function public.fin_create_entry(uuid, text, text, uuid, uuid, text, text, numeric, date, date, integer, date, uuid) to authenticated;

-- Change an open entry (what changed is kept in its history).
create or replace function public.fin_update_entry(p_entry uuid, p_description text, p_account uuid, p_branch uuid, p_counterpart text, p_document text,
                                                   p_amount numeric, p_due_on date, p_competence_on date, p_reason text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare e public.fin_entries%rowtype; v_changes jsonb := '{}'::jsonb;
begin
  select * into e from public.fin_entries where id = p_entry for update;
  if e.id is null or auth.uid() is null or not public.has_permission(e.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if e.status <> 'open' then raise exception 'fin_entry_not_open'; end if;
  if e.source <> 'manual' and (p_amount is distinct from e.amount) then raise exception 'fin_entry_automatic'; end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) or p_amount >= 1e13 then raise exception 'invalid_amount'; end if;
  perform private.fin_check_refs(e.organization_id, p_account, p_branch, null);
  if btrim(p_description) is distinct from e.description then v_changes := v_changes || jsonb_build_object('description', jsonb_build_object('from', e.description, 'to', btrim(p_description))); end if;
  if p_account is distinct from e.account_id then v_changes := v_changes || jsonb_build_object('account', jsonb_build_object('from', e.account_id, 'to', p_account)); end if;
  if p_branch is distinct from e.branch_id then v_changes := v_changes || jsonb_build_object('branch', jsonb_build_object('from', e.branch_id, 'to', p_branch)); end if;
  if p_amount is distinct from e.amount then v_changes := v_changes || jsonb_build_object('amount', jsonb_build_object('from', e.amount, 'to', p_amount)); end if;
  if p_due_on is distinct from e.due_on then v_changes := v_changes || jsonb_build_object('due_on', jsonb_build_object('from', e.due_on, 'to', p_due_on)); end if;
  if coalesce(p_competence_on, p_due_on) is distinct from e.competence_on then v_changes := v_changes || jsonb_build_object('competence_on', jsonb_build_object('from', e.competence_on, 'to', coalesce(p_competence_on, p_due_on))); end if;
  if v_changes = '{}'::jsonb and nullif(btrim(coalesce(p_counterpart, '')), '') is not distinct from e.counterpart
     and nullif(btrim(coalesce(p_document, '')), '') is not distinct from e.document then return; end if;
  begin
    update public.fin_entries
    set description = btrim(p_description), account_id = p_account, branch_id = p_branch, counterpart = nullif(btrim(coalesce(p_counterpart, '')), ''),
        document = nullif(btrim(coalesce(p_document, '')), ''), amount = p_amount, due_on = p_due_on, competence_on = coalesce(p_competence_on, p_due_on), updated_at = now()
    where id = e.id;
  exception when check_violation then raise exception 'fin_entry_invalid';
  end;
  perform private.fin_event(e.organization_id, e.id, 'edited', v_changes, p_reason);
end
$$;
revoke all on function public.fin_update_entry(uuid, text, uuid, uuid, text, text, numeric, date, date, text) from public, anon;
grant execute on function public.fin_update_entry(uuid, text, uuid, uuid, text, text, numeric, date, date, text) to authenticated;

-- Money moved: settle (date and, when known, the bank account). Undo keeps the history.
create or replace function public.fin_settle_entry(p_entry uuid, p_settled_on date, p_bank_account uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare e public.fin_entries%rowtype;
begin
  select * into e from public.fin_entries where id = p_entry for update;
  if e.id is null or auth.uid() is null or not public.has_permission(e.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if e.status <> 'open' then raise exception 'fin_entry_not_open'; end if;
  if p_settled_on is null or p_settled_on > current_date then raise exception 'fin_settle_invalid'; end if;
  perform private.fin_check_refs(e.organization_id, e.account_id, e.branch_id, p_bank_account);
  update public.fin_entries set status = 'settled', settled_on = p_settled_on, bank_account_id = p_bank_account, updated_at = now() where id = e.id;
  perform private.fin_event(e.organization_id, e.id, 'settled', jsonb_build_object('on', p_settled_on, 'bank', p_bank_account), null);
end
$$;
revoke all on function public.fin_settle_entry(uuid, date, uuid) from public, anon;
grant execute on function public.fin_settle_entry(uuid, date, uuid) to authenticated;

create or replace function public.fin_undo_settlement(p_entry uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare e public.fin_entries%rowtype;
begin
  select * into e from public.fin_entries where id = p_entry for update;
  if e.id is null or auth.uid() is null or not public.has_permission(e.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if e.status <> 'settled' then raise exception 'fin_entry_not_settled'; end if;
  if e.source <> 'manual' then raise exception 'fin_entry_automatic'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'reason_required'; end if;
  if exists (select 1 from public.fin_statement_lines l where l.entry_id = e.id) then raise exception 'fin_entry_reconciled'; end if;
  update public.fin_entries set status = 'open', settled_on = null, bank_account_id = null, updated_at = now() where id = e.id;
  perform private.fin_event(e.organization_id, e.id, 'settlement_undone', jsonb_build_object('was', e.settled_on), p_reason);
end
$$;
revoke all on function public.fin_undo_settlement(uuid, text) from public, anon;
grant execute on function public.fin_undo_settlement(uuid, text) to authenticated;

create or replace function public.fin_cancel_entry(p_entry uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare e public.fin_entries%rowtype;
begin
  select * into e from public.fin_entries where id = p_entry for update;
  if e.id is null or auth.uid() is null or not public.has_permission(e.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if e.status <> 'open' then raise exception 'fin_entry_not_open'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'reason_required'; end if;
  update public.fin_entries set status = 'cancelled', updated_at = now() where id = e.id;
  perform private.fin_event(e.organization_id, e.id, 'cancelled', '{}'::jsonb, p_reason);
end
$$;
revoke all on function public.fin_cancel_entry(uuid, text) from public, anon;
grant execute on function public.fin_cancel_entry(uuid, text) to authenticated;

-- Posting of the commission business into the company finance: a confirmed bank receipt is money in (a chargeback,
-- money out); a paid payout statement is money out. Settled on the date the money moved; the bank account comes later
-- from the statement reconciliation. Once per receipt or payout.
create or replace function private.fin_post_receipt(p_receipt uuid)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare x public.commission_receipts%rowtype; v_account uuid; v_key text; v_id uuid; v_ade text; v_bank text;
begin
  select * into x from public.commission_receipts where id = p_receipt;
  if x.id is null then return null; end if;
  if exists (select 1 from public.fin_entries e where e.organization_id = x.organization_id and e.source = 'commission_receipt' and e.source_ref = x.id and e.status <> 'cancelled') then return null; end if;
  perform private.fin_ensure_chart(x.organization_id);
  v_key := case when x.entry_kind = 'chargeback' then 'chargeback' when x.component_key = 'deferred' then 'commission_deferred' else 'commission_upfront' end;
  select id into v_account from public.fin_chart_accounts where organization_id = x.organization_id and system_key = v_key;
  select p.external_proposal_id, p.commercial_snapshot->>'bank' into v_ade, v_bank from public.proposals_v2 p where p.id = x.proposal_id;
  insert into public.fin_entries (organization_id, direction, status, description, account_id, counterpart, amount, due_on, competence_on, settled_on, source, source_ref, proposal_id, created_by)
  values (x.organization_id, case when x.entry_kind = 'chargeback' then 'out' else 'in' end, 'settled',
          left(case when x.entry_kind = 'chargeback' then 'Estorno de comissão' when x.component_key = 'deferred' then 'Comissão diferida parcela ' || coalesce(x.installment_number::text, '')
               else 'Comissão à vista' end || coalesce(' · ADE ' || v_ade, ''), 200),
          v_account, left(v_bank, 120), x.amount, coalesce(x.received_on, current_date), coalesce(x.received_on, current_date), coalesce(x.received_on, current_date),
          'commission_receipt', x.id, x.proposal_id, auth.uid())
  returning id into v_id;
  perform private.fin_event(x.organization_id, v_id, 'created', jsonb_build_object('source', 'commission_receipt'), null);
  return v_id;
end
$$;
revoke all on function private.fin_post_receipt(uuid) from public, anon, authenticated;

create or replace function private.fin_post_payout(p_payout uuid)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare y public.payouts%rowtype; v_account uuid; v_id uuid; v_name text;
begin
  select * into y from public.payouts where id = p_payout;
  if y.id is null or y.status not in ('paid') or coalesce(y.amount, 0) <= 0 then return null; end if;
  if exists (select 1 from public.fin_entries e where e.organization_id = y.organization_id and e.source = 'payout' and e.source_ref = y.id and e.status <> 'cancelled') then return null; end if;
  perform private.fin_ensure_chart(y.organization_id);
  select id into v_account from public.fin_chart_accounts where organization_id = y.organization_id and system_key = 'payout';
  select coalesce(s.name, (select u.email from auth.users u where u.id = a.user_id)) into v_name
  from public.payout_accounts a left join public.commercial_sellers s on s.id = a.seller_id where a.id = y.account_id;
  insert into public.fin_entries (organization_id, direction, status, description, account_id, counterpart, document, amount, due_on, competence_on, settled_on, source, source_ref, created_by)
  values (y.organization_id, 'out', 'settled', left('Repasse' || coalesce(' · ' || v_name, ''), 200), v_account, left(v_name, 120), left(y.payment_reference, 60),
          y.amount, coalesce(y.paid_on, current_date), coalesce(y.paid_on, current_date), coalesce(y.paid_on, current_date), 'payout', y.id, auth.uid())
  returning id into v_id;
  perform private.fin_event(y.organization_id, v_id, 'created', jsonb_build_object('source', 'payout'), null);
  return v_id;
end
$$;
revoke all on function private.fin_post_payout(uuid) from public, anon, authenticated;

create or replace function private.fin_auto_post_trigger()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if not coalesce((select s.auto_post from public.fin_settings s where s.organization_id = (to_jsonb(new)->>'organization_id')::uuid), true) then return null; end if;
  if tg_table_name = 'commission_receipts' then
    perform private.fin_post_receipt(new.id);
  elsif (to_jsonb(new)->>'status') = 'paid' and (tg_op = 'INSERT' or (to_jsonb(old)->>'status') is distinct from 'paid') then
    perform private.fin_post_payout(new.id);
  end if;
  return null;
end
$$;
revoke all on function private.fin_auto_post_trigger() from public, anon, authenticated;
create trigger commission_receipts_90_fin_post after insert on public.commission_receipts for each row execute function private.fin_auto_post_trigger();
create trigger payouts_90_fin_post after insert or update of status on public.payouts for each row execute function private.fin_auto_post_trigger();

-- Manual mode: what is still to be posted, and posting one item by hand.
create or replace function public.fin_pending_postings(p_org uuid)
returns table (kind text, source_ref uuid, happened_on date, description text, amount numeric, proposal_id uuid)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.view') then raise exception 'not_authorized'; end if;
  return query
    select 'commission_receipt'::text, x.id, x.received_on,
           (case when x.entry_kind = 'chargeback' then 'Estorno de comissão' when x.component_key = 'deferred' then 'Comissão diferida' else 'Comissão à vista' end)
             || coalesce(' · ADE ' || p.external_proposal_id, ''),
           case when x.entry_kind = 'chargeback' then -x.amount else x.amount end, x.proposal_id
    from public.commission_receipts x left join public.proposals_v2 p on p.id = x.proposal_id
    where x.organization_id = p_org
      and not exists (select 1 from public.fin_entries e where e.organization_id = p_org and e.source = 'commission_receipt' and e.source_ref = x.id and e.status <> 'cancelled')
    union all
    select 'payout', y.id, y.paid_on, 'Repasse pago', -y.amount, null::uuid
    from public.payouts y
    where y.organization_id = p_org and y.status = 'paid' and y.amount > 0
      and not exists (select 1 from public.fin_entries e where e.organization_id = p_org and e.source = 'payout' and e.source_ref = y.id and e.status <> 'cancelled')
    order by 3 desc nulls last;
end
$$;
revoke all on function public.fin_pending_postings(uuid) from public, anon;
grant execute on function public.fin_pending_postings(uuid) to authenticated;

create or replace function public.fin_post_pending(p_org uuid, p_kind text, p_ref uuid)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare v_id uuid;
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if p_kind = 'commission_receipt' then
    if not exists (select 1 from public.commission_receipts x where x.id = p_ref and x.organization_id = p_org) then raise exception 'not_authorized'; end if;
    v_id := private.fin_post_receipt(p_ref);
  elsif p_kind = 'payout' then
    if not exists (select 1 from public.payouts y where y.id = p_ref and y.organization_id = p_org) then raise exception 'not_authorized'; end if;
    v_id := private.fin_post_payout(p_ref);
  else
    raise exception 'fin_entry_invalid';
  end if;
  if v_id is null then raise exception 'fin_already_posted'; end if;
  return v_id;
end
$$;
revoke all on function public.fin_post_pending(uuid, text, uuid) from public, anon;
grant execute on function public.fin_post_pending(uuid, text, uuid) to authenticated;

-- Statement (OFX) import: the lines already parsed by the app (FITID, date, signed amount, memo). A line seen before
-- (same FITID in the account) is skipped.
create or replace function public.fin_import_statement(p_bank_account uuid, p_file_name text, p_file_sha256 text, p_lines jsonb)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare k public.fin_bank_accounts%rowtype; v_import uuid; l jsonb; v_count integer := 0;
begin
  select * into k from public.fin_bank_accounts where id = p_bank_account;
  if k.id is null or auth.uid() is null or not public.has_permission(k.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 1 or jsonb_array_length(p_lines) > 5000 then raise exception 'fin_statement_invalid'; end if;
  begin
    insert into public.fin_statement_imports (organization_id, bank_account_id, file_name, file_sha256, created_by)
    values (k.organization_id, k.id, left(btrim(coalesce(p_file_name, 'extrato.ofx')), 200), lower(coalesce(p_file_sha256, '')), auth.uid())
    returning id into v_import;
  exception
    when unique_violation then raise exception 'fin_statement_already_imported';
    when check_violation then raise exception 'fin_statement_invalid';
  end;
  for l in select * from jsonb_array_elements(p_lines) loop
    begin
      insert into public.fin_statement_lines (organization_id, bank_account_id, import_id, fitid, posted_on, amount, memo)
      values (k.organization_id, k.id, v_import, left(btrim(l->>'fitid'), 80), (l->>'posted_on')::date, (l->>'amount')::numeric(15,2), left(nullif(btrim(coalesce(l->>'memo', '')), ''), 200))
      on conflict (bank_account_id, fitid) do nothing;
      if found then v_count := v_count + 1; end if;
    exception when others then raise exception 'fin_statement_invalid';
    end;
  end loop;
  update public.fin_statement_imports set line_count = v_count where id = v_import;
  return v_import;
end
$$;
revoke all on function public.fin_import_statement(uuid, text, text, jsonb) from public, anon;
grant execute on function public.fin_import_statement(uuid, text, text, jsonb) to authenticated;

-- Reconcile a statement line with an entry of the same direction and amount: an open entry is settled on the line's
-- date and account; a settled one without account gets the account.
create or replace function public.fin_match_line(p_line uuid, p_entry uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare l public.fin_statement_lines%rowtype; e public.fin_entries%rowtype;
begin
  select * into l from public.fin_statement_lines where id = p_line for update;
  if l.id is null or auth.uid() is null or not public.has_permission(l.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if l.status <> 'pending' then raise exception 'fin_line_not_pending'; end if;
  select * into e from public.fin_entries where id = p_entry and organization_id = l.organization_id for update;
  if e.id is null or e.status = 'cancelled' then raise exception 'fin_entry_invalid'; end if;
  if (l.amount > 0) <> (e.direction = 'in') or abs(l.amount) <> e.amount then raise exception 'fin_match_amount'; end if;
  if e.status = 'settled' and e.bank_account_id is not null and e.bank_account_id <> l.bank_account_id then raise exception 'fin_match_other_account'; end if;
  if exists (select 1 from public.fin_statement_lines x where x.entry_id = e.id) then raise exception 'fin_entry_reconciled'; end if;
  if e.status = 'open' then
    update public.fin_entries set status = 'settled', settled_on = l.posted_on, bank_account_id = l.bank_account_id, updated_at = now() where id = e.id;
    perform private.fin_event(e.organization_id, e.id, 'settled', jsonb_build_object('on', l.posted_on, 'bank', l.bank_account_id), null);
  else
    update public.fin_entries set bank_account_id = l.bank_account_id, updated_at = now() where id = e.id;
  end if;
  update public.fin_statement_lines set status = 'matched', entry_id = e.id where id = l.id;
  perform private.fin_event(e.organization_id, e.id, 'reconciled', jsonb_build_object('line', l.id, 'posted_on', l.posted_on), null);
end
$$;
revoke all on function public.fin_match_line(uuid, uuid) from public, anon;
grant execute on function public.fin_match_line(uuid, uuid) to authenticated;

-- A statement line with no entry (a bank fee, an income nobody registered) becomes a settled entry of the chosen account.
create or replace function public.fin_entry_from_line(p_line uuid, p_account uuid, p_branch uuid, p_description text)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare l public.fin_statement_lines%rowtype; v_id uuid;
begin
  select * into l from public.fin_statement_lines where id = p_line for update;
  if l.id is null or auth.uid() is null or not public.has_permission(l.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if l.status <> 'pending' then raise exception 'fin_line_not_pending'; end if;
  perform private.fin_check_refs(l.organization_id, p_account, p_branch, l.bank_account_id);
  insert into public.fin_entries (organization_id, direction, status, description, account_id, branch_id, amount, due_on, competence_on, settled_on, bank_account_id, source, source_ref, created_by)
  values (l.organization_id, case when l.amount > 0 then 'in' else 'out' end, 'settled', left(coalesce(nullif(btrim(coalesce(p_description, '')), ''), l.memo, 'Lançamento do extrato'), 200),
          p_account, p_branch, abs(l.amount), l.posted_on, l.posted_on, l.posted_on, l.bank_account_id, 'statement', l.id, auth.uid())
  returning id into v_id;
  update public.fin_statement_lines set status = 'matched', entry_id = v_id where id = l.id;
  perform private.fin_event(l.organization_id, v_id, 'created', jsonb_build_object('source', 'statement'), null);
  return v_id;
end
$$;
revoke all on function public.fin_entry_from_line(uuid, uuid, uuid, text) from public, anon;
grant execute on function public.fin_entry_from_line(uuid, uuid, uuid, text) to authenticated;

create or replace function public.fin_ignore_line(p_line uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare l public.fin_statement_lines%rowtype;
begin
  select * into l from public.fin_statement_lines where id = p_line for update;
  if l.id is null or auth.uid() is null or not public.has_permission(l.organization_id, 'financeiro.edit') then raise exception 'not_authorized'; end if;
  if l.status <> 'pending' then raise exception 'fin_line_not_pending'; end if;
  update public.fin_statement_lines set status = 'ignored' where id = l.id;
end
$$;
revoke all on function public.fin_ignore_line(uuid) from public, anon;
grant execute on function public.fin_ignore_line(uuid) to authenticated;

-- Cash flow per month: realized (settled, by settlement date) and forecast (open, by due date).
create or replace function public.fin_cash_flow(p_org uuid, p_from date, p_to date, p_branch uuid default null)
returns table (month date, realized_in numeric, realized_out numeric, forecast_in numeric, forecast_out numeric)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.view') then raise exception 'not_authorized'; end if;
  return query
    with m as (select generate_series(date_trunc('month', p_from)::date, date_trunc('month', p_to)::date, interval '1 month')::date as month),
    e as (
      select date_trunc('month', coalesce(x.settled_on, x.due_on))::date as month, x.direction, x.status, x.amount
      from public.fin_entries x join public.fin_chart_accounts a on a.id = x.account_id
      where x.organization_id = p_org and x.status <> 'cancelled' and a.kind <> 'transfer'
        and coalesce(x.settled_on, x.due_on) between p_from and p_to and (p_branch is null or x.branch_id = p_branch)
    )
    select m.month,
           coalesce(sum(e.amount) filter (where e.status = 'settled' and e.direction = 'in'), 0),
           coalesce(sum(e.amount) filter (where e.status = 'settled' and e.direction = 'out'), 0),
           coalesce(sum(e.amount) filter (where e.status = 'open' and e.direction = 'in'), 0),
           coalesce(sum(e.amount) filter (where e.status = 'open' and e.direction = 'out'), 0)
    from m left join e on e.month = m.month
    group by m.month order by m.month;
end
$$;
revoke all on function public.fin_cash_flow(uuid, date, date, uuid) from public, anon;
grant execute on function public.fin_cash_flow(uuid, date, date, uuid) to authenticated;

-- Income statement by competence month and account (cancelled entries and transfers out). Values are signed as in the
-- statement: income positive, everything that reduces the result negative.
create or replace function public.fin_income_statement(p_org uuid, p_from date, p_to date, p_branch uuid default null)
returns table (month date, kind text, account_code text, account_name text, total numeric)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.view') then raise exception 'not_authorized'; end if;
  return query
    select date_trunc('month', x.competence_on)::date, a.kind, a.code, a.name,
           sum(case when x.direction = 'in' then x.amount else -x.amount end)
    from public.fin_entries x join public.fin_chart_accounts a on a.id = x.account_id
    where x.organization_id = p_org and x.status <> 'cancelled' and a.kind <> 'transfer'
      and x.competence_on between p_from and p_to and (p_branch is null or x.branch_id = p_branch)
    group by 1, 2, 3, 4
    order by 1, 3;
end
$$;
revoke all on function public.fin_income_statement(uuid, date, date, uuid) from public, anon;
grant execute on function public.fin_income_statement(uuid, date, date, uuid) to authenticated;

-- Balance of each bank account: opening balance plus what was settled in it since the opening date.
create or replace function public.fin_bank_balances(p_org uuid)
returns table (bank_account_id uuid, balance numeric, pending_lines integer)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or not public.has_permission(p_org, 'financeiro.view') then raise exception 'not_authorized'; end if;
  return query
    select k.id,
           k.opening_balance + coalesce((select sum(case when e.direction = 'in' then e.amount else -e.amount end) from public.fin_entries e
                                         where e.bank_account_id = k.id and e.status = 'settled' and e.settled_on >= k.opening_on), 0),
           (select count(*)::integer from public.fin_statement_lines l where l.bank_account_id = k.id and l.status = 'pending')
    from public.fin_bank_accounts k where k.organization_id = p_org;
end
$$;
revoke all on function public.fin_bank_balances(uuid) from public, anon;
grant execute on function public.fin_bank_balances(uuid) to authenticated;
