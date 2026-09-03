-- Step 1d: the guessing baseline computed from real option counts, and the
-- correct-items-only speed metric moved into one shared function.

CREATE OR REPLACE FUNCTION public.hiregauge_gma_chance_floor(p_candidate_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
-- Guessing baseline for the candidate's GMA item set.
--   chance_mean_items = sum over items of 1/(number of options)
--   chance_sd_items   = sqrt(sum of p(1-p))
--   derived_floor_items = ceil(mean + 2 SD)  -- design record: migration
--     reasoning_gate_chance_anchored_provisional (2026-08-05): "fire the floor
--     only when a score cannot be distinguished from guessing". A pure
--     guesser's score is a sum of independent Bernoulli trials with unequal
--     p (Poisson-binomial); the exact distribution is computed here by
--     dynamic programming so p_guesser_reaches_derived_floor is exact rather
--     than a normal approximation (Lord & Novick 1968, Statistical Theories
--     of Mental Test Scores, ch. 14 on guessing models).
--   derived_gate_c_max_correct = floor(mean)  -- stint-1 hard eliminator:
--     at or below the guessing mean.
-- floor_pct / gate_c_max_correct are the EFFECTIVE values: a set can pin them
-- by override (hiregauge_gma_item_sets.*_override) when a ruling has been made
-- on that set; otherwise the derived values apply. The 2026-08 set is pinned
-- to 62.5% / 3 by Peter ruling 2026-09-02 -- its original derivation assumed
-- 2-option items, and the true chance + 2 SD there is 7 of 16 (43.75%).
DECLARE
  v_set text;
  v_override_pct numeric;
  v_override_gate int;
  v_probs numeric[] := ARRAY[]::numeric[];
  v_p numeric;
  v_n int;
  v_mean numeric := 0;
  v_var numeric := 0;
  v_sd numeric;
  v_floor_items int;
  v_floor_pct numeric;
  v_gate_c int;
  v_dist numeric[];
  v_new numeric[];
  v_tail numeric := 0;
  v_eff_pct numeric;
  v_eff_floor_items int;
  k int;
  r record;
BEGIN
  v_set := public.hiregauge_gma_candidate_set(p_candidate_id);
  IF v_set IS NULL THEN
    RETURN jsonb_build_object('set_key', NULL, 'n_items', 0, 'floor_pct', NULL, 'gate_c_max_correct', NULL);
  END IF;

  SELECT floor_pct_override, gate_c_max_correct_override
    INTO v_override_pct, v_override_gate
  FROM public.hiregauge_gma_item_sets WHERE set_key = v_set;

  FOR r IN
    SELECT CASE
             WHEN jsonb_typeof(i.choices) = 'array' THEN jsonb_array_length(i.choices)
             WHEN jsonb_typeof(i.choices) = 'object' AND (i.choices ? 'options')
               THEN (SELECT count(*)::int FROM jsonb_object_keys(i.choices->'options'))
             ELSE NULL
           END AS n_opts
    FROM public.hiregauge_gma_item_set_members m
    JOIN public.hiregauge_instrument_items i ON i.id = m.item_id
    WHERE m.set_key = v_set
  LOOP
    IF r.n_opts IS NULL OR r.n_opts < 2 THEN CONTINUE; END IF;
    v_probs := array_append(v_probs, (1.0::numeric / r.n_opts));
  END LOOP;

  v_n := COALESCE(array_length(v_probs, 1), 0);
  IF v_n = 0 THEN
    RETURN jsonb_build_object('set_key', v_set, 'n_items', 0,
                              'floor_pct', v_override_pct, 'gate_c_max_correct', v_override_gate);
  END IF;

  v_dist := ARRAY[1.0::numeric];
  FOREACH v_p IN ARRAY v_probs LOOP
    v_mean := v_mean + v_p;
    v_var := v_var + v_p * (1 - v_p);
    v_new := array_fill(0::numeric, ARRAY[array_length(v_dist, 1) + 1]);
    FOR k IN 1..array_length(v_dist, 1) LOOP
      v_new[k]     := v_new[k]     + v_dist[k] * (1 - v_p);
      v_new[k + 1] := v_new[k + 1] + v_dist[k] * v_p;
    END LOOP;
    v_dist := v_new;
  END LOOP;

  v_sd := sqrt(v_var);
  v_floor_items := ceil(v_mean + 2 * v_sd)::int;
  v_gate_c := floor(v_mean)::int;
  v_floor_pct := round(v_floor_items::numeric / v_n * 100.0, 4);

  -- exact P(guesser scores >= derived_floor_items); v_dist[k] = P(X = k-1)
  FOR k IN (v_floor_items + 1)..array_length(v_dist, 1) LOOP
    v_tail := v_tail + v_dist[k];
  END LOOP;

  v_eff_pct := COALESCE(v_override_pct, v_floor_pct);
  v_eff_floor_items := ceil(v_eff_pct / 100.0 * v_n)::int;

  RETURN jsonb_build_object(
    'set_key', v_set,
    'n_items', v_n,
    'chance_mean_items', round(v_mean, 4),
    'chance_sd_items', round(v_sd, 4),
    'derived_floor_items', v_floor_items,
    'derived_floor_pct', v_floor_pct,
    'derived_gate_c_max_correct', v_gate_c,
    'p_guesser_reaches_derived_floor', round(v_tail, 5),
    'floor_pct', v_eff_pct,
    'floor_items', v_eff_floor_items,
    'gate_c_max_correct', COALESCE(v_override_gate, v_gate_c),
    'basis', CASE WHEN v_override_pct IS NOT NULL OR v_override_gate IS NOT NULL
                  THEN 'pinned_by_ruling_2026_09_02_for_' || v_set
                  ELSE 'chance_plus_2sd_from_option_counts' END
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.hiregauge_gma_speed_ipm(p_candidate_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
AS $function$
-- CORRECT GMA items answered per minute of time spent on those correct items
-- (role_fit_v5_5, Kyllonen & Zu 2016 J. Intelligence 4(14); Peter directive
-- "faster should help when correct, does nothing when wrong"). NULL when the
-- candidate is below the reasoning floor for their item set, or no correct
-- item carries valid timing. Used by _newtworks_role_fit_core AND the norm
-- rebuild so the two can never drift apart.
DECLARE
  v_row public.hiring_candidates%ROWTYPE;
  v_n_answered numeric;
  v_n_correct numeric;
  v_correct_seconds numeric;
  v_floor jsonb;
  v_floor_items int;
BEGIN
  SELECT * INTO v_row FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF NOT FOUND OR v_row.gma_total_accuracy IS NULL THEN RETURN NULL; END IF;

  SELECT count(*)::numeric INTO v_n_answered
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
  WHERE r.candidate_id = p_candidate_id
    AND i.section = 'newtworks_v2_cognitive_gma'
    AND i.cognitive_domain IS NOT NULL
    AND i.retest_of_item_number IS NULL;
  IF COALESCE(v_n_answered, 0) = 0 THEN RETURN NULL; END IF;

  v_floor := public.hiregauge_gma_chance_floor(p_candidate_id);
  v_floor_items := (v_floor->>'floor_items')::int;
  IF v_floor_items IS NOT NULL AND v_row.gma_total_accuracy < v_floor_items THEN
    RETURN NULL;
  END IF;

  SELECT count(*)::numeric, SUM(EXTRACT(EPOCH FROM (r.answered_at - r.served_at)))
    INTO v_n_correct, v_correct_seconds
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
  WHERE r.candidate_id = p_candidate_id
    AND i.section = 'newtworks_v2_cognitive_gma'
    AND i.cognitive_domain IS NOT NULL
    AND i.retest_of_item_number IS NULL
    AND r.is_correct = true;

  IF COALESCE(v_n_correct, 0) = 0 THEN RETURN NULL; END IF;
  IF v_correct_seconds IS NULL OR v_correct_seconds = 0 THEN RETURN NULL; END IF;
  RETURN ROUND(v_n_correct / (v_correct_seconds / 60.0), 2);
END;
$function$;

REVOKE ALL ON FUNCTION public.hiregauge_gma_chance_floor(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.hiregauge_gma_speed_ipm(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hiregauge_gma_chance_floor(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.hiregauge_gma_speed_ipm(uuid) TO authenticated, service_role;
