-- Rebrand leadership style names to be unique to HireGauge (no vendor overlap).
-- Mapping:
--   High Ego + High Empathy       Performer -> Rockstar
--   Low Ego  + High Empathy       Diplomat  -> Ambassador
--   Low Ego  + Low Empathy        Thinker   -> Analyst
--   High Ego + Low Empathy        Achiever  -> Achiever  (was placeholder, now committed)

-- Step 1: drop the generated column so we can replace the function it depends on
ALTER TABLE public.team_assessments DROP COLUMN leadership_style;

-- Step 2: replace the function with the new labels
CREATE OR REPLACE FUNCTION public.cts_leadership_style(
  ego int,
  empathy int
) RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN ego IS NULL OR empathy IS NULL THEN NULL
    WHEN ego >= 50 AND empathy >= 50 THEN 'Rockstar'
    WHEN ego <  50 AND empathy >= 50 THEN 'Ambassador'
    WHEN ego <  50 AND empathy <  50 THEN 'Analyst'
    ELSE 'Achiever'
  END;
$$;

-- Step 3: re-add the generated column
ALTER TABLE public.team_assessments
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
