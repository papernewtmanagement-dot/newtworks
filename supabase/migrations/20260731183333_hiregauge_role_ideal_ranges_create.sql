-- Per-role Intelligence (cognitive composite) ideal range storage
-- Feeds fit/nurture scoring with curvilinear penalty; competency scoring uses
-- monotonic floor only. Justified by Ree, Earles & Teachout (1994) on g-plus-
-- almost-nothing, and Ganzach (1998) on intelligence-satisfaction sign flip
-- moderated by job complexity. Intent: one ideal range per role on the
-- composite score, not per-subtest role calibration (research does not support
-- fine-grained subtest-role distinctions beyond g).

CREATE TABLE IF NOT EXISTS public.hiregauge_role_ideal_ranges (
  agency_id UUID NOT NULL,
  role_category TEXT NOT NULL,
  role_level TEXT NOT NULL,
  intelligence_ideal_min NUMERIC NULL,
  intelligence_ideal_max NUMERIC NULL,
  notes TEXT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by TEXT NULL,
  PRIMARY KEY (agency_id, role_category, role_level),
  CONSTRAINT intel_min_bounded CHECK (
    intelligence_ideal_min IS NULL
    OR (intelligence_ideal_min >= 0 AND intelligence_ideal_min <= 100)
  ),
  CONSTRAINT intel_max_bounded CHECK (
    intelligence_ideal_max IS NULL
    OR (intelligence_ideal_max >= 0 AND intelligence_ideal_max <= 100)
  ),
  CONSTRAINT intel_min_le_max CHECK (
    intelligence_ideal_min IS NULL
    OR intelligence_ideal_max IS NULL
    OR intelligence_ideal_min <= intelligence_ideal_max
  )
);

COMMENT ON TABLE public.hiregauge_role_ideal_ranges IS
'Per-role ideal range on Intelligence composite (LSS efficiency aggregate). One row per (agency, role_category, role_level). Feeds fit scoring (curvilinear) and competency scoring (monotonic floor only). NULL max = no ceiling (high-complexity roles).';

COMMENT ON COLUMN public.hiregauge_role_ideal_ranges.intelligence_ideal_min IS
'Lower bound on Intelligence composite (0-100 scale). Below this = fit and competency penalties. NULL = no floor.';

COMMENT ON COLUMN public.hiregauge_role_ideal_ranges.intelligence_ideal_max IS
'Upper bound on Intelligence composite (0-100 scale). Above this = fit/retention penalty only (Ganzach flip for low-complexity roles). NULL = no ceiling.';

ALTER TABLE public.hiregauge_role_ideal_ranges ENABLE ROW LEVEL SECURITY;

CREATE POLICY anon_read_hiregauge_role_ideal_ranges
  ON public.hiregauge_role_ideal_ranges
  FOR SELECT
  TO anon, authenticated
  USING (true);
