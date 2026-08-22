-- Ingest US Bank Tithe Tax (2-120-0476-6755) statements 26-01..26-07
-- Same pattern as KidsProfitDisc (6730) ingest earlier today.
-- All 7 periods chain: each close = next open. Verified from PDFs.
-- NOTE: Existing cutover snapshot ($12,145.46 @ 6/30/2026) LEFT IN PLACE.
--   Actual balance on 6/30/2026 = $30,552.13 (26-06 close Jun 24 = $30,552.13,
--   no transactions posted Jun 25-30 per 26-07 statement detail).
--   Delta = $18,406.67 short in book. Anchor reconciliation gated on Peter per
--   accounting rule "do not silently overwrite anchor".

INSERT INTO public.statement_balances
  (agency_id, business_entity_id, account_code, account_last4, account_kind,
   statement_period_start, statement_period_end, opening_balance, closing_balance,
   source, notes)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365',
   'b3333333-3333-3333-3333-333333333333',
   'COA-PERSONAL-6755', '6755', 'bank',
   '2025-12-24', '2026-01-27', 6997.61, 7005.98,
   'us_bank_tithe_tax_zip_20260727',
   'Parsed from 26-01 PDF. 35-day period straddles year-end. First statement of 2026.'),
  ('126794dd-25ff-47d2-a436-724499733365',
   'b3333333-3333-3333-3333-333333333333',
   'COA-PERSONAL-6755', '6755', 'bank',
   '2026-01-28', '2026-02-25', 7005.98, 9028.29,
   'us_bank_tithe_tax_zip_20260727',
   'Parsed from 26-02 PDF. Continuity ok with 26-01 close.'),
  ('126794dd-25ff-47d2-a436-724499733365',
   'b3333333-3333-3333-3333-333333333333',
   'COA-PERSONAL-6755', '6755', 'bank',
   '2026-02-26', '2026-03-24', 9028.29, 25404.28,
   'us_bank_tithe_tax_zip_20260727',
   'Parsed from 26-03 PDF. Continuity ok with 26-02 close. Large deposit month (+$16.4K net).'),
  ('126794dd-25ff-47d2-a436-724499733365',
   'b3333333-3333-3333-3333-333333333333',
   'COA-PERSONAL-6755', '6755', 'bank',
   '2026-03-25', '2026-04-23', 25404.28, 25566.55,
   'us_bank_tithe_tax_zip_20260727',
   'Parsed from 26-04 PDF. Continuity ok with 26-03 close.'),
  ('126794dd-25ff-47d2-a436-724499733365',
   'b3333333-3333-3333-3333-333333333333',
   'COA-PERSONAL-6755', '6755', 'bank',
   '2026-04-24', '2026-05-26', 25566.55, 25890.05,
   'us_bank_tithe_tax_zip_20260727',
   'Parsed from 26-05 PDF. Continuity ok with 26-04 close.'),
  ('126794dd-25ff-47d2-a436-724499733365',
   'b3333333-3333-3333-3333-333333333333',
   'COA-PERSONAL-6755', '6755', 'bank',
   '2026-05-27', '2026-06-24', 25890.05, 30552.13,
   'us_bank_tithe_tax_zip_20260727',
   'Parsed from 26-06 PDF. Continuity ok with 26-05 close. Actual balance at 6/30 cutover = $30,552.13 (no txns Jun 25-30 per 26-07 detail); book cutover snapshot shows $12,145.46 — $18,406.67 gap flagged.'),
  ('126794dd-25ff-47d2-a436-724499733365',
   'b3333333-3333-3333-3333-333333333333',
   'COA-PERSONAL-6755', '6755', 'bank',
   '2026-06-25', '2026-07-23', 30552.13, 30796.47,
   'us_bank_tithe_tax_zip_20260727',
   'Parsed from 26-07 PDF. Continuity ok with 26-06 close. Latest cycle on file.');

-- Mark the parent zip doc as processed
UPDATE public.documents
SET processing_status = 'processed',
    notes = 'unpacked 7 files; ingested via chat_upload — 7 statement_balances rows landed (Jan-Jul 2026), continuity verified. Cutover anchor gap flagged ($12,145.46 book vs $30,552.13 actual @ 6/30/2026 — reconciliation pending Peter).'
WHERE id = '53dce21e-e110-47a7-a551-1e2177ab2cab';
