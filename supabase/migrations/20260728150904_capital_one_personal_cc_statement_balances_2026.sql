-- Capital One Personal Card (7435) — 5 missing statement_balances rows for 26-01..26-05
-- 26-06 already exists; ON CONFLICT DO NOTHING preserves it
-- All 6 cycles reconcile penny-perfect against 301 existing credit_transactions
-- statement_balances_unique_period is a UNIQUE INDEX not a named constraint → use column list
INSERT INTO public.statement_balances
  (agency_id, business_entity_id, account_code, account_last4, account_kind,
   statement_period_start, statement_period_end, opening_balance, closing_balance,
   source, notes)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333',
   'COA-PERSONAL-CC-7435', '7435', 'credit',
   '2025-12-29', '2026-01-28', 2957.01, 2696.77,
   'statement_pdf_ingest', 'Cycle 26-01 | prev 2957.01 - pmt 2957.01 - othercr 181.78 + charges 2878.55 = 2696.77'),
  ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333',
   'COA-PERSONAL-CC-7435', '7435', 'credit',
   '2026-01-29', '2026-02-25', 2696.77, 2488.99,
   'statement_pdf_ingest', 'Cycle 26-02 | prev 2696.77 - pmt 2696.77 - othercr 67.49 + charges 2556.48 = 2488.99'),
  ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333',
   'COA-PERSONAL-CC-7435', '7435', 'credit',
   '2026-02-26', '2026-03-28', 2488.99, 2165.58,
   'statement_pdf_ingest', 'Cycle 26-03 | prev 2488.99 - pmt 2488.99 - othercr 100.33 + charges 2265.91 = 2165.58'),
  ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333',
   'COA-PERSONAL-CC-7435', '7435', 'credit',
   '2026-03-29', '2026-04-27', 2165.58, 4461.51,
   'statement_pdf_ingest', 'Cycle 26-04 | prev 2165.58 - pmt 2165.58 - othercr 38.96 + charges 4500.47 = 4461.51'),
  ('126794dd-25ff-47d2-a436-724499733365', 'b3333333-3333-3333-3333-333333333333',
   'COA-PERSONAL-CC-7435', '7435', 'credit',
   '2026-04-28', '2026-05-28', 4461.51, 1301.91,
   'statement_pdf_ingest', 'Cycle 26-05 | prev 4461.51 - pmt 4461.51 - othercr 1.16 + charges 1303.07 = 1301.91')
ON CONFLICT (agency_id, account_code, statement_period_end) DO NOTHING;
