-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-10 22:46:45 UTC (ledger name: t1_chase_2110_payments_2602_thru_2606) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260810224645.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
WITH acct AS (
  SELECT a.id, a.business_entity_id FROM public.accounts a
  WHERE a.agency_id='126794dd-25ff-47d2-a436-724499733365' AND a.account_number_last4='7762'
),
rows(txn_date, amt, doc_id, note) AS (
  VALUES
    ('2026-02-13'::date, -2499.48, '03bb225e-d00d-4383-a33a-9f947d3f00f7'::uuid, 'Task 1, period 1/23-2/22/26'),
    ('2026-03-13'::date, -2703.80, 'a97621ca-a764-429c-89c0-ce7b704fd654'::uuid, 'Task 1, period 2/23-3/22/26'),
    ('2026-04-15'::date, -3162.56, '234ded0f-2116-4e20-853a-e12ec2e25832'::uuid, 'Task 1, period 3/23-4/22/26'),
    ('2026-05-13'::date, -4844.24, '24f32c40-3ccf-40df-a537-de71b0caa768'::uuid, 'Task 1, period 4/23-5/22/26'),
    ('2026-06-15'::date, -4986.04, 'f26f0020-7590-45c8-9469-029e889c95e7'::uuid, 'Task 1, period 5/23-6/22/26')
)
INSERT INTO public.statements
  (id, agency_id, business_entity_id, account_id, account_kind,
   transaction_date, description, amount, transaction_type,
   source_document_id, notes)
SELECT gen_random_uuid(), '126794dd-25ff-47d2-a436-724499733365',
       acct.business_entity_id, acct.id, 'credit',
       rows.txn_date, 'Payment Thank You - Web', rows.amt, 'payment',
       rows.doc_id, rows.note
FROM rows, acct;
