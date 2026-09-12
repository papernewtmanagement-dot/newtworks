-- Wipe the nine dropped facets' raw values on hiring_candidates and keep them empty (2026-09-11).
--
-- Peter: "wipe those old raw numbers for the traits that were dropped." The scoring paths stopped
-- reading these columns in migration drop_nine_facets_from_scoring; this clears the stored values
-- for every candidate and adds a row trigger that blanks the nine columns on any future insert or
-- update, so no scorer, backfill, or rescore can refill them (a Likert-fallback finalize still
-- returns sincerity/fairness/greed_avoidance rows from stint 1 -- the write lands as NULL instead
-- of failing). The columns themselves stay so nothing that selects them breaks.
--
-- The nine: sincerity, fairness, greed_avoidance, anxiety, anger, trust, competitiveness,
-- prove_goal_orientation, avoid_goal_orientation. Section-1 honesty is scored live from responses
-- (hiregauge_v2_stint1_exit_gate) and is not affected.

CREATE OR REPLACE FUNCTION public.hiring_candidates_null_dropped_facets()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  -- 2026-09-11 (16-trait set, Peter): these nine facets are no longer measured or stored.
  NEW.sincerity := NULL;
  NEW.fairness := NULL;
  NEW.greed_avoidance := NULL;
  NEW.anxiety := NULL;
  NEW.anger := NULL;
  NEW.trust := NULL;
  NEW.competitiveness := NULL;
  NEW.prove_goal_orientation := NULL;
  NEW.avoid_goal_orientation := NULL;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_hiring_candidates_null_dropped_facets ON public.hiring_candidates;
CREATE TRIGGER trg_hiring_candidates_null_dropped_facets
BEFORE INSERT OR UPDATE ON public.hiring_candidates
FOR EACH ROW EXECUTE FUNCTION public.hiring_candidates_null_dropped_facets();

UPDATE public.hiring_candidates
SET sincerity = NULL, fairness = NULL, greed_avoidance = NULL, anxiety = NULL, anger = NULL,
    trust = NULL, competitiveness = NULL, prove_goal_orientation = NULL, avoid_goal_orientation = NULL
WHERE sincerity IS NOT NULL OR fairness IS NOT NULL OR greed_avoidance IS NOT NULL
   OR anxiety IS NOT NULL OR anger IS NOT NULL OR trust IS NOT NULL
   OR competitiveness IS NOT NULL OR prove_goal_orientation IS NOT NULL OR avoid_goal_orientation IS NOT NULL;

DO $$
DECLARE v_left int;
BEGIN
  SELECT count(*) INTO v_left FROM public.hiring_candidates
  WHERE sincerity IS NOT NULL OR fairness IS NOT NULL OR greed_avoidance IS NOT NULL
     OR anxiety IS NOT NULL OR anger IS NOT NULL OR trust IS NOT NULL
     OR competitiveness IS NOT NULL OR prove_goal_orientation IS NOT NULL OR avoid_goal_orientation IS NOT NULL;
  IF v_left <> 0 THEN RAISE EXCEPTION '% candidates still carry a dropped-facet value', v_left; END IF;
  PERFORM public.hiregauge_refresh_scoring_cache('126794dd-25ff-47d2-a436-724499733365', 'all');
END $$;
