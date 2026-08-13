-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-04 23:34:02 UTC (ledger name: add_fidelity_hsa_bank_account) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260804233402.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Fidelity HSA statement routing. chart_of_accounts 1400 "HSA (Fidelity)"
-- already existed with no activity and no account record, so nothing could
-- route a Fidelity statement to it. account_number_last4 is left NULL on
-- purpose: the number is inside the PDFs and has not been read yet. The
-- resolver matches this row by institution/name instead.
INSERT INTO public.bank_accounts
  (agency_id, account_name, institution, account_type, is_active,
   business_entity_id, chart_account_id, created_at, updated_at)
SELECT '126794dd-25ff-47d2-a436-724499733365',
       'Fidelity HSA', 'Fidelity', 'savings', true,
       coa.business_entity_id, coa.id, now(), now()
FROM public.chart_of_accounts coa
WHERE coa.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND coa.account_code = '1400'
  AND NOT EXISTS (
    SELECT 1 FROM public.bank_accounts ba
    WHERE ba.agency_id = '126794dd-25ff-47d2-a436-724499733365'
      AND ba.chart_account_id = coa.id
  );
