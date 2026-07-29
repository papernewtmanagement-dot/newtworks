-- Parser year-inference bug: "US Bank Personal Checking 26-01.pdf" (Jan 2026 statement)
-- covers late-Dec 2025 through late-Jan 2026. Parser stamped the 12/26 GLOELE deposit
-- as 2026-12-26 instead of 2025-12-26.
--
-- A manual OBE-scrubbed JE at 2025-12-26 already exists (chat_backfill_0353_20260727)
-- as part of the pre-2026 P&L walk-forward — Peter chose to scrub pre-2026 activity to
-- Opening Balance Equity, not book as 2025 income.
--
-- Right fix: delete the parser-generated duplicate JE (booked as W2 income, wrong period),
-- correct the bank_transactions date, relink to the OBE-scrubbed JE for audit trail.

-- 1. Relink bank_transactions to the manual OBE-scrubbed JE + fix date (FK must move before delete).
UPDATE public.bank_transactions
SET transaction_date = '2025-12-26',
    journal_entry_id = 'daf6da4e-6b4e-4e66-a12a-cb5a82ce6683',
    posting_source = 'chat_backfill_reconciled',
    notes = COALESCE(notes, '') || ' [2026-07-29: corrected 2026-12-26 → 2025-12-26 parser year-inference bug; relinked to OBE-scrubbed manual JE]'
WHERE id = 'c2b0f7ac-5283-438d-9870-64ea84471331';

-- 2. Now safe to delete the parser-generated JE lines and the JE itself.
DELETE FROM public.journal_lines WHERE journal_entry_id = '23f180ea-4c33-44fc-af9d-c12b6414b607';
DELETE FROM public.journal_entries WHERE id = '23f180ea-4c33-44fc-af9d-c12b6414b607';
