-- PROSESP contracts imported from the WorkBank report on 05/10/2026 were registered with the WorkBank CONTRATO number
-- as their ADE, while the PROSESP commission report ("Acerto da Produção") and the contracts typed by hand use the
-- WorkBank PROPOSTA number. From now on the PROSESP layout reads PROPOSTA as the ADE (owner request 05/10/2026); this
-- adds the PROPOSTA number as a second identity of those 10 contracts, so commission reports match them by themselves
-- and a later import does not register them again. Nothing is changed or removed: only identities are added, under the
-- same bank key the contract already has. Elsewhere (no such contract) it adds nothing.

insert into public.proposal_external_identities (organization_id, proposal_id, institution_key, external_proposal_number, source, metadata)
select e.organization_id, e.proposal_id, e.institution_key, v.proposta, 'workbank_proposta',
       jsonb_build_object('contrato', v.contrato, 'note', 'Número da PROPOSTA do WorkBank (05/10/2026)')
from (values ('14462', '13939'), ('14465', '13942'), ('14471', '13950'), ('14472', '13949'), ('14477', '14955'),
             ('14478', '13956'), ('14482', '14960'), ('14483', '14961'), ('14486', '14967'), ('14493', '14973')) as v(contrato, proposta)
join public.proposal_external_identities e on e.external_proposal_number = v.contrato
join public.organization_banks b on b.organization_id = e.organization_id and b.tech_key = e.institution_key and b.name = 'PROSESP'
on conflict (organization_id, institution_key, external_proposal_number) do nothing;
