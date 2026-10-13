-- "Desfazer pagamento" (owner request 13/10/2026): a seller payment registered in Corban but not made in the bank.
--
-- Nothing is deleted; every step is a compensation recorded with who, when and why:
--   * the payout becomes "reversed" (new status) with reversed_by, reversed_at and the reason;
--   * the entries that payout closed (statement_id) are released, so the next payment closes them again;
--   * an approved credit equal to the payout ("Pagamento desfeito: <reason>") offsets the payout debit in the person's
--     statement; it is linked to the reversed payout (statement_id), so no later closing counts it twice;
--   * the bank outflow the payment created in the company finance (fin_entries, source payout) is cancelled, with the
--     reason in its history.
-- Administrators only. Only a paid payout, the last one of the account, whose bank outflow was not reconciled with a
-- bank statement line (then the money did leave). The contracts of a reversed closing go back to "not paid to the
-- seller", because that status reads the payout of each commission entry.

alter table public.payouts
  add column reversed_by uuid references auth.users(id) on delete set null,
  add column reversed_at timestamptz,
  add column reversal_reason text check (reversal_reason is null or length(btrim(reversal_reason)) between 3 and 300);

alter table public.payouts drop constraint payouts_status_check;
alter table public.payouts add constraint payouts_status_check
  check (status = any (array['pending', 'approved', 'paid', 'settled', 'cancelled', 'reversed']));
alter table public.payouts add constraint payouts_reversal_shape
  check ((status = 'reversed') = (reversed_at is not null and reversal_reason is not null));

-- Same guard, plus one door: a paid payout may become reversed, through reverse_payout only, changing nothing else.
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

create or replace function public.reverse_payout(p_payout uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  p public.payouts%rowtype;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_today date := (now() at time zone 'America/Sao_Paulo')::date;
  f record;
begin
  select * into p from public.payouts where id = p_payout for update;
  if p.id is null or auth.uid() is null or not public.has_active_organization_role(p.organization_id, array['admin']) then
    raise exception 'not_authorized';
  end if;
  if p.status <> 'paid' then raise exception 'payout_not_paid'; end if;
  if length(v_reason) not between 3 and 300 then raise exception 'reason_required'; end if;
  perform 1 from public.payout_accounts where id = p.account_id for update;
  if exists (select 1 from public.payouts x where x.account_id = p.account_id and x.id <> p.id
             and x.status in ('pending', 'approved', 'paid', 'settled') and x.requested_at > p.requested_at) then
    raise exception 'later_payout_exists';
  end if;
  if exists (select 1 from public.fin_entries e join public.fin_statement_lines l on l.entry_id = e.id
             where e.organization_id = p.organization_id and e.source = 'payout' and e.source_ref = p.id and e.status <> 'cancelled') then
    raise exception 'payout_reconciled';
  end if;

  perform set_config('corban.payout_rpc', 'on', true);
  perform set_config('corban.payout_reverse_rpc', 'on', true);
  update public.payouts set status = 'reversed', reversed_by = auth.uid(), reversed_at = now(), reversal_reason = v_reason where id = p.id;
  perform set_config('corban.payout_reverse_rpc', 'off', true);

  -- The entries this closing took are open again for the next payment.
  update public.payout_entries set statement_id = null where statement_id = p.id;

  -- The payout debit stays in the statement; this credit offsets it.
  if p.amount > 0 then
    insert into public.payout_entries (organization_id, account_id, kind, amount, effective_on, description, status, created_by,
                                       decided_by, decided_at, decision_note, statement_id, payout_id)
    values (p.organization_id, p.account_id, 'adjustment', p.amount, v_today, left('Pagamento desfeito: ' || v_reason, 200), 'approved', auth.uid(),
            auth.uid(), now(), 'Desfazer pagamento', p.id, p.id);
  end if;
  perform set_config('corban.payout_rpc', 'off', true);

  -- The bank outflow never happened.
  for f in select e.id from public.fin_entries e
           where e.organization_id = p.organization_id and e.source = 'payout' and e.source_ref = p.id and e.status <> 'cancelled' for update
  loop
    update public.fin_entries set status = 'cancelled', settled_on = null, updated_at = now() where id = f.id;
    perform private.fin_event(p.organization_id, f.id, 'cancelled', jsonb_build_object('source', 'payout_reversal'), v_reason);
  end loop;
end
$$;

revoke all on function public.reverse_payout(uuid, text) from public, anon;
grant execute on function public.reverse_payout(uuid, text) to authenticated;
