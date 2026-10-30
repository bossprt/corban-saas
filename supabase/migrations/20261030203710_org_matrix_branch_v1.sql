-- CORBAN OS — every company has its "Matriz" (30/10/2026)
-- A seller saved without a branch goes to the company's active matrix (guard_seller_catalog_row raises
-- active_matrix_required otherwise). The matrix was created only by the 21/09 backfill, so a company created later
-- (MAIS VALOR, 08/10) had none and could not register any seller.
-- 1) the same backfill again for companies still without a matrix; 2) a new company is created with its matrix.
-- Additive only: nothing is changed or removed.

insert into public.organization_branches(organization_id,code,name,branch_type)
select o.id,'MATRIZ','Matriz','matrix'
from public.organizations o
where not exists(
  select 1 from public.organization_branches b
  where b.organization_id=o.id and b.branch_type='matrix'
);

create or replace function public.create_organization_matrix()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into public.organization_branches(organization_id,code,name,branch_type)
  values(new.id,'MATRIZ','Matriz','matrix')
  on conflict do nothing;
  return new;
end $$;
revoke all on function public.create_organization_matrix() from public, anon, authenticated;

create trigger organizations_create_matrix after insert on public.organizations
for each row execute function public.create_organization_matrix();
