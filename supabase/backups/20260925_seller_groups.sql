-- Backup of the ChatGPT-era second grouping of sellers, removed by migration seller_group_rules_v1 (owner decision 25/09/2026).
-- Taken from production (project nhjfrcttzxnphhizlnmc) before the removal: 1 group ("Padrão") and the only seller's link to it.
-- To restore (only if ever needed): recreate the table seller_groups and the column commercial_sellers.seller_group_id as in
-- supabase/migrations/20261007_seller_commercial_profile_v1.sql, then run the lines below.

insert into public.seller_groups select * from json_populate_record(null::public.seller_groups, '{"id":"0665990e-c17a-4e00-8cee-81fae4c53d73","organization_id":"62405e20-af29-4359-b39c-79c206146b6c","tech_key":"13ea2510f64544cb9a4b6f8e48b7b7fc","name":"Padrão","is_active":true,"sort_order":0,"created_by":"9917cdc3-bca0-4249-91a4-20fec75ef26a","created_at":"2026-09-21T16:37:43.663829+00:00","updated_at":"2026-09-21T16:37:43.663829+00:00"}');
update public.commercial_sellers set seller_group_id = '0665990e-c17a-4e00-8cee-81fae4c53d73' where id = '009adf01-9bcd-433b-b727-07113cbba6aa';
