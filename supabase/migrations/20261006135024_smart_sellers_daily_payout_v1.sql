-- Smart Promotora: every seller receives the payout daily (owner request 06/10/2026). Only the field "Recebe o repasse"
-- (commercial_sellers.commission_payment_frequency) changes, for the sellers registered today; no statement, credit or
-- payment is touched. The default for sellers registered from now on stays as it is (monthly). Elsewhere it does nothing.

update public.commercial_sellers s
   set commission_payment_frequency = 'daily'
  from public.organizations o
 where o.id = s.organization_id
   and o.name = 'Smart Promotora Ltda.'
   and s.commission_payment_frequency is distinct from 'daily';
