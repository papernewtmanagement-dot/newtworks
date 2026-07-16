-- Widen prior_year_pl.period_year check to include 2019 (Alvi delivered 2019-2024)
ALTER TABLE public.prior_year_pl
  DROP CONSTRAINT IF EXISTS prior_year_pl_period_year_check;

ALTER TABLE public.prior_year_pl
  ADD CONSTRAINT prior_year_pl_period_year_check
  CHECK (period_year >= 2019 AND period_year <= 2026);
