-- pf3_batch2_ingest
-- Personal financials Phase 3 batch 2 ingest.
-- Covers: US Bank Tithe Tax (6755, personal b3333333),
--         AMEX Personal Cash Magnet (1006, personal b3333333),
--         Citi 1247 (Marie's card, PaperNewt b1111111).
-- 19 bank_transactions + 5 credit_transactions + 3 anchors + 1 COA seed + 1 last4 backfill.
-- RBFCU Savings + Capital One Personal 7435 deferred (Peter did not upload in this batch).
-- Agency-side extras (AMEX Discretionary, Chase Ink 7762, US Bank SF Card 3447) also uploaded
-- but deferred per batch 1 pattern (agency ledger already anchored 6/30).

BEGIN;

-- ============================================================
-- 1. last4 backfill on the two accounts still missing it
-- ============================================================
UPDATE public.bank_accounts
SET account_number_last4 = '6755', updated_at = NOW()
WHERE id = '261e4d80-04ff-4877-92d6-788b0909a24b'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_number_last4 IS NULL;

UPDATE public.credit_accounts
SET account_number_last4 = '1006', updated_at = NOW()
WHERE id = '50ba6422-c1a6-4e2b-bd5e-5c757fa86332'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_number_last4 IS NULL;

-- ============================================================
-- 2. COA seed for FK workaround
--    bank_transactions.bank_account_id targets chart_of_accounts.id (legacy misnaming).
--    Only Tithe Tax needs this — AMEX Personal + Citi are credit_transactions
--    which target credit_accounts.id correctly.
-- ============================================================
INSERT INTO public.chart_of_accounts
  (agency_id, chart_namespace, account_code, account_name, account_type, account_subtype, business_entity_id)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'active', 'PERSONAL-6755',
   'US Bank Tithe Tax', 'asset', 'bank', 'b3333333-3333-3333-3333-333333333333');

-- ============================================================
-- 3. Anchors (account_starting_balances)
-- ============================================================
INSERT INTO public.account_starting_balances
  (agency_id, account_last4, account_label, account_type, as_of_date, balance, source, business_entity_id)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', '6755', 'US Bank Tithe Tax ...6755',
   'checking', '2026-03-25', 25404.28,
   'personal_financials_phase3_batch2', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '1006', 'AMEX Personal Cash Magnet ...1006',
   'credit_card', '2026-04-17', -493.01,
   'personal_financials_phase3_batch2', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '1247', 'CITI Personal Card ...1247',
   'credit_card', '2026-04-06', 103.64,
   'personal_financials_phase3_batch2', 'b1111111-1111-1111-1111-111111111111');

-- ============================================================
-- 4. Bank transactions — Tithe Tax (6755), 19 rows
--    Sign convention: + = deposit/credit, - = withdrawal
--    bank_account_id is a scalar subquery to the seeded COA row.
-- ============================================================
INSERT INTO public.bank_transactions
  (agency_id, bank_account_id, transaction_date, description, amount,
   transaction_type, reference_number, posting_source, business_entity_id)
SELECT
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  (SELECT id FROM public.chart_of_accounts
    WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
      AND account_code='PERSONAL-6755'),
  d.transaction_date::date,
  d.description,
  d.amount::numeric,
  d.transaction_type,
  d.reference_number,
  'manual_batch_20260722'::text,
  'b3333333-3333-3333-3333-333333333333'::uuid
FROM (VALUES
  -- Cycle 26-04 (Mar 25 - Apr 23): 5 txns
  ('2026-04-03', 'Internet Banking Transfer From Account 212004766730',  603.22, 'deposit',    NULL::text),
  ('2026-04-03', 'Internet Banking Transfer From Account 212004766730',  650.10, 'deposit',    NULL),
  ('2026-04-03', 'Internet Banking Transfer From Account 212004766730', 2417.67, 'deposit',    NULL),
  ('2026-04-23', 'Interest Paid',                                          57.66, 'deposit',   '2300102943'),
  ('2026-04-06', 'Electronic Withdrawal To DISCOVER 2510020270E-PAYMENT 3208', -3566.38, 'withdrawal', '260960068750600N00'),

  -- Cycle 26-05 (Apr 24 - May 26): 7 txns
  ('2026-05-06', 'Internet Banking Transfer From Account 212004766730',  617.65, 'deposit',    NULL),
  ('2026-05-06', 'Internet Banking Transfer From Account 212004766730',  650.10, 'deposit',    NULL),
  ('2026-05-06', 'Internet Banking Transfer From Account 212004766730', 1970.58, 'deposit',    NULL),
  ('2026-05-06', 'Internet Banking Transfer From Account 212004766730', 2638.42, 'deposit',    NULL),
  ('2026-05-26', 'Interest Paid',                                          64.02, 'deposit',   '2600103934'),
  ('2026-05-07', 'Electronic Withdrawal To IRS USATAXPYMT3387702000',     -45.48, 'withdrawal','261270056680860N00'),
  ('2026-05-08', 'Electronic Withdrawal To DISCOVER 2510020270E-PAYMENT 3208', -5571.79, 'withdrawal', '261270148133620N00'),

  -- Cycle 26-06 (May 27 - Jun 24): 7 txns
  ('2026-05-27', 'Internet Banking Transfer From Account 212003144335', 2654.95, 'deposit',    NULL),
  ('2026-05-28', 'Internet Banking Transfer From Account 212004766730',  659.61, 'deposit',    NULL),
  ('2026-06-10', 'Internet Banking Transfer From Account 212004766730',  663.74, 'deposit',    NULL),
  ('2026-06-10', 'Internet Banking Transfer From Account 104797420353',  957.15, 'deposit',    NULL),
  ('2026-06-10', 'Internet Banking Transfer From Account 212004766730', 3228.09, 'deposit',    NULL),
  ('2026-06-24', 'Interest Paid',                                          64.92, 'deposit',   '2400105416'),
  ('2026-06-12', 'Electronic Withdrawal To DISCOVER 2510020270E-PAYMENT 3208', -3566.38, 'withdrawal', '261620138856060N00')
) AS d(transaction_date, description, amount, transaction_type, reference_number);

-- ============================================================
-- 5. Credit transactions — AMEX Personal (Cash Magnet 1006), 1 row
--    Sign convention: + = charge, - = payment
--    Credit Balance Refund posts as +$493.01 to bring the -$493.01 credit
--    balance up to $0.00 (matches AMEX statement sign).
-- ============================================================
INSERT INTO public.credit_transactions
  (agency_id, credit_account_id, transaction_date, description, amount,
   transaction_type, notes, business_entity_id)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365',
   '50ba6422-c1a6-4e2b-bd5e-5c757fa86332',
   '2026-06-19',
   'Credit Balance Refund',
   493.01,
   'charge',
   'AMEX Cash Rebate Refund; brings credit balance -$493.01 to $0.00; posting_source=manual_batch_20260722_cc',
   'b3333333-3333-3333-3333-333333333333');

-- ============================================================
-- 6. Credit transactions — Citi 1247 (Marie's, PaperNewt b1111111), 4 rows
-- ============================================================
INSERT INTO public.credit_transactions
  (agency_id, credit_account_id, transaction_date, description, amount,
   transaction_type, notes, business_entity_id)
VALUES
  -- Cycle 26-05 (Apr 7 - May 6): 1 txn
  ('126794dd-25ff-47d2-a436-724499733365',
   'b9af7f0c-06df-4e5a-9d93-9ac579d8f55e',
   '2026-05-02',
   'ONLINE PAYMENT, THANK YOU',
   -103.64,
   'payment',
   'posting_source=manual_batch_20260722_cc',
   'b1111111-1111-1111-1111-111111111111'),

  -- Cycle 26-06 (May 7 - Jun 4): 2 txns
  ('126794dd-25ff-47d2-a436-724499733365',
   'b9af7f0c-06df-4e5a-9d93-9ac579d8f55e',
   '2026-05-11',
   'ND4C HOUSTON TX',
   247.73,
   'charge',
   'posting_source=manual_batch_20260722_cc',
   'b1111111-1111-1111-1111-111111111111'),
  ('126794dd-25ff-47d2-a436-724499733365',
   'b9af7f0c-06df-4e5a-9d93-9ac579d8f55e',
   '2026-05-14',
   'ND4C HOUSTON TX',
   194.37,
   'charge',
   'posting_source=manual_batch_20260722_cc',
   'b1111111-1111-1111-1111-111111111111'),

  -- Cycle 26-07 (Jun 5 - Jul 6): 1 txn
  ('126794dd-25ff-47d2-a436-724499733365',
   'b9af7f0c-06df-4e5a-9d93-9ac579d8f55e',
   '2026-07-01',
   'ONLINE PAYMENT, THANK YOU',
   -442.10,
   'payment',
   'posting_source=manual_batch_20260722_cc',
   'b1111111-1111-1111-1111-111111111111');

COMMIT;
