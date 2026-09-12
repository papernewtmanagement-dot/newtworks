-- Scorecard x (stored 0) — follow-through: rp_log_scorecard accepts 0, and average_score (a stored generated column)
-- averages only the parts scored 1-3. The BEFORE trigger from the round-2 migration could not set a generated
-- column, so it is dropped and the column is re-generated instead.
DROP TRIGGER IF EXISTS trg_fit_scorecards_average ON public.fit_scorecards;
DROP FUNCTION IF EXISTS public.fit_scorecards_average();

DO $$
DECLARE d text; o1 text; n1 text;
BEGIN
  d := pg_get_functiondef('public.rp_log_scorecard'::regproc);
  o1 := 'IF v_val NOT BETWEEN 1 AND 3 THEN RAISE EXCEPTION ''scorecard scores are 1, 2, 3, or left blank''; END IF;';
  n1 := 'IF v_val NOT BETWEEN 0 AND 3 THEN RAISE EXCEPTION ''scorecard scores are x (0), 1, 2, or 3''; END IF;';
  IF position(o1 in d) = 0 THEN RAISE EXCEPTION 'rp_log_scorecard patch anchor not found'; END IF;
  EXECUTE replace(d, o1, n1);
END $$;

ALTER TABLE public.fit_scorecards DROP COLUMN IF EXISTS average_score;
ALTER TABLE public.fit_scorecards ADD COLUMN average_score numeric GENERATED ALWAYS AS (
  CASE WHEN
    (CASE WHEN demeanor_score > 0 THEN 1 ELSE 0 END + CASE WHEN frogs_score > 0 THEN 1 ELSE 0 END + CASE WHEN intro_score > 0 THEN 1 ELSE 0 END
     + CASE WHEN eligibility_score > 0 THEN 1 ELSE 0 END + CASE WHEN setup_gnc_score > 0 THEN 1 ELSE 0 END + CASE WHEN uncover_gap_score > 0 THEN 1 ELSE 0 END
     + CASE WHEN bridge_gap_score > 0 THEN 1 ELSE 0 END + CASE WHEN customize_close_score > 0 THEN 1 ELSE 0 END + CASE WHEN set_followup_score > 0 THEN 1 ELSE 0 END
     + CASE WHEN review_referral_score > 0 THEN 1 ELSE 0 END) > 0
  THEN ROUND(
    (CASE WHEN demeanor_score > 0 THEN demeanor_score ELSE 0 END + CASE WHEN frogs_score > 0 THEN frogs_score ELSE 0 END + CASE WHEN intro_score > 0 THEN intro_score ELSE 0 END
     + CASE WHEN eligibility_score > 0 THEN eligibility_score ELSE 0 END + CASE WHEN setup_gnc_score > 0 THEN setup_gnc_score ELSE 0 END + CASE WHEN uncover_gap_score > 0 THEN uncover_gap_score ELSE 0 END
     + CASE WHEN bridge_gap_score > 0 THEN bridge_gap_score ELSE 0 END + CASE WHEN customize_close_score > 0 THEN customize_close_score ELSE 0 END + CASE WHEN set_followup_score > 0 THEN set_followup_score ELSE 0 END
     + CASE WHEN review_referral_score > 0 THEN review_referral_score ELSE 0 END)::numeric
    /
    (CASE WHEN demeanor_score > 0 THEN 1 ELSE 0 END + CASE WHEN frogs_score > 0 THEN 1 ELSE 0 END + CASE WHEN intro_score > 0 THEN 1 ELSE 0 END
     + CASE WHEN eligibility_score > 0 THEN 1 ELSE 0 END + CASE WHEN setup_gnc_score > 0 THEN 1 ELSE 0 END + CASE WHEN uncover_gap_score > 0 THEN 1 ELSE 0 END
     + CASE WHEN bridge_gap_score > 0 THEN 1 ELSE 0 END + CASE WHEN customize_close_score > 0 THEN 1 ELSE 0 END + CASE WHEN set_followup_score > 0 THEN 1 ELSE 0 END
     + CASE WHEN review_referral_score > 0 THEN 1 ELSE 0 END)::numeric, 2)
  ELSE NULL END) STORED;
