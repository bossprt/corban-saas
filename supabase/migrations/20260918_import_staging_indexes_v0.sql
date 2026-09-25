-- Import Staging V0 performance hardening.
create index if not exists import_sources_entity_idx on public.import_sources(source_entity_id);
create index if not exists import_batches_source_idx on public.import_batches(source_id);
create index if not exists import_batches_received_by_idx on public.import_batches(received_by);
create index if not exists import_match_org_idx on public.import_match_candidates(organization_id);
create index if not exists import_match_product_table_idx on public.import_match_candidates(product_table_id);
create index if not exists import_match_channel_idx on public.import_match_candidates(channel_id);
create index if not exists import_match_producer_idx on public.import_match_candidates(producer_entity_id);
create index if not exists import_decisions_org_idx on public.import_decisions(organization_id);
create index if not exists import_decisions_candidate_idx on public.import_decisions(candidate_id);
create index if not exists import_decisions_decided_by_idx on public.import_decisions(decided_by);
