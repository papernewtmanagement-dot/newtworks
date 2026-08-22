-- hiregauge_competency_floors: per-competency intelligence-composite floors for LSS Step 4 rewire.
--
-- Companion table to hiregauge_role_ideal_ranges. That table stores role-fit floors + ceilings
-- (min + max) for the 7 role_fit functions. This table stores comp-side floors (min only) for
-- the 27 competency functions.
--
-- Comp-side scoring per LSS Step 2c (locked 2026-07-31): monotonic floor-only curve.
--   multiplier = 1.0                                          if composite >= floor
--              = exp(-3.0 * (floor - composite) / floor)      if composite <  floor
--
-- Populated one row per competency as each function is rewired in the 27-fn walkthrough.
-- Each floor decision requires research grounding in the notes field (same discipline as
-- the 7 role_ideal_ranges rows populated during Step 3).
CREATE TABLE IF NOT EXISTS public.hiregauge_competency_floors (
  agency_id        uuid NOT NULL,
  competency_name  text NOT NULL,
  floor            numeric,
  notes            text,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       text,
  PRIMARY KEY (agency_id, competency_name),
  CONSTRAINT hiregauge_competency_floors_floor_range
    CHECK (floor IS NULL OR (floor >= 0 AND floor <= 100))
);

ALTER TABLE public.hiregauge_competency_floors ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anon_all_hiregauge_competency_floors" ON public.hiregauge_competency_floors;
CREATE POLICY "anon_all_hiregauge_competency_floors"
  ON public.hiregauge_competency_floors
  FOR ALL TO anon
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "authenticated_all_hiregauge_competency_floors" ON public.hiregauge_competency_floors;
CREATE POLICY "authenticated_all_hiregauge_competency_floors"
  ON public.hiregauge_competency_floors
  FOR ALL TO authenticated
  USING (true) WITH CHECK (true);

COMMENT ON TABLE public.hiregauge_competency_floors IS
  'Per-competency intelligence-composite floors (0-100) for comp-side monotonic floor-only curve (LSS Step 2c, locked 2026-07-31). Populated one row per competency during the 27-fn Step 4 rewire. Companion to hiregauge_role_ideal_ranges (role-fit floors + ceilings).';

COMMENT ON COLUMN public.hiregauge_competency_floors.competency_name IS
  'Competency identifier matching the assessment_competency_<name> SQL function suffix. One row per rewired competency function.';

COMMENT ON COLUMN public.hiregauge_competency_floors.floor IS
  'Intelligence-composite floor on 0-100 scale. Below this, comp-side multiplier applies exp(-3.0 * (floor - composite) / floor) decay per Step 2c curve.';

COMMENT ON COLUMN public.hiregauge_competency_floors.notes IS
  'Research citation stack justifying floor choice for this competency. Same discipline as hiregauge_role_ideal_ranges.notes. Cite primary sources (e.g., Hunter & Hunter 1984 complexity band, Zhou/Kuncel/Sackett 2024, Sweller 1988, competency-specific meta-analytic priors).';
