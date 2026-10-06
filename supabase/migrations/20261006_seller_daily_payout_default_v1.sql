-- New sellers receive the payout daily unless the form says otherwise (owner request 06/10/2026): the default of
-- "Recebe o repasse" moves from monthly to daily. Existing sellers are not touched.
alter table public.commercial_sellers alter column commission_payment_frequency set default 'daily';
