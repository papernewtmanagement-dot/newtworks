-- 2141 AMEX Discretionary: the 26-06 window was stored 2026-05-15..2026-06-14,
-- overlapping the 26-05 window's close date 2026-05-15. Convention everywhere
-- else in statement_balances: a window starts the day AFTER the prior close.
-- Sweep on 2026-08-11 found this single overlap in the whole table.
-- The two rows dated 2026-05-15 (21.64 ADT, 84.70 Authentic Taquitos) are
-- explicitly pinned to the June statement via statements.statement_balance_id,
-- so this date change moves nothing in v_statement_reconciliation.
UPDATE statement_balances
SET statement_period_start = '2026-05-16'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_code = '2141'
  AND statement_period_end = '2026-06-14'
  AND statement_period_start = '2026-05-15';
