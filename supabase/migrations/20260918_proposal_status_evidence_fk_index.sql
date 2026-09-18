-- CORBAN OS V2 — proposal_status_evidence FK performance patch
create index if not exists proposal_status_evidence_created_by_idx
on public.proposal_status_evidence(created_by);
