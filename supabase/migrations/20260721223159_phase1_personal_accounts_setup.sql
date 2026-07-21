-- Phase 1: Personal accounts setup
-- Applied 2026-07-21 via Supabase MCP.
--
-- Purpose: wire up personal-side accounts (Peter Story entity b3333333) and
-- correct the two "SF Card" agency rows to their true institution (State-Farm-
-- branded US Bank, not SFFCU).
--
-- Peter directive 2026-07-21: full build of personal financials, starting with
-- entity + account setup. Follow-on phases handle opening-balance anchors,
-- transaction ingest from Alvi's 2026-07-20 statement batch, and doc-processor
-- routing for personal statements.

BEGIN;

-- A. Fix institution + last4 on the two agency SF-branded US Bank cards
--    (stay on agency b2222222; used for agency business, mislabeled SFFCU)
UPDATE public.credit_accounts
SET institution = 'US Bank (State Farm-branded)',
    account_number_last4 = '4676',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_name = 'SF Card - Expenses, Peter';

UPDATE public.credit_accounts
SET institution = 'US Bank (State Farm-branded)',
    account_number_last4 = '3439',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_name = 'SF Card - Expenses, Alvi';

-- B. Move Capital One Personal (7435) Agency -> Personal
UPDATE public.credit_accounts
SET business_entity_id = 'b3333333-3333-3333-3333-333333333333',
    chart_account_id = NULL,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_name = 'Capital One Personal Card'
  AND account_number_last4 = '7435';

-- B. Move CITI 1247 Agency -> PaperNewt (personal-owned card, 100% used for
--    PaperNewt printing charges; lives on PaperNewt entity for accounting)
UPDATE public.credit_accounts
SET business_entity_id = 'b1111111-1111-1111-1111-111111111111',
    chart_account_id = NULL,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_name = 'CITI Personal Card'
  AND account_number_last4 = '1247';

-- C. Create 5 personal bank accounts on Personal (b3333333)
INSERT INTO public.bank_accounts (agency_id, business_entity_id, account_name, institution, account_type, is_active)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', v.account_name, v.institution, v.account_type, true
FROM (VALUES
  ('US Bank Personal Checking', 'US Bank', 'checking'),
  ('US Bank Kids Profit Disc', 'US Bank', 'savings'),
  ('US Bank Other Income', 'US Bank', 'checking'),
  ('US Bank Tithe Tax', 'US Bank', 'savings'),
  ('RBFCU Savings', 'Randolph-Brooks Federal Credit Union', 'savings')
) AS v(account_name, institution, account_type)
WHERE NOT EXISTS (
  SELECT 1 FROM public.bank_accounts b
  WHERE b.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND b.business_entity_id = 'b3333333-3333-3333-3333-333333333333'
    AND b.account_name = v.account_name
);

-- C. Create 2 personal credit cards on Personal (b3333333)
INSERT INTO public.credit_accounts (agency_id, business_entity_id, account_name, institution, account_type, account_number_last4, is_active)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333', v.account_name, v.institution, v.account_type, v.account_number_last4, true
FROM (VALUES
  ('US Bank Personal CC', 'US Bank (State Farm-branded)', 'credit_card', '8847'),
  ('AMEX Personal', 'American Express', 'credit_card', NULL)
) AS v(account_name, institution, account_type, account_number_last4)
WHERE NOT EXISTS (
  SELECT 1 FROM public.credit_accounts c
  WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND c.business_entity_id = 'b3333333-3333-3333-3333-333333333333'
    AND c.account_name = v.account_name
);

COMMIT;
