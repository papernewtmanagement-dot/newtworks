-- Purpose: retire six stored columns whose values are either function-derivable from the
-- 9 primary traits, or no longer needed given the shift to function-based role fit.
--
-- Regression fits (from the 25-row calibration cohort):
--   ego_drive_score: R² = 0.9995, MAE 0.29, max_err 1.28
--   empathy_score:   R² = 0.9988, MAE 0.52, max_err 1.56
--   leadership_style: 20/20 stored labels reproduce exactly under threshold = 50
--   Zero classification flips verified against stored data (including near-threshold cases).

-- 1. Ego drive: dominant loadings are Deadline Motivation, Recognition Drive,
--    Assertiveness, Independent Spirit (the four "drive" traits). Others near-zero.
CREATE OR REPLACE FUNCTION public.cts_ego_drive(
  deadline_motivation int,
  recognition_drive   int,
  assertiveness       int,
  independent_spirit  int,
  analytical          int,
  compassion          int,
  self_promotion      int,
  belief_in_others    int,
  optimism            int
) RETURNS int
LANGUAGE sql IMMUTABLE
AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    -0.5353
    + 0.4070 * deadline_motivation
    + 0.1960 * recognition_drive
    + 0.2085 * assertiveness
    + 0.2002 * independent_spirit
    + (-0.0059) * analytical
    + 0.0013 * compassion
    + 0.0015 * self_promotion
    + (-0.0054) * belief_in_others
    + 0.0023 * optimism
  )::numeric)::int);
$$;

-- 2. Empathy: dominant positive loading Compassion; secondary Belief in Others;
--    notable NEGATIVE loading on Analytical (analytical operators score lower on warmth).
CREATE OR REPLACE FUNCTION public.cts_empathy(
  deadline_motivation int,
  recognition_drive   int,
  assertiveness       int,
  independent_spirit  int,
  analytical          int,
  compassion          int,
  self_promotion      int,
  belief_in_others    int,
  optimism            int
) RETURNS int
LANGUAGE sql IMMUTABLE
AS $$
  SELECT GREATEST(0, LEAST(100, ROUND(
    24.6859
    + 0.0075 * deadline_motivation
    + (-0.0015) * recognition_drive
    + 0.0193 * assertiveness
    + (-0.0086) * independent_spirit
    + (-0.2585) * analytical
    + 0.5024 * compassion
    + 0.0047 * self_promotion
    + 0.2403 * belief_in_others
    + (-0.0023) * optimism
  )::numeric)::int);
$$;

-- 3. Leadership style: 4-quadrant grid on ego × empathy, threshold = 50.
--    Cohort observed: Performer (both high), Diplomat (low ego high emp),
--    Thinker (both low). 4th quadrant (high ego low emp) named "Achiever" as
--    placeholder — override if vendor's canonical term is different.
CREATE OR REPLACE FUNCTION public.cts_leadership_style(
  ego int,
  empathy int
) RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN ego IS NULL OR empathy IS NULL THEN NULL
    WHEN ego >= 50 AND empathy >= 50 THEN 'Performer'
    WHEN ego <  50 AND empathy >= 50 THEN 'Diplomat'
    WHEN ego <  50 AND empathy <  50 THEN 'Thinker'
    ELSE 'Achiever'
  END;
$$;

-- 4. Drop the six redundant stored columns.
ALTER TABLE public.team_assessments
  DROP COLUMN IF EXISTS overall_score_band,
  DROP COLUMN IF EXISTS recommended_coaching_hours_min,
  DROP COLUMN IF EXISTS recommended_coaching_hours_max,
  DROP COLUMN IF EXISTS leadership_style,
  DROP COLUMN IF EXISTS ego_drive_score,
  DROP COLUMN IF EXISTS empathy_score;

-- 5. Re-add ego_drive_score, empathy_score, leadership_style as STORED generated
--    columns so existing queries that SELECT them keep working. Storage cost is
--    trivial (int × 25 rows). Regenerates automatically on any trait UPDATE.
ALTER TABLE public.team_assessments
  ADD COLUMN ego_drive_score int GENERATED ALWAYS AS (
    public.cts_ego_drive(
      deadline_motivation, recognition_drive, assertiveness,
      independent_spirit, analytical, compassion,
      self_promotion, belief_in_others, optimism
    )
  ) STORED,
  ADD COLUMN empathy_score int GENERATED ALWAYS AS (
    public.cts_empathy(
      deadline_motivation, recognition_drive, assertiveness,
      independent_spirit, analytical, compassion,
      self_promotion, belief_in_others, optimism
    )
  ) STORED,
  ADD COLUMN leadership_style text GENERATED ALWAYS AS (
    public.cts_leadership_style(
      public.cts_ego_drive(
        deadline_motivation, recognition_drive, assertiveness,
        independent_spirit, analytical, compassion,
        self_promotion, belief_in_others, optimism
      ),
      public.cts_empathy(
        deadline_motivation, recognition_drive, assertiveness,
        independent_spirit, analytical, compassion,
        self_promotion, belief_in_others, optimism
      )
    )
  ) STORED;
