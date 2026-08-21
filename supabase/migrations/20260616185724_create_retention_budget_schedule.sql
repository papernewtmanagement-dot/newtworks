-- Retention budget multiplier schedule
-- Stores per-week multiplier used in: retention_budget = multiplier * (Auto + Fire + Life premium)
-- Phase 1: AA05 step-down (1.535% -> 1.25%)
-- Phase 2: AA28 step-down (1.095% -> 1.00%) — note discontinuity at AA28 transition

CREATE TABLE IF NOT EXISTS public.retention_budget_schedule (
  id               uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id        uuid          NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  week_start_date  date          NOT NULL,
  multiplier       numeric(7,5)  NOT NULL CHECK (multiplier >= 0 AND multiplier <= 1),
  phase            text          NOT NULL,
  plan_note        text,
  created_at       timestamptz   NOT NULL DEFAULT now(),
  updated_at       timestamptz   NOT NULL DEFAULT now(),
  UNIQUE (agency_id, week_start_date)
);

CREATE INDEX IF NOT EXISTS idx_retbudsched_agency_week
  ON public.retention_budget_schedule (agency_id, week_start_date DESC);

ALTER TABLE public.retention_budget_schedule ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS anon_read_retention_budget_schedule ON public.retention_budget_schedule;
CREATE POLICY anon_read_retention_budget_schedule
  ON public.retention_budget_schedule FOR SELECT
  USING (true);

DROP POLICY IF EXISTS anon_write_retention_budget_schedule ON public.retention_budget_schedule;
CREATE POLICY anon_write_retention_budget_schedule
  ON public.retention_budget_schedule FOR ALL
  USING (true) WITH CHECK (true);

-- Convenience view: the multiplier active for the current week (and current dollar budget)
CREATE OR REPLACE VIEW public.v_retention_budget_current AS
SELECT
  s.agency_id,
  s.week_start_date,
  s.multiplier,
  s.phase,
  s.plan_note
FROM public.retention_budget_schedule s
WHERE s.week_start_date <= CURRENT_DATE
  AND s.week_start_date >  CURRENT_DATE - INTERVAL '7 days'
ORDER BY s.week_start_date DESC
LIMIT 1;

COMMENT ON TABLE public.retention_budget_schedule IS
  'Weekly multiplier schedule for retention budget formula: budget = multiplier * (Auto+Fire+Life premium). Two phases: AA05 step-down through 2027-12-27, AA28 step-down through 2028-12-25.';
COMMENT ON COLUMN public.retention_budget_schedule.week_start_date IS 'Monday of the week the multiplier applies to. Multiplier is in effect Mon through Sun.';
COMMENT ON COLUMN public.retention_budget_schedule.multiplier IS 'Decimal form, e.g. 0.01535 = 1.535%.';
COMMENT ON COLUMN public.retention_budget_schedule.phase IS 'phase_1_aa05_stepdown | phase_2_aa28_stepdown';
