-- pf3_batch2b_ingest
-- Personal financials Phase 3 batch 2b ingest.
-- Covers the two accounts that were staged in documents table (from Alvi's 2026-07-22 20:14 CT email zip)
-- but never actually posted through the LLM parse pipeline.
--
-- Landed here manually:
-- - RBFCU Primary Savings 220516596 (b3333333, savings) -- 3 cycles Apr/May/Jun 2026
-- - Capital One Quicksilver Personal 7435 (b3333333, credit) -- 3 cycles Mar 29 - Jun 27 2026,
--   two-cardholder card (Peter #7435 primary + Marie #4780 supplementary).
--
-- Also fixes the stale document rows: mark all 6 as processed and close the 4 open llm_parse_queue rows.

BEGIN;

-- ============================================================
-- 1. last4 backfill
-- ============================================================
UPDATE public.bank_accounts
SET account_number_last4 = '6596', updated_at = NOW()
WHERE id = 'b6d516fc-6038-4528-beac-0c7cd1df8543'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_number_last4 IS NULL;

-- Capital One 7435 already has account_number_last4 set (backfilled 2026-07-16).

-- ============================================================
-- 2. COA seed for FK workaround (RBFCU bank account only; Cap One credit uses credit_accounts FK)
-- ============================================================
INSERT INTO public.chart_of_accounts
  (agency_id, chart_namespace, account_code, account_name, account_type, account_subtype, business_entity_id)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'active', 'PERSONAL-6596',
   'RBFCU Primary Savings', 'asset', 'bank', 'b3333333-3333-3333-3333-333333333333');

-- ============================================================
-- 3. Anchors
-- ============================================================
INSERT INTO public.account_starting_balances
  (agency_id, account_last4, account_label, account_type, as_of_date, balance, source, business_entity_id)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', '6596', 'RBFCU Primary Savings ...6596',
   'checking', '2026-03-31', 328.89,
   'personal_financials_phase3_batch2b', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '7435', 'Capital One Quicksilver Personal ...7435',
   'credit_card', '2026-03-28', 2165.58,
   'personal_financials_phase3_batch2b', 'b3333333-3333-3333-3333-333333333333');

-- ============================================================
-- 4. RBFCU bank_transactions (5 rows)
-- ============================================================
INSERT INTO public.bank_transactions
  (agency_id, bank_account_id, transaction_date, description, amount,
   transaction_type, reference_number, posting_source, business_entity_id)
SELECT
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  (SELECT id FROM public.chart_of_accounts
    WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND account_code='PERSONAL-6596'),
  d.transaction_date::date, d.description, d.amount::numeric,
  d.transaction_type, NULL::text, 'manual_batch_20260722b'::text,
  'b3333333-3333-3333-3333-333333333333'::uuid
FROM (VALUES
  -- Cycle 26-04 (04/01-04/30)
  ('2026-04-30', 'Deposit',   2000.00, 'deposit'),
  ('2026-04-30', 'Dividend',     0.10, 'deposit'),
  -- Cycle 26-05 (05/01-05/31)
  ('2026-05-14', 'ACH W/D CAPITAL ONE - ONLINE PMT', -2300.00, 'withdrawal'),
  ('2026-05-31', 'Dividend',      0.25, 'deposit'),
  -- Cycle 26-06 (06/01-06/30)
  ('2026-06-30', 'Dividend',      0.01, 'deposit')
) AS d(transaction_date, description, amount, transaction_type);


-- ============================================================
-- 5. Capital One credit_transactions (138 rows across 3 cycles)
--    Sign convention: + = charge, - = payment/credit/refund
--    transaction_date = statement Post Date (batch 1 convention)
--    Cardholder + refund/pmt flag captured in notes for downstream classification
-- ============================================================
INSERT INTO public.credit_transactions
  (agency_id, credit_account_id, transaction_date, description, amount,
   transaction_type, notes, business_entity_id)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-20', 'CAPITAL ONE ONLINE PYMT', -2165.58, 'payment', 'cardholder:Peter J Story section:payments trans_date:2026-04-20 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-03', 'AMAZON MKTPLACE PMTSAmzn.com/billWA', -38.96, 'payment', 'cardholder:Marie T Story section:payments trans_date:2026-04-02 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-03-30', 'AMAZON MKTPL*B58D24HS0Amzn.com/billWA', 7.57, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-03-28 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-03-30', 'Amazon.com*B56280IU1Amzn.com/billWA', 21.91, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-03-28 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-03-30', 'SAMS CLUB.COM800-966-6546AR', 10.00, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-03-28 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-03-30', 'AMAZON MKTPL*B53J442P0Amzn.com/billWA', 16.24, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-03-29 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-01', 'Amazon.com*BG6X41PB1Amzn.com/billWA', 29.44, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-03-31 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-02', 'SANANTONIOEXPERTTAEKWWWW.SAEXPERTTVA', 175.64, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-01 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-02', 'AMAZON MKTPL*BC70H6UR2Amzn.com/billWA', 12.98, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-01 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-02', 'Amazon.com*BG9B635J1Amzn.com/billWA', 27.05, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-01 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-02', 'AMAZON MKTPL*BC43L4UO2Amzn.com/billWA', 43.26, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-01 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-02', 'Champions Cheer183-0438309TX', 152.00, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-01 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-02', 'AMAZON MKTPL*BG9KU7BO1Amzn.com/billWA', 12.99, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-01 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-04', 'Amazon.com*BG8HX69Y1Amzn.com/billWA', 26.00, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-03 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-04', 'HEB CURBSIDE800-432-3113TX', 175.92, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-03 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-06', 'Amazon.com*BC6UH8FP1Amzn.com/billWA', 23.80, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-04 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-06', 'DAVIDS LAWN SERVICESmariapaulafueTX', 59.54, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-04 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-08', 'STATE FARM INSURANCE800-956-6310IL', 95.27, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-07 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-08', 'BEXAR VEHREG210-335-6554TX', 83.50, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-07 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-08', 'TEXAS.GOV*SERVICEFEE-R512-936-2644TX', 2.00, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-07 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-08', 'SP SAFERINGZSAFERINGZ.COMAZ', 92.01, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-08 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-09', 'STATE FARM INSURANCE800-956-6310IL', 1120.00, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-08 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-13', 'SAMS CLUB.COM800-966-6546AR', 10.00, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-10 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-13', 'AMAZON MKTPL*BC4IL6KN0Amzn.com/billWA', 24.89, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-11 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-13', 'SAMS CLUB.COM800-966-6546AR', 2.12, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-11 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-14', 'AMAZON MKTPL*B700U4VN1Amzn.com/billWA', 68.87, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-13 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-14', 'AMAZON MKTPL*B78T29L70Amzn.com/billWA', 27.99, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-13 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-18', 'Dons Tropical Pets andSan AntonioTX', 21.08, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-18 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-18', 'AMAZON MKTPL*BS8604552Amzn.com/billWA', 18.39, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-18 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-20', 'AMAZON MKTPL*BS6FD16K2Amzn.com/billWA', 16.23, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-19 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-21', 'AMAZON MKTPL*BS1TV8RG2Amzn.com/billWA', 40.03, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-21 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-22', 'CCM*CINCH HOME SERVICE866-229-4584FL', 52.99, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-21 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-23', 'LIVE OAK PERIODONTICSSAN ANTONIOTX', 1673.60, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-22 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-23', 'H-E-B #108SAN ANTONIOTX', 22.72, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-22 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-23', 'AMAZON MKTPL*BY5D37MC0Amzn.com/billWA', 17.05, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-23 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-23', 'AMAZON MKTPL*BJ3VW1JL2Amzn.com/billWA', 12.65, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-23 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-23', 'AMAZON MKTPL*BY91W5MG0Amzn.com/billWA', 50.95, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-23 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-23', 'AMAZON MKTPL*BS3RY6481Amzn.com/billWA', 38.24, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-23 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-23', 'AMAZON MKTPL*BY6NW7ML0Amzn.com/billWA', 11.95, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-23 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-23', 'AMAZON MKTPL*BJ3VE9J72Amzn.com/billWA', 57.80, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-23 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-23', 'Amazon.com*BJ7J58JE2Amzn.com/billWA', 6.43, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-23 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-23', 'AMAZON MKTPL*BY67K8MD0Amzn.com/billWA', 22.94, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-23 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-23', 'AMAZON MKTPL*BJ72F7J62Amzn.com/billWA', 52.70, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-23 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-27', 'Amazon.com*BS9YL2P01Amzn.com/billWA', 38.94, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-25 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-27', 'Amazon.com*BJ6KK5SJ2Amzn.com/billWA', 24.79, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-26 cycle:26-04; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-13', 'CAPITAL ONE ONLINE PYMT', -2300.00, 'payment', 'cardholder:Peter J Story section:payments trans_date:2026-05-13 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-18', 'CAPITAL ONE ONLINE PYMT', -2161.51, 'payment', 'cardholder:Peter J Story section:payments trans_date:2026-05-18 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-04', 'HEB CURBSIDESAN ANTONIOTX', -1.16, 'payment', 'cardholder:Marie T Story section:payments trans_date:2026-05-01 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-04-28', 'PURE MANA CBD512-8973442TX', 50.89, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-27 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-02', 'SAMSCLUB.COM888-746-7726AR', 55.96, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-04-30 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-02', 'SANANTONIOEXPERTTAEKWWWW.SAEXPERTTVA', 175.64, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-01 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-02', 'HEB CURBSIDE800-432-3113TX', 6.61, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-01 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-05', 'AMAZON MKTPL*BV5OG0O71Amzn.com/billWA', 21.64, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-04 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-05', 'AMAZON MKTPL*BV7SO2O71Amzn.com/billWA', 20.42, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-05 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-06', 'AMAZON MKTPL*BF73R0OZ2Amzn.com/billWA', 21.64, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-05 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-06', 'STATE FARM INSURANCE800-956-6310IL', 95.27, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-05 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-07', 'AMAZON MKTPL*BV1SY0TH1Amzn.com/billWA', 18.39, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-06 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-07', 'AMAZON MKTPL*BV1LA9AZ1Amzn.com/billWA', 32.46, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-06 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-08', 'AMAZON MKTPL*BF76R51W2Amzn.com/billWA', 10.81, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-07 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-08', 'AMAZON MKTPL*BJ55C3990Amzn.com/billWA', 35.71, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-07 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-08', 'AMAZON MKTPL*BF3FJ71B2Amzn.com/billWA', 10.80, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-07 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-08', 'AMAZON MKTPL*BF8CT31R2Amzn.com/billWA', 21.64, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-07 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-11', 'SAMS CLUB.COM800-966-6546AR', 205.03, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-08 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-11', 'AMAZON MKTPL*BV6GU53V0Amzn.com/billWA', 9.99, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-09 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-11', 'Google TV650-2530000CA', 1.15, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-10 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-11', 'Amazon.com*BV1HG8RQ1Amzn.com/billWA', 25.53, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-10 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-11', 'AMAZON MKTPL*BV4YR6YV1Amzn.com/billWA', 7.57, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-10 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-12', 'AMAZON MKTPL*BV4188P10Amzn.com/billWA', 9.87, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-11 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-12', 'AMAZON MKTPL*BV67N6VD0Amzn.com/billWA', 14.06, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-11 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-13', 'Amazon.com*BF6BG8GP1Amzn.com/billWA', 10.81, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-12 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-18', 'Google TV650-2530000CA', 3.82, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-17 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-18', 'AMAZON MKTPL*JR0L25393Amzn.com/billWA', 10.38, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-18 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-21', 'AMAZON MKTPL*HI7TC1WA3Amzn.com/billWA', 13.81, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-20 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-21', 'AMAZON MKTPL*P22K74X83Amzn.com/billWA', 7.57, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-20 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-21', 'AMAZON MKTPL*OH8Q607N3Amzn.com/billWA', 10.81, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-20 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-21', 'SAMS CLUB #4914800-925-6278TX', 55.73, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-20 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-21', 'PLAYSTATION800-345-7669CA', 10.83, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-21 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-22', 'AMAZON MKTPL*CY8CI9B83Amzn.com/billWA', 8.65, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-21 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-22', 'CCM*CINCH HOME SERVICE866-229-4584FL', 52.99, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-21 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-23', 'TPC DENTAL CARE PCSAN ANTONIOTX', 67.20, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-21 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-23', 'AMAZON MKTPL*OB4AG4MZ3Amzn.com/billWA', 7.57, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-22 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-23', 'Amazon.com*9F6AW0I43Amzn.com/billWA', 50.00, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-23 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-25', 'AMAZON MKTPL*2Y8V774X3Amzn.com/billWA', 32.19, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-23 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-25', 'PLAYSTATION800-345-7669CA', 20.83, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-24 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-25', 'AMAZON MKTPL*4B21Q9SX3Amzn.com/billWA', 24.97, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-24 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-26', 'AMAZON MKTPL*ST2Q023D3Amzn.com/billWA', 10.81, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-25 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-28', 'AMAZON MKTPL*N619Y2UL3Amzn.com/billWA', 37.88, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-27 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-28', 'Amazon.com*KY2EJ6823Amzn.com/billWA', 15.14, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-28 cycle:26-05; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-15', 'CAPITAL ONE ONLINE PYMT', -1301.91, 'payment', 'cardholder:Peter J Story section:payments trans_date:2026-06-15 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-15', 'HEB CURBSIDESAN ANTONIOTX', -7.87, 'payment', 'cardholder:Marie T Story section:payments trans_date:2026-06-12 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-05-30', 'HEB CURBSIDE800-432-3113TX', 15.65, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-29 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-01', 'AMAZON MKTPL*E25E406S3Amzn.com/billWA', 10.81, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-31 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-01', 'AMAZON MKTPL*8Q4Q79YH3Amzn.com/billWA', 15.51, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-31 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-01', 'AMAZON MKTPL*1T3UB3MG3Amzn.com/billWA', 52.70, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-31 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-01', 'Amazon.com*6T8YP14C3Amzn.com/billWA', 57.37, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-31 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-01', 'AMAZON MKTPL*WQ81N2TX3Amzn.com/billWA', 16.29, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-31 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-01', 'Amazon.com*WI11V1H83Amzn.com/billWA', 14.67, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-31 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-01', 'AMAZON MKTPL*T17V16JL3Amzn.com/billWA', 20.35, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-31 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-01', 'AMAZON MKTPL*FP3SB8S53Amzn.com/billWA', 23.33, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-05-31 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-01', 'Amazon.com*2S1H61OV3Amzn.com/billWA', 24.79, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-01 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-02', 'SANANTONIOEXPERTTAEKWWWW.SAEXPERTTVA', 175.64, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-01 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-02', 'AMAZON MKTPL*572MA4W53Amzn.com/billWA', 48.70, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-01 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-02', 'ROVER.COM* PET SVCS.WWW.ROVER.COMWA', 190.36, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-01 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-02', 'AMAZON MKTPL*PZ1XX7M13Amzn.com/billWA', 10.81, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-01 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-02', 'AMAZON MKTPL*NI6YS4DR3Amzn.com/billWA', 31.95, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-02 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-03', 'Amazon.com*HN4DZ69T3Amzn.com/billWA', 15.14, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-02 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-03', 'LIVE OAK PERIODONTICSSAN ANTONIOTX', 133.00, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-02 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-04', 'SAMSCLUB.COM888-746-7726AR', 57.07, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-02 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-04', 'Amazon.com*3A6XL6I23Amzn.com/billWA', 16.01, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-03 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-04', 'AMAZON MKTPL*L76301E83Amzn.com/billWA', 21.64, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-03 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-05', 'AMAZON MKTPL*JS4131ND3Amzn.com/billWA', 21.21, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-04 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-05', 'BUCK AND DOE''S MERCANTILESAN ANTONIOTX', 20.78, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-04 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-06', 'STATE FARM INSURANCE800-956-6310IL', 95.27, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-05 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-08', 'SAMS CLUB.COM800-966-6546AR', 26.12, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-05 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-06', 'Dons Tropical Pets andSan AntonioTX', 3.24, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-06 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-09', 'AMAZON MKTPL*KA69P15S3Amzn.com/billWA', 53.95, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-08 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-10', 'REPUBLIC SERVICES TRASHHTTP://WWW.PHAZ', 78.47, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-09 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-13', 'HEB CURBSIDE800-432-3113TX', 163.86, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-12 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-15', 'AMAZON MKTPL*B80E19Y03Amzn.com/billWA', 25.71, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-13 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-15', 'AMAZON MKTPL*VA6TB9V73Amzn.com/billWA', 70.12, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-13 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-15', 'GOOGLE*TVSUPPORT.GOOGLCA', 1.88, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-14 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-17', 'Amazon.com*FX9BM0663Amzn.com/billWA', 36.74, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-16 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-17', 'SAMSCLUB #4914SAN ANTONIOTX', 53.03, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-16 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-18', 'Dons Tropical Pets andSan AntonioTX', 2.15, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-17 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-19', 'BUCK AND DOE''S MERCANTILESAN ANTONIOTX', 20.97, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-18 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-22', 'AMAZON MKTPL*XE3770FV3Amzn.com/billWA', 12.98, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-20 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-23', 'CCM*CINCH HOME SERVICE866-229-4584FL', 52.99, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-22 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-26', 'ROVER.COM* PET SVCS.WWW.ROVER.COMWA', 20.00, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-25 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-26', 'Amazon.com*335AZ6DL3Amzn.com/billWA', 6.43, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-25 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-26', 'Amazon.com*859WC52J3Amzn.com/billWA', 4.67, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-25 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-26', 'AMAZON MKTPL*D91HR21E3Amzn.com/billWA', 15.51, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-25 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-26', 'AMAZON MKTPL*478677MB3Amzn.com/billWA', 57.80, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-25 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-26', 'Amazon.com*3S1T79NL3Amzn.com/billWA', 9.21, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-25 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-26', 'AMAZON MKTPL*EA1MW6CW3Amzn.com/billWA', 50.95, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-25 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-26', 'AMAZON MKTPL*8P0587PM3Amzn.com/billWA', 24.89, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-25 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-26', 'AMAZON MKTPL*K19BX8QT3Amzn.com/billWA', 20.35, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-25 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-26', 'AMAZON MKTPL*B21NE2UK3Amzn.com/billWA', 15.58, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-25 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333'),
  ('126794dd-25ff-47d2-a436-724499733365', '0ed39c01-7280-446f-ab3b-a6e11e5e8cca', '2026-06-27', 'SAMS CLUB.COM800-966-6546AR', 10.00, 'charge', 'cardholder:Marie T Story section:purchases trans_date:2026-06-26 cycle:26-06; posting_source=manual_batch_20260722b_cc', 'b3333333-3333-3333-3333-333333333333');

-- ============================================================
-- 6. Housekeeping: close out the pipeline docs so they don't sit in queued_for_llm forever
-- ============================================================
UPDATE public.documents
SET processing_status = 'filed',
    processed_at = NOW(),
    notes = COALESCE(notes,'') || ' | posted via pf3_batch2b_ingest (manual path)'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND id IN (
    '1f84fd45-98ef-409e-9311-98dde986590b',  -- RBFCU 26-04
    'b98890cd-32a5-44da-9efa-f0852ea7abf3',  -- RBFCU 26-05
    'cdad8278-342e-4bc9-9a5b-fcaa11abc429',  -- RBFCU 26-06
    '0dfbc74b-0556-4ac5-80ee-5662717968a4',  -- Cap One 26-04
    '90e9dcfd-4ee7-4a34-9342-bc92c82b3962',  -- Cap One 26-05
    '4730f48c-e9d3-46d7-b16d-76ae0115baac'   -- Cap One 26-06 (already filed on 7/16, add note)
  );

UPDATE public.llm_parse_queue
SET status = 'obsolete',
    completed_at = NOW(),
    last_error = 'Superseded by manual pf3_batch2b_ingest 2026-07-22'
WHERE document_id IN (
    '1f84fd45-98ef-409e-9311-98dde986590b',
    'b98890cd-32a5-44da-9efa-f0852ea7abf3',
    'cdad8278-342e-4bc9-9a5b-fcaa11abc429',
    '0dfbc74b-0556-4ac5-80ee-5662717968a4',
    '90e9dcfd-4ee7-4a34-9342-bc92c82b3962'
  )
  AND status = 'pending';

COMMIT;
