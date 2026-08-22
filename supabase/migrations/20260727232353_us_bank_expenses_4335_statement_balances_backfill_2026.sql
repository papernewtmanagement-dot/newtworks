-- US Bank Expenses (4335 / COA-006) — replace awaiting_statement placeholder
-- with 6 real statement rows for 2026 (26-01 through 26-06), driving the
-- Financials Bank tab "ending number" for this account.

-- 1) Drop the placeholder row
DELETE FROM public.statement_balances
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  AND account_code = 'COA-006'
  AND source = 'awaiting_statement';

-- 2) Insert 6 real statement rows (26-01 through 26-06)
INSERT INTO public.statement_balances
  (agency_id, business_entity_id, account_code, account_last4, account_kind,
   statement_period_start, statement_period_end, opening_balance, closing_balance,
   source_document_id, source, notes)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'b2222222-2222-2222-2222-222222222222'::uuid,
   'COA-006', '4335', 'bank',
   '2025-12-24', '2026-01-27', 61934.54, 85873.00,
   '93090174-012c-4767-93f4-8f9ad5d99772'::uuid,
   'us_bank_expenses_zip_20260727',
   'US Bank Smartly Savings 2-120-0314-4335 (Expenses). Parsed from PDF (26-01). 35-day period straddles year-end.'),

  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'b2222222-2222-2222-2222-222222222222'::uuid,
   'COA-006', '4335', 'bank',
   '2026-01-28', '2026-02-25', 85873.00, 86207.67,
   '0527f9ae-9fa7-43f7-a17c-329933fcecc0'::uuid,
   'us_bank_expenses_zip_20260727',
   'Parsed from PDF (26-02). Continuity verified with 26-01 close.'),

  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'b2222222-2222-2222-2222-222222222222'::uuid,
   'COA-006', '4335', 'bank',
   '2026-02-26', '2026-03-24', 86207.67, 160593.40,
   '3991b9bc-5fb2-4b7f-b377-deac8b2ec092'::uuid,
   'us_bank_expenses_zip_20260727',
   'Parsed from PDF (26-03). Continuity verified with 26-02 close.'),

  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'b2222222-2222-2222-2222-222222222222'::uuid,
   'COA-006', '4335', 'bank',
   '2026-03-25', '2026-04-23', 160593.40, 128197.22,
   'f75fbe5f-2cab-4801-8037-9f20616452c5'::uuid,
   'us_bank_expenses_zip_20260727',
   'Parsed from PDF (26-04). Continuity verified with 26-03 close.'),

  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'b2222222-2222-2222-2222-222222222222'::uuid,
   'COA-006', '4335', 'bank',
   '2026-04-24', '2026-05-26', 128197.22, 131155.26,
   'f77aac16-1a17-4696-83df-d345d17ae498'::uuid,
   'us_bank_expenses_zip_20260727',
   'Parsed from PDF (26-05). Continuity verified with 26-04 close.'),

  ('126794dd-25ff-47d2-a436-724499733365'::uuid,
   'b2222222-2222-2222-2222-222222222222'::uuid,
   'COA-006', '4335', 'bank',
   '2026-05-27', '2026-06-24', 131155.26, 75039.22,
   '94aa6222-08d4-4403-8a7d-95e920d68a3c'::uuid,
   'us_bank_expenses_zip_20260727',
   'Parsed from PDF (26-06). Continuity verified with 26-05 close. Latest cycle on file — pre-cutover by 6 days (cutover 6/30/2026).');

-- 3) Fill in bank_accounts identifying fields so Bank tab shows "US Bank · ••4335"
UPDATE public.bank_accounts
SET account_number_last4 = '4335',
    current_balance      = 75039.22,
    as_of_date           = '2026-06-24',
    statement_close_day  = 24,
    updated_at           = NOW()
WHERE id = '4dc792cf-c087-47f9-b9ea-cbf1c43421f6'::uuid;

-- 4) Replace account_starting_balances placeholder with real anchor
UPDATE public.account_starting_balances
SET balance     = 75039.22,
    as_of_date  = '2026-06-24',
    source      = 'us_bank_expenses_stmt_26-06',
    notes       = 'Real anchor from 26-06 statement close ($75,039.22 on 6/24/2026). Statement cycle ends ~24th; 6/30 cutover anchor requires next statement (26-07, ~7/23-24) to capture Jun 25-30 activity. Prior placeholder ($0.00 awaiting_statement) retired.',
    updated_at  = NOW()
WHERE id = '3a421c72-8306-4aa0-b29f-1e10150aa696'::uuid;
