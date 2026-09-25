-- Reference institutions may be banks, associations or fintechs.
-- An official banking code is therefore optional.
alter table public.banks alter column code drop not null;
