-- Accent-insensitive "Buscar" on the company entries list (owner approval 05/11/2026): "ficticia" finds "Fictícia".
-- fold_text lowercases and removes Portuguese accents with translate(), so it is immutable without the unaccent extension.
-- search_text is a stored generated column: written by the database itself, never by the app, and covered by the
-- table's existing select grant and RLS. Adding it does not touch any financial value or event.
create or replace function public.fold_text(p text) returns text
language sql immutable parallel safe set search_path = ''
as $$
  select lower(translate(coalesce(p, ''),
    'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑáàâãäéèêëíìîïóòôõöúùûüçñ',
    'AAAAAEEEEIIIIOOOOOUUUUCNaaaaaeeeeiiiiooooouuuucn'))
$$;
revoke all on function public.fold_text(text) from public, anon;
grant execute on function public.fold_text(text) to authenticated;

alter table public.fin_entries add column search_text text
  generated always as (public.fold_text(coalesce(description, '') || ' ' || coalesce(counterpart, '') || ' ' || coalesce(document, ''))) stored;
