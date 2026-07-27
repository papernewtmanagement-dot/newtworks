-- STEP 1: Fix credit-card anchors at 6/30/2026 GL cutover.
-- Balances computed live from journal_lines through 2026-06-30.

INSERT INTO public.opening_balances
  (agency_id, as_of_date, account_code, account_name, account_type, opening_balance, source, business_entity_id)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365','2026-06-30','COA-009','AMEX - Discretionary','liability', 4320.41,'gl_cutover_ledger_snapshot','b2222222-2222-2222-2222-222222222222'),
  ('126794dd-25ff-47d2-a436-724499733365','2026-06-30','COA-013','SF Card - Expenses, Alvi','liability',    0.00,'gl_cutover_ledger_snapshot_no_activity','b2222222-2222-2222-2222-222222222222'),
  ('126794dd-25ff-47d2-a436-724499733365','2026-06-30','COA-014','SF Card - Expenses, Peter','liability', 6262.09,'gl_cutover_ledger_snapshot','b2222222-2222-2222-2222-222222222222'),
  ('126794dd-25ff-47d2-a436-724499733365','2026-06-30','COA-PN-CC-1247','Citi CC (1247) — PN printing card','liability', 442.10,'gl_cutover_ledger_snapshot','b1111111-1111-1111-1111-111111111111');

UPDATE public.opening_balances
SET opening_balance = 8409.59,
    source = 'gl_cutover_ledger_snapshot_refreshed_from_3923_55'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND as_of_date = '2026-06-30'
  AND account_code = 'COA-012';
