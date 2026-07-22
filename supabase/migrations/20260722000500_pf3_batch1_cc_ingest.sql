-- ============================================================
-- Personal financials Phase 3 batch 1 CREDIT-SIDE ingest
-- Entity: Peter Story personal (b3333333)
-- Account: US Bank Personal CC ...8847 (1ba6196f-b0f7-470e-84a0-4061166adddf)
-- Anchor confirmed 2026-07-22 via Marie (Apr 7 statement Previous Balance = $536.48)
-- 14 transactions + 1 anchor. All 4 cycles reconcile: 26-04 536.48, 26-05 546.15, 26-06 984.41, 26-07 113.00
-- Sign convention: + = charge/purchase, - = payment/credit (natural balance direction)
-- ============================================================

-- 14 credit_transactions
INSERT INTO public.credit_transactions (
  agency_id, credit_account_id, business_entity_id,
  transaction_date, description, amount, transaction_type,
  posted_at, notes
) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', '1ba6196f-b0f7-470e-84a0-4061166adddf', 'b3333333-3333-3333-3333-333333333333', DATE '2026-03-18', 'STATE FARM INSURANCE', 64.41, 'charge', ('2026-03-18'::date)::timestamptz, 'ref 2948; posting_source=manual_batch_20260721_cc'),
  ('126794dd-25ff-47d2-a436-724499733365', '1ba6196f-b0f7-470e-84a0-4061166adddf', 'b3333333-3333-3333-3333-333333333333', DATE '2026-03-18', 'STATE FARM INSURANCE', 113.00, 'charge', ('2026-03-18'::date)::timestamptz, 'ref 2342; posting_source=manual_batch_20260721_cc'),
  ('126794dd-25ff-47d2-a436-724499733365', '1ba6196f-b0f7-470e-84a0-4061166adddf', 'b3333333-3333-3333-3333-333333333333', DATE '2026-03-18', 'STATE FARM INSURANCE', 73.72, 'charge', ('2026-03-18'::date)::timestamptz, 'ref 0693; posting_source=manual_batch_20260721_cc'),
  ('126794dd-25ff-47d2-a436-724499733365', '1ba6196f-b0f7-470e-84a0-4061166adddf', 'b3333333-3333-3333-3333-333333333333', DATE '2026-03-18', 'STATE FARM INSURANCE', 285.35, 'charge', ('2026-03-18'::date)::timestamptz, 'ref 3915; posting_source=manual_batch_20260721_cc'),
  ('126794dd-25ff-47d2-a436-724499733365', '1ba6196f-b0f7-470e-84a0-4061166adddf', 'b3333333-3333-3333-3333-333333333333', DATE '2026-03-23', 'MOBILE PAYMENT THANK YOU', -536.48, 'payment', ('2026-03-23'::date)::timestamptz, 'posting_source=manual_batch_20260721_cc'),
  ('126794dd-25ff-47d2-a436-724499733365', '1ba6196f-b0f7-470e-84a0-4061166adddf', 'b3333333-3333-3333-3333-333333333333', DATE '2026-04-17', 'STATE FARM INSURANCE', 113.00, 'charge', ('2026-04-17'::date)::timestamptz, 'ref 7845; trans 2026-04-16; posting_source=manual_batch_20260721_cc'),
  ('126794dd-25ff-47d2-a436-724499733365', '1ba6196f-b0f7-470e-84a0-4061166adddf', 'b3333333-3333-3333-3333-333333333333', DATE '2026-04-20', 'STATE FARM INSURANCE', 433.15, 'charge', ('2026-04-20'::date)::timestamptz, 'ref 5198; trans 2026-04-17; posting_source=manual_batch_20260721_cc'),
  ('126794dd-25ff-47d2-a436-724499733365', '1ba6196f-b0f7-470e-84a0-4061166adddf', 'b3333333-3333-3333-3333-333333333333', DATE '2026-05-01', 'PAYMENT THANK YOU', -536.48, 'payment', ('2026-05-01'::date)::timestamptz, 'posting_source=manual_batch_20260721_cc'),
  ('126794dd-25ff-47d2-a436-724499733365', '1ba6196f-b0f7-470e-84a0-4061166adddf', 'b3333333-3333-3333-3333-333333333333', DATE '2026-05-18', 'STATE FARM INSURANCE', 113.00, 'charge', ('2026-05-18'::date)::timestamptz, 'ref 2979; trans 2026-05-16; posting_source=manual_batch_20260721_cc'),
  ('126794dd-25ff-47d2-a436-724499733365', '1ba6196f-b0f7-470e-84a0-4061166adddf', 'b3333333-3333-3333-3333-333333333333', DATE '2026-05-18', 'STATE FARM INSURANCE', 285.35, 'charge', ('2026-05-18'::date)::timestamptz, 'ref 1601; posting_source=manual_batch_20260721_cc'),
  ('126794dd-25ff-47d2-a436-724499733365', '1ba6196f-b0f7-470e-84a0-4061166adddf', 'b3333333-3333-3333-3333-333333333333', DATE '2026-05-29', 'STATE FARM INSURANCE', 586.06, 'charge', ('2026-05-29'::date)::timestamptz, 'ref 9276; trans 2026-05-28; posting_source=manual_batch_20260721_cc'),
  ('126794dd-25ff-47d2-a436-724499733365', '1ba6196f-b0f7-470e-84a0-4061166adddf', 'b3333333-3333-3333-3333-333333333333', DATE '2026-06-01', 'MOBILE PAYMENT THANK YOU', -546.15, 'payment', ('2026-06-01'::date)::timestamptz, 'posting_source=manual_batch_20260721_cc'),
  ('126794dd-25ff-47d2-a436-724499733365', '1ba6196f-b0f7-470e-84a0-4061166adddf', 'b3333333-3333-3333-3333-333333333333', DATE '2026-06-17', 'STATE FARM INSURANCE', 113.00, 'charge', ('2026-06-17'::date)::timestamptz, 'ref 5586; trans 2026-06-16; posting_source=manual_batch_20260721_cc'),
  ('126794dd-25ff-47d2-a436-724499733365', '1ba6196f-b0f7-470e-84a0-4061166adddf', 'b3333333-3333-3333-3333-333333333333', DATE '2026-07-01', 'INTERNET PAYMENT THANK YOU', -984.41, 'payment', ('2026-07-01'::date)::timestamptz, 'posting_source=manual_batch_20260721_cc')
;

-- Anchor
INSERT INTO public.account_starting_balances (
  agency_id, account_last4, account_label, account_type,
  as_of_date, balance, source, business_entity_id, notes
) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', '8847', 'US Bank Personal CC ...8847', 'credit_card', DATE '2026-03-07', 536.48, 'personal_financials_phase3_batch1', 'b3333333-3333-3333-3333-333333333333', 'Anchor confirmed 2026-07-22 by Marie from Apr 7 2026 statement Previous Balance line')
;
