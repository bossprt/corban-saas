-- Payment batches (owner request 13/10/2026, like the NASP "Lotes de pagamento de comissões"): every confirmation of
-- seller payments is kept as one batch (date, proof, who paid, how many, total), with its detail and "Desfazer lote",
-- so a wrong confirmation is undone at once instead of one seller at a time.
--
-- * payout_batches: one row per confirmation. Written only by the functions below; readable by who sees Repasse.
-- * payouts.batch_id: set by a trigger when a payout becomes paid. "Confirmar pagos" (pay_account_in_batch) passes the
--   batch the screen opened; any other payment (pay one person, mark one paid) gets a batch of its own.
-- * reverse_payout_batch: undoes every payment still paid in the batch through reverse_payout (ADR-0057), all or none.
-- * Past payments: grouped into batches by who paid, date, proof and minute (a confirmation pays all its sellers within
--   seconds); the batch is "desfeito" when all its payments were undone. Payout rows are immutable: the guard opens one
--   door, batch_id from empty, under a flag only this migration and the batch trigger use.

create table public.payout_batches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  paid_on date not null,
  payment_reference text check (payment_reference is null or length(payment_reference) <= 120),
  origin text not null check (origin in ('batch', 'single', 'backfill')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  reversed_by uuid references auth.users(id) on delete set null,
  reversed_at timestamptz,
  reversal_reason text check (reversal_reason is null or length(btrim(reversal_reason)) between 3 and 300),
  constraint payout_batches_reversal_shape check ((reversed_at is null) = (reversal_reason is null))
);
create index payout_batches_org_idx on public.payout_batches (organization_id, paid_on desc, created_at desc);

alter table public.payout_batches enable row level security;
revoke all on table public.payout_batches from anon, authenticated;
grant select on public.payout_batches to authenticated;
create policy payout_batches_select on public.payout_batches for select to authenticated
  using (public.has_permission(organization_id, 'repasse.view'));

alter table public.payouts add column batch_id uuid references public.payout_batches(id) on delete restrict;
create index payouts_batch_idx on public.payouts (batch_id) where batch_id is not null;

-- The payout guard (as in 20261013230214_payout_reversal_v1), plus: batch_id is written only once, from empty, by the
-- batch trigger (a new payment) or by the one-time link of past payments below; never by a caller.
create or replace function public.guard_payout_write()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if current_setting('corban.payout_rpc', true) is distinct from 'on' then raise exception 'payout_write_requires_governed_rpc'; end if;
  if tg_op = 'DELETE' then raise exception 'payout_records_are_not_deletable'; end if;
  if tg_op = 'UPDATE' then
    if tg_table_name = 'payout_entries' then
      -- Only the approval decision (once) and the statement link may change.
      if (to_jsonb(new) - array['status','decided_by','decided_at','decision_note','statement_id'])
         is distinct from (to_jsonb(old) - array['status','decided_by','decided_at','decision_note','statement_id']) then
        raise exception 'payout_entry_is_immutable';
      end if;
      if new.status is distinct from old.status and not (old.status = 'pending' and new.status in ('approved','rejected')) then
        raise exception 'payout_entry_decision_is_final';
      end if;
    elsif tg_table_name = 'payouts' then
      if new.batch_id is distinct from old.batch_id then
        if old.batch_id is null and current_setting('corban.payout_batch_link', true) = 'on'
           and (to_jsonb(new) - 'batch_id') is not distinct from (to_jsonb(old) - 'batch_id') then
          return new;
        end if;
        raise exception 'payout_is_immutable';
      end if;
      if old.status = 'paid' and new.status = 'reversed' and current_setting('corban.payout_reverse_rpc', true) = 'on' then
        if (to_jsonb(new) - array['status','reversed_by','reversed_at','reversal_reason'])
           is distinct from (to_jsonb(old) - array['status','reversed_by','reversed_at','reversal_reason']) then
          raise exception 'payout_is_immutable';
        end if;
        return new;
      end if;
      if old.status in ('paid','settled','cancelled','reversed') then raise exception 'payout_is_closed'; end if;
      if (to_jsonb(new) - array['status','approved_by','approved_at','paid_by','paid_at','paid_on','payment_reference','cancelled_by','cancelled_at','note'])
         is distinct from (to_jsonb(old) - array['status','approved_by','approved_at','paid_by','paid_at','paid_on','payment_reference','cancelled_by','cancelled_at','note']) then
        raise exception 'payout_is_immutable';
      end if;
    elsif tg_table_name = 'payout_accounts' then
      if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id or new.seller_id is distinct from old.seller_id or new.user_id is distinct from old.user_id then
        raise exception 'payout_account_holder_is_immutable';
      end if;
    end if;
  end if;
  return new;
end
$function$;

-- Runs after the guard (which compares the columns the caller changed), when a payout becomes paid.
create or replace function private.payout_batch_on_paid()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare v_batch uuid := nullif(current_setting('corban.payout_batch', true), '')::uuid;
begin
  if new.status <> 'paid' or (tg_op = 'UPDATE' and old.status = 'paid') or new.batch_id is not null then return new; end if;
  if v_batch is not null then
    insert into public.payout_batches (id, organization_id, paid_on, payment_reference, origin, created_by)
    values (v_batch, new.organization_id, new.paid_on, new.payment_reference, 'batch', auth.uid())
    on conflict (id) do nothing;
    if not exists (select 1 from public.payout_batches b where b.id = v_batch and b.organization_id = new.organization_id
                   and b.created_by is not distinct from auth.uid() and b.reversed_at is null and b.created_at > now() - interval '1 day') then
      raise exception 'invalid_payout_batch';
    end if;
  else
    insert into public.payout_batches (organization_id, paid_on, payment_reference, origin, created_by)
    values (new.organization_id, new.paid_on, new.payment_reference, 'single', auth.uid())
    returning id into v_batch;
  end if;
  new.batch_id := v_batch;
  return new;
end
$$;

create trigger payouts_05_batch before insert or update on public.payouts
  for each row execute function private.payout_batch_on_paid();

-- "Confirmar pagos": the same check and payment as pay_account_now_checked, inside the batch the screen opened.
create or replace function public.pay_account_in_batch(p_account uuid, p_paid_on date, p_reference text, p_expected numeric, p_batch uuid)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare v_id uuid;
begin
  if p_batch is null then raise exception 'invalid_payout_batch'; end if;
  perform set_config('corban.payout_batch', p_batch::text, true);
  v_id := public.pay_account_now_checked(p_account, p_paid_on, p_reference, p_expected);
  perform set_config('corban.payout_batch', '', true);
  return v_id;
end
$$;

revoke all on function public.pay_account_in_batch(uuid, date, text, numeric, uuid) from public, anon;
grant execute on function public.pay_account_in_batch(uuid, date, text, numeric, uuid) to authenticated;

-- Undo a whole batch: every payment of it that is still paid, all or none (each through reverse_payout).
create or replace function public.reverse_payout_batch(p_batch uuid, p_reason text)
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  b public.payout_batches%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  n integer := 0;
  r record;
begin
  select * into b from public.payout_batches where id = p_batch for update;
  if b.id is null or auth.uid() is null or not public.has_active_organization_role(b.organization_id, array['admin']) then
    raise exception 'not_authorized';
  end if;
  if b.reversed_at is not null then raise exception 'batch_already_reversed'; end if;
  if length(v_reason) not between 3 and 300 then raise exception 'reason_required'; end if;
  for r in select p.id from public.payouts p where p.batch_id = b.id and p.status = 'paid' order by p.requested_at desc loop
    perform public.reverse_payout(r.id, v_reason);
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'batch_nothing_to_reverse'; end if;
  update public.payout_batches set reversed_by = auth.uid(), reversed_at = now(), reversal_reason = v_reason where id = b.id;
  return n;
end
$$;

revoke all on function public.reverse_payout_batch(uuid, text) from public, anon;
grant execute on function public.reverse_payout_batch(uuid, text) to authenticated;

-- Holder of a payout account, in words.
create or replace function private.payout_holder_name(p_account uuid)
returns text
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(s.name, (select coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), u.email) from auth.users u where u.id = a.user_id), 'Conta')
  from public.payout_accounts a left join public.commercial_sellers s on s.id = a.seller_id where a.id = p_account
$$;
revoke all on function private.payout_holder_name(uuid) from public, anon, authenticated;

-- The batches of the company, newest first, with totals (money as text: exact decimals for the screen).
create or replace function public.payout_batch_list(p_org uuid, p_limit integer default 200)
returns table (id uuid, paid_on date, payment_reference text, origin text, created_at timestamptz, paid_by text, payouts integer,
               total text, undone integer, bank_accounts text, reversed_at timestamptz, reversal_reason text)
language plpgsql
stable
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or not public.has_permission(p_org, 'repasse.view') then raise exception 'not_authorized'; end if;
  return query
  select b.id, b.paid_on, b.payment_reference, b.origin, b.created_at,
         (select coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), u.email) from auth.users u where u.id = b.created_by),
         count(p.id)::integer, coalesce(sum(p.amount), 0)::text, count(p.id) filter (where p.status = 'reversed')::integer,
         (select string_agg(distinct coalesce(nullif(a.label, ''), a.bank_name), ', ') from public.fin_entries f join public.fin_bank_accounts a on a.id = f.bank_account_id
          where f.organization_id = b.organization_id and f.source = 'payout' and f.source_ref in (select x.id from public.payouts x where x.batch_id = b.id)),
         b.reversed_at, b.reversal_reason
  from public.payout_batches b
  left join public.payouts p on p.batch_id = b.id
  where b.organization_id = p_org
  group by b.id
  having count(p.id) > 0
  order by b.paid_on desc, b.created_at desc
  limit least(greatest(coalesce(p_limit, 200), 1), 1000);
end
$$;
revoke all on function public.payout_batch_list(uuid, integer) from public, anon;
grant execute on function public.payout_batch_list(uuid, integer) to authenticated;

-- One batch: header and one line per payment, with the contracts a closing paid (ADE, client, amount).
create or replace function public.payout_batch_detail(p_batch uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $$
declare b public.payout_batches%rowtype;
begin
  select * into b from public.payout_batches where id = p_batch;
  if b.id is null or auth.uid() is null or not public.has_permission(b.organization_id, 'repasse.view') then raise exception 'not_authorized'; end if;
  return jsonb_build_object(
    'id', b.id, 'paid_on', b.paid_on, 'payment_reference', b.payment_reference, 'origin', b.origin, 'created_at', b.created_at,
    'paid_by', (select coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), u.email) from auth.users u where u.id = b.created_by),
    'reversed_at', b.reversed_at, 'reversal_reason', b.reversal_reason,
    'total', (select coalesce(sum(x.amount), 0)::text from public.payouts x where x.batch_id = b.id),
    'reversed_by', (select coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), u.email) from auth.users u where u.id = b.reversed_by),
    'bank_accounts', (select string_agg(distinct coalesce(nullif(a.label, ''), a.bank_name), ', ') from public.fin_entries f join public.fin_bank_accounts a on a.id = f.bank_account_id
                      where f.organization_id = b.organization_id and f.source = 'payout' and f.source_ref in (select x.id from public.payouts x where x.batch_id = b.id)),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
        'payout_id', p.id, 'account_id', p.account_id, 'holder', private.payout_holder_name(p.account_id), 'kind', p.kind,
        'amount', p.amount::text, 'status', p.status, 'reversal_reason', p.reversal_reason,
        'contracts', coalesce((
          -- One line per contract: its commission, chargebacks and adjustments in this payment, added up.
          select jsonb_agg(jsonb_build_object('proposal_id', c.proposal_id, 'ade', c.ade, 'client', c.client, 'amount', c.amount::text) order by c.ade)
          from (select e.proposal_id, pr.external_proposal_id as ade, pr.customer_snapshot->>'full_name' as client, sum(e.amount) as amount
                from public.payout_entries e join public.proposals_v2 pr on pr.id = e.proposal_id
                where e.statement_id = p.id and e.kind in ('commission', 'chargeback', 'adjustment') and e.status = 'approved'
                group by e.proposal_id, pr.external_proposal_id, pr.customer_snapshot->>'full_name') c), '[]'::jsonb)
      ) order by private.payout_holder_name(p.account_id))
      from public.payouts p where p.batch_id = b.id), '[]'::jsonb));
end
$$;
revoke all on function public.payout_batch_detail(uuid) from public, anon;
grant execute on function public.payout_batch_detail(uuid) to authenticated;

-- Past payments into batches (one time), through the guard's one-time batch link.
do $$
declare g record; v_batch uuid;
begin
  perform set_config('corban.payout_rpc', 'on', true);
  perform set_config('corban.payout_batch_link', 'on', true);
  for g in
    select p.organization_id, p.paid_by, coalesce(p.paid_on, (p.paid_at at time zone 'America/Sao_Paulo')::date) as paid_on, p.payment_reference,
           date_trunc('minute', p.paid_at) as minute,
           array_agg(p.id) as ids, min(p.paid_at) as first_paid, bool_and(p.status = 'reversed') as all_reversed,
           max(p.reversed_at) as reversed_at, min(p.reversal_reason) as reason,
           (array_agg(p.reversed_by order by p.reversed_at desc nulls last))[1] as reversed_by
    from public.payouts p
    where p.batch_id is null and p.status in ('paid', 'reversed') and p.paid_at is not null
    group by 1, 2, 3, 4, 5
  loop
    insert into public.payout_batches (organization_id, paid_on, payment_reference, origin, created_by, created_at,
                                       reversed_by, reversed_at, reversal_reason)
    values (g.organization_id, g.paid_on, g.payment_reference, 'backfill', g.paid_by, g.first_paid,
            case when g.all_reversed then g.reversed_by end, case when g.all_reversed then g.reversed_at end,
            case when g.all_reversed then g.reason end)
    returning id into v_batch;
    update public.payouts set batch_id = v_batch where id = any (g.ids);
  end loop;
  perform set_config('corban.payout_batch_link', 'off', true);
  perform set_config('corban.payout_rpc', 'off', true);
end
$$;
