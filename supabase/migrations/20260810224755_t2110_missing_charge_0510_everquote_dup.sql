-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-10 22:47:55 UTC (ledger name: t2110_missing_charge_0510_everquote_dup) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260810224755.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
INSERT INTO public.statements
  (id, agency_id, business_entity_id, account_id, account_kind,
   transaction_date, description, amount, transaction_type,
   source_document_id, notes)
SELECT gen_random_uuid(), '126794dd-25ff-47d2-a436-724499733365',
       a.business_entity_id, a.id, 'credit',
       '2026-05-10', 'EVERQUOTE, INC PRO.EVERQUOTE MA', 250.00, 'charge',
       '24f32c40-3ccf-40df-a537-de71b0caa768', 'Diagnostic rule (b) — Chase CC 26-05.pdf prints TWO separate 05/10 EVERQUOTE $250.00 charges; only one was in statements. Verified by direct PDF read.'
FROM public.accounts a
WHERE a.agency_id='126794dd-25ff-47d2-a436-724499733365' AND a.account_number_last4='7762';
