-- Fix AMEX 2141 statement window boundary: the period beginning 2026-06-14 had
-- statement_period_start incorrectly set to 2026-05-15, overlapping the prior
-- (05-15 close) window. Universal convention is "period start = day after prior
-- statement's period end." Corrected to 2026-05-16.
UPDATE statement_balances
SET statement_period_start = '2026-05-16'
WHERE account_code = '2141'
  AND statement_period_end = '2026-06-14';
