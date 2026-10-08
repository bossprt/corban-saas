-- Cancel a proposal that has not entered the typing queue yet (owner request 08/10/2026).
--
-- "Venda fechada" in Vendas creates the proposal from the negotiated simulation; until it enters the typing queue
-- (operational case) it is not on the Esteira board, so the board's "Cancelada" stage cannot reach it. This lets the
-- creator, or an admin/manager/supervisor who can see it, cancel it with a reason. History is kept: the proposal is
-- never deleted, it becomes "cancelled" (allowed by guard_proposal_status_transition) and the reason is a contract
-- note. The lead follows as for any cancelled proposal (back to Negotiating, private.leads_follow_proposal).
-- Contract: tests/security/cancel-proposal-before-queue-contract.sql

create or replace function public.cancel_proposal_before_queue(p_proposal uuid, p_reason text)
returns void language plpgsql security definer set search_path to '' as $$
declare p public.proposals_v2%rowtype;
begin
  select * into p from public.proposals_v2 where id = p_proposal for update;
  if p.id is null or auth.uid() is null or not public.is_active_organization_member(p.organization_id)
     or not private.can_see_proposal_row(p.organization_id, p.seller_id, p.created_by) then raise exception 'not_authorized'; end if;
  if p.created_by is distinct from auth.uid()
     and not public.has_active_organization_role(p.organization_id, array['admin','manager','supervisor']) then raise exception 'not_authorized'; end if;
  if p.status not in ('draft', 'documents_pending', 'ready_for_digitization')
     or exists (select 1 from public.operational_cases c where c.proposal_id = p.id) then raise exception 'proposal_already_in_queue'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 or length(p_reason) > 300 then raise exception 'cancel_reason_required'; end if;

  perform set_config('corban.proposal_rpc', 'on', true);
  update public.proposals_v2 set status = 'cancelled', updated_at = now() where id = p.id;
  perform set_config('corban.proposal_rpc', 'off', true);
  perform set_config('corban.contract_rpc', 'on', true);
  insert into public.contract_events (organization_id, proposal_id, kind, reason, actor_user_id)
  values (p.organization_id, p.id, 'note', 'Cancelada antes da fila de digitação: ' || btrim(p_reason), auth.uid());
  perform set_config('corban.contract_rpc', 'off', true);
end
$$;

revoke all on function public.cancel_proposal_before_queue(uuid, text) from public, anon;
grant execute on function public.cancel_proposal_before_queue(uuid, text) to authenticated;
