-- CORBAN OS V2 — Import Source Financial Semantics V0
-- PREPARED ONLY. Requires explicit Human Gate before production apply.
-- Persists evidence meaning at source level so adapters/UI cannot silently reinterpret a file.

alter table public.import_sources add column if not exists financial_semantic text not null default 'commercial_offer'
 check(financial_semantic in ('commercial_offer','production_report','commission_statement','payment_statement','network_payment_statement'));
alter table public.import_sources add column if not exists financial_semantic_reviewed_by uuid references auth.users(id);
alter table public.import_sources add column if not exists financial_semantic_reviewed_at timestamptz;

create index if not exists import_sources_semantic_reviewed_by_idx on public.import_sources(financial_semantic_reviewed_by);

create or replace function public.freeze_import_source_financial_semantic()
returns trigger language plpgsql set search_path=public as $$
begin
 if old.financial_semantic is distinct from new.financial_semantic and exists(select 1 from public.import_batches where source_id=old.id) then
  raise exception 'source_financial_semantic_in_use';
 end if;
 return new;
end $$;
drop trigger if exists import_sources_financial_semantic_freeze on public.import_sources;
create trigger import_sources_financial_semantic_freeze before update on public.import_sources for each row execute function public.freeze_import_source_financial_semantic();
revoke all on function public.freeze_import_source_financial_semantic() from public,anon,authenticated;
