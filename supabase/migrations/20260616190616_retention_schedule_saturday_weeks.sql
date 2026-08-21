-- Switch to Saturday week-end semantics
-- Rename column and update the convenience view

ALTER TABLE public.retention_budget_schedule
  RENAME COLUMN week_start_date TO week_end_date;

ALTER INDEX idx_retbudsched_agency_week
  RENAME TO idx_retbudsched_agency_weekend;

DROP VIEW IF EXISTS public.v_retention_budget_current;

CREATE OR REPLACE VIEW public.v_retention_budget_current AS
SELECT
  s.agency_id,
  s.week_end_date,
  s.multiplier,
  s.phase,
  s.plan_note
FROM public.retention_budget_schedule s
WHERE s.week_end_date >= CURRENT_DATE
ORDER BY s.week_end_date ASC
LIMIT 1;

COMMENT ON COLUMN public.retention_budget_schedule.week_end_date IS
  'Saturday that ends the Sun-Sat week the multiplier applies to.';
COMMENT ON TABLE public.retention_budget_schedule IS
  'Weekly multiplier schedule (Sun-Sat weeks, Saturday-ending) for retention budget formula: budget = multiplier * (Auto+Fire+Life premium). Phase 1: AA05 step-down 1.535% (baseline, not stored) -> 1.25% landing Sat 2028-01-01. Phase 2: jump to 1.095% on Sat 2028-01-08, step down to 1.00% landing Sat 2028-12-30.';
