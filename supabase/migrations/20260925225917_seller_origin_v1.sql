-- Where each seller came from (owner decision 25/09/2026): registered in Corban, or imported from another system
-- (the first import is the 2tech seller list). Only the origin is kept from the old system; the date says when.
alter table public.commercial_sellers
  add column origin text not null default 'manual' check (origin in ('manual', 'import:2tech')),
  add column imported_at timestamptz,
  add constraint commercial_sellers_import_date check ((origin = 'manual') = (imported_at is null));
