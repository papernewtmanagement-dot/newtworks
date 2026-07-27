-- Backfill statement_balances with the most-recent known close per account.
-- Personal side: real statement closes from Pers Fin 2/3 ingest work.
-- Elsewhere: 6/30/2026 GL cutover snapshot as approximation until real statements ingest.

INSERT INTO public.statement_balances
  (agency_id, business_entity_id, account_code, account_last4, account_kind,
   statement_period_end, closing_balance, source, notes)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365','b3333333-3333-3333-3333-333333333333','COA-PERSONAL-0353','0353','bank','2026-06-22', 3145.49, 'personal_financials_phase3_batch1','US Bank Personal Checking 26-06 statement close (Jun 22, 2026)'),
  ('126794dd-25ff-47d2-a436-724499733365','b3333333-3333-3333-3333-333333333333','COA-PERSONAL-6730','6730','bank','2026-06-24', 1132.98, 'personal_financials_phase3_batch1','US Bank Kids Profit Disc 26-06 statement close (Jun 24, 2026)'),
  ('126794dd-25ff-47d2-a436-724499733365','b3333333-3333-3333-3333-333333333333','COA-PERSONAL-2545','2545','bank','2026-07-08', 800.02, 'personal_financials_phase3_batch1','US Bank Other Income 26-07 statement close (Jul 8, 2026)'),
  ('126794dd-25ff-47d2-a436-724499733365','b3333333-3333-3333-3333-333333333333','COA-PERSONAL-CC-8847','8847','credit','2026-07-08', 113.00, 'personal_financials_phase3_batch1','US Bank Personal CC 26-07 statement close (Jul 8, 2026)'),
  ('126794dd-25ff-47d2-a436-724499733365','b3333333-3333-3333-3333-333333333333','COA-PERSONAL-6755','6755','bank','2026-06-30', 12145.46, 'gl_cutover_ledger_snapshot','Ledger snapshot — replace with actual statement close when 26-06 US Bank Tithe Tax processes'),
  ('126794dd-25ff-47d2-a436-724499733365','b3333333-3333-3333-3333-333333333333','COA-PERSONAL-6596','6596','bank','2026-06-30', -279.64, 'gl_cutover_ledger_snapshot_ANOMALY','Ledger says negative — real bank account cannot be negative. Likely SBA loan JE misrouted here from 0353. Fix before trusting.'),
  ('126794dd-25ff-47d2-a436-724499733365','b3333333-3333-3333-3333-333333333333','COA-PERSONAL-CC-1006','1006','credit','2026-06-30', 493.01, 'gl_cutover_ledger_snapshot','Ledger snapshot — replace with actual statement close when next AMEX 1006 processes'),
  ('126794dd-25ff-47d2-a436-724499733365','b3333333-3333-3333-3333-333333333333','COA-PERSONAL-CC-3208','3208','credit','2026-06-30', 7132.76, 'gl_cutover_ledger_snapshot','Ledger snapshot — replace with actual statement close when next Discover 3208 processes'),
  ('126794dd-25ff-47d2-a436-724499733365','b3333333-3333-3333-3333-333333333333','COA-PERSONAL-CC-7435','7435','credit','2026-06-30', 2710.21, 'gl_cutover_ledger_snapshot','Ledger snapshot — replace with actual statement close when next Capital One 7435 processes'),
  ('126794dd-25ff-47d2-a436-724499733365','b2222222-2222-2222-2222-222222222222','COA-007','3977','bank','2026-06-30', 30034.83, 'real_bank_statement_20260630','Real US Bank Income statement close 6/30/2026'),
  ('126794dd-25ff-47d2-a436-724499733365','b2222222-2222-2222-2222-222222222222','COA-006',NULL,'bank','2026-06-30', 0.00, 'awaiting_statement','US Bank Expenses (4335) — June statement not on hand. Ask Alvi.'),
  ('126794dd-25ff-47d2-a436-724499733365','b2222222-2222-2222-2222-222222222222','COA-009',NULL,'credit','2026-06-30', 4320.41, 'gl_cutover_ledger_snapshot','AMEX Discretionary — ledger snapshot'),
  ('126794dd-25ff-47d2-a436-724499733365','b2222222-2222-2222-2222-222222222222','COA-011','7762','credit','2026-06-30', 0.00, 'gl_cutover_ledger_snapshot','Chase Marketing 1 — inactive card, ledger snapshot'),
  ('126794dd-25ff-47d2-a436-724499733365','b2222222-2222-2222-2222-222222222222','COA-012','7770','credit','2026-06-30', 8409.59, 'gl_cutover_ledger_snapshot','Chase Marketing 2 — ledger snapshot'),
  ('126794dd-25ff-47d2-a436-724499733365','b2222222-2222-2222-2222-222222222222','COA-013','3439','credit','2026-06-30', 0.00, 'awaiting_statement','SF Card Alvi — no post-cutover activity, verify from statement'),
  ('126794dd-25ff-47d2-a436-724499733365','b2222222-2222-2222-2222-222222222222','COA-014','4676','credit','2026-06-30', 6262.09, 'gl_cutover_ledger_snapshot','SF Card Peter — ledger snapshot'),
  ('126794dd-25ff-47d2-a436-724499733365','b1111111-1111-1111-1111-111111111111','COA-PN-CC-1247','1247','credit','2026-06-30', 442.10, 'gl_cutover_ledger_snapshot','Citi 1247 PN printing — ledger snapshot');
