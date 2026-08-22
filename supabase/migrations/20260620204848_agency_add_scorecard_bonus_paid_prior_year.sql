ALTER TABLE public.agency
  ADD COLUMN IF NOT EXISTS scorecard_bonus_paid_prior_year NUMERIC(12,2);

COMMENT ON COLUMN public.agency.scorecard_bonus_paid_prior_year IS
  'Actual Scorecard Bonus paid out for the prior program year (e.g. 2025 bonus paid March 2026). Manual entry, updated annually when the actual payout lands. Used by compute_scorecard_bonus() as the "Last Year" column value on CPR Section 11.';
