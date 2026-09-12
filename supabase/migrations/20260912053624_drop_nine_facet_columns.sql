-- Drop the nine dropped facets' columns from hiring_candidates (2026-09-12).
--
-- Peter: "delete those old columns that stored the now deleted trait scores." Sequence so far:
-- drop_nine_facets_from_scoring took the nine out of every scoring path and deleted their weight
-- and norm rows; wipe_nine_facet_raw_columns nulled the stored values and added a blanking trigger.
-- This drops the columns themselves and retires that trigger (nothing left to blank).
--
-- Preconditions checked before writing this: no view, function body, or app source selects these
-- columns by name (repo sweep of src/ and supabase/functions/ on 2026-09-12); the assessment endpoint's
-- facet write-back map dropped the nine in commit f95c8989 and was redeployed as v53 before this ran,
-- so a Likert-fallback finalize (stint-1 honesty rows) hits the unmapped-trait guard instead of a
-- missing column. Section-1 honesty is scored live from responses and is unaffected.
--
-- The nine: sincerity, fairness, greed_avoidance, anxiety, anger, trust, competitiveness,
-- prove_goal_orientation, avoid_goal_orientation.

DROP TRIGGER IF EXISTS trg_hiring_candidates_null_dropped_facets ON public.hiring_candidates;
DROP FUNCTION IF EXISTS public.hiring_candidates_null_dropped_facets();

ALTER TABLE public.hiring_candidates
  DROP COLUMN IF EXISTS sincerity,
  DROP COLUMN IF EXISTS fairness,
  DROP COLUMN IF EXISTS greed_avoidance,
  DROP COLUMN IF EXISTS anxiety,
  DROP COLUMN IF EXISTS anger,
  DROP COLUMN IF EXISTS trust,
  DROP COLUMN IF EXISTS competitiveness,
  DROP COLUMN IF EXISTS prove_goal_orientation,
  DROP COLUMN IF EXISTS avoid_goal_orientation;

DO $$
DECLARE v_cols int; v_mix text;
BEGIN
  SELECT count(*) INTO v_cols FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'hiring_candidates'
    AND column_name IN ('sincerity','fairness','greed_avoidance','anxiety','anger','trust',
                        'competitiveness','prove_goal_orientation','avoid_goal_orientation');
  IF v_cols <> 0 THEN RAISE EXCEPTION '% dropped-facet columns still present', v_cols; END IF;

  -- Scoring must be untouched by the column drop: same verdict mix as after drop_nine_facets_from_scoring.
  SELECT string_agg(verdict || '=' || n, ',' ORDER BY verdict) INTO v_mix
  FROM (SELECT v.verdict, count(*) n
        FROM public.hiring_candidates c
        CROSS JOIN LATERAL public.verdict_assessment(c.id, NULL) v
        WHERE c.assessment_source = 'v2fcq' AND c.assessment_completed_at IS NOT NULL
        GROUP BY 1) z;
  IF v_mix <> 'consider=20,decline=3,pass=4' THEN
    RAISE EXCEPTION 'verdict mix changed after column drop: %', v_mix;
  END IF;
END $$;
