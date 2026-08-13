-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-10 22:47:23 UTC (ledger name: t2110_missing_charge_1222_quotewizard) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260810224723.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
INSERT INTO public.statements
  (id, agency_id, business_entity_id, account_id, account_kind,
   transaction_date, description, amount, transaction_type,
   source_document_id, notes)
SELECT gen_random_uuid(), '126794dd-25ff-47d2-a436-724499733365',
       a.business_entity_id, a.id, 'credit',
       '2025-12-22', 'QUOTEWIZARD 877-9166344 WA', 250.00, 'charge',
       '4aa907fe-d989-476b-984b-20e2539f34fe', 'Diagnostic rule (b) — printed on Chase CC 26-01.pdf, absent from statements, verified by direct PDF read'
FROM public.accounts a
WHERE a.agency_id='126794dd-25ff-47d2-a436-724499733365' AND a.account_number_last4='7762';
