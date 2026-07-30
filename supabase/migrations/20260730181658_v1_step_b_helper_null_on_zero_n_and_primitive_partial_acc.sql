-- Step B follow-up: two coordinated fixes for the "candidate saw 0 items in a domain"
-- case exposed by Peter+Alvi backfill (both had 0 problem_solving items served).
-- 1) apply_newtworks_v1_lss_to_candidate writes NULL for a domain accuracy when
--    the candidate saw zero items in that domain — storing 0 would tell the
--    primitive "candidate got 0/2 PS correct" (deep-negative signal) instead of
--    the truth ("we don't know").
-- 2) hiregauge_lss_delta_v1 relaxes per_subtest_acc_only to allow ANY subset of
--    accuracy cols non-null (missing acc -> signal=0 -> term drops out). Preserves
--    original per_subtest full path exactly.

BEGIN;

CREATE OR REPLACE FUNCTION public.apply_newtworks_v1_lss_to_candidate(p_candidate_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_agency_id uuid;
  v_verbal_acc int;
  v_math_acc int;
  v_ps_acc int;
  v_total_acc int;
  v_verbal_spd int;
  v_math_spd int;
  v_ps_spd int;
  v_verbal_n int;
  v_math_n int;
  v_ps_n int;
BEGIN
  SELECT agency_id INTO v_agency_id FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF v_agency_id IS NULL THEN
    RETURN jsonb_build_object('error','candidate_not_found','candidate_id', p_candidate_id);
  END IF;

  SELECT
    count(*) FILTER (WHERE i.cognitive_domain = 'verbal'          AND r.is_correct)::int,
    count(*) FILTER (WHERE i.cognitive_domain = 'math'            AND r.is_correct)::int,
    count(*) FILTER (WHERE i.cognitive_domain = 'problem_solving' AND r.is_correct)::int,
    count(*) FILTER (WHERE i.cognitive_domain = 'verbal'         )::int,
    count(*) FILTER (WHERE i.cognitive_domain = 'math'           )::int,
    count(*) FILTER (WHERE i.cognitive_domain = 'problem_solving')::int,
    ROUND(AVG(EXTRACT(EPOCH FROM (r.answered_at - r.served_at)))
      FILTER (WHERE i.cognitive_domain = 'verbal'
              AND r.served_at IS NOT NULL AND r.answered_at IS NOT NULL))::int,
    ROUND(AVG(EXTRACT(EPOCH FROM (r.answered_at - r.served_at)))
      FILTER (WHERE i.cognitive_domain = 'math'
              AND r.served_at IS NOT NULL AND r.answered_at IS NOT NULL))::int,
    ROUND(AVG(EXTRACT(EPOCH FROM (r.answered_at - r.served_at)))
      FILTER (WHERE i.cognitive_domain = 'problem_solving'
              AND r.served_at IS NOT NULL AND r.answered_at IS NOT NULL))::int
  INTO v_verbal_acc, v_math_acc, v_ps_acc,
       v_verbal_n, v_math_n, v_ps_n,
       v_verbal_spd, v_math_spd, v_ps_spd
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON r.item_id = i.id
  WHERE r.candidate_id = p_candidate_id
    AND i.section = 'cognitive'
    AND i.cognitive_domain IS NOT NULL
    AND i.retest_of_item_number IS NULL;

  IF (v_verbal_n + v_math_n + v_ps_n) = 0 THEN
    RETURN jsonb_build_object(
      'candidate_id', p_candidate_id,
      'wrote', false,
      'reason', 'no_v1_cognitive_responses'
    );
  END IF;

  -- NULL out per-domain accuracy when candidate saw zero items in that domain.
  -- Storing 0 would misrepresent "not asked" as "got 0/N correct" and produce
  -- a false deep-negative signal downstream.
  IF v_verbal_n = 0 THEN v_verbal_acc := NULL; END IF;
  IF v_math_n   = 0 THEN v_math_acc   := NULL; END IF;
  IF v_ps_n     = 0 THEN v_ps_acc     := NULL; END IF;

  v_total_acc := COALESCE(v_verbal_acc, 0) + COALESCE(v_math_acc, 0) + COALESCE(v_ps_acc, 0);

  UPDATE public.hiring_candidates SET
    lss_verbal_accuracy          = v_verbal_acc,
    lss_math_accuracy            = v_math_acc,
    lss_problem_solving_accuracy = v_ps_acc,
    lss_total_accuracy           = v_total_acc,
    lss_verbal_speed_seconds     = v_verbal_spd,
    lss_math_speed_seconds       = v_math_spd,
    lss_problem_solving_speed_seconds = v_ps_spd,
    updated_at = now()
  WHERE id = p_candidate_id;

  RETURN jsonb_build_object(
    'candidate_id', p_candidate_id,
    'wrote', true,
    'accuracy', jsonb_build_object(
      'verbal', jsonb_build_object('correct', v_verbal_acc, 'n', v_verbal_n),
      'math',   jsonb_build_object('correct', v_math_acc,   'n', v_math_n),
      'problem_solving', jsonb_build_object('correct', v_ps_acc, 'n', v_ps_n),
      'total', v_total_acc
    ),
    'speed_seconds', jsonb_build_object(
      'verbal', v_verbal_spd,
      'math',   v_math_spd,
      'problem_solving', v_ps_spd
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.hiregauge_lss_delta_v1(
  p_candidate hiring_candidates,
  p_weights jsonb,
  p_thresholds jsonb DEFAULT NULL::jsonb
) RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $function$
DECLARE
  v_source text;
  v_settings_key text;
  v_global_thresh jsonb;
  va int := p_candidate.lss_verbal_accuracy;
  ma int := p_candidate.lss_math_accuracy;
  pa int := p_candidate.lss_problem_solving_accuracy;
  vs int := p_candidate.lss_verbal_speed_seconds;
  ms int := p_candidate.lss_math_speed_seconds;
  ps int := p_candidate.lss_problem_solving_speed_seconds;
  v_has_all_subtest boolean;
  v_all_speed_null  boolean;
  v_any_acc         boolean;
  v_any_lss         boolean;
  s_va numeric; s_ma numeric; s_pa numeric;
  s_vs numeric; s_ms numeric; s_ps numeric;
  va_n int; va_t int; ma_n int; ma_t int; pa_n int; pa_t int;
  vs_n int; vs_t int; ms_n int; ms_t int; ps_n int; ps_t int;
  agg_acc_flags int; agg_spd_flags int;
  agg_acc_signal numeric; agg_spd_signal numeric;
  w_va numeric; w_ma numeric; w_pa numeric;
  w_vs numeric; w_ms numeric; w_ps numeric;
  w_acc_agg numeric; w_spd_agg numeric;
  v_lin_signal numeric := 0;
  v_delta numeric := 0;
  v_effective_thresh jsonb;
BEGIN
  v_source := COALESCE(p_candidate.assessment_source, 'cts');
  v_settings_key := CASE v_source
    WHEN 'v1' THEN 'hiregauge_lss_subtest_thresholds_v1'
    ELSE           'hiregauge_lss_subtest_thresholds_cts'
  END;
  SELECT setting_value::jsonb INTO v_global_thresh
    FROM public.settings
   WHERE agency_id = p_candidate.agency_id AND setting_key = v_settings_key;

  v_effective_thresh := COALESCE(p_thresholds, '{}'::jsonb);
  va_n := COALESCE((v_effective_thresh->>'verbal_acc_neutral')::int, (v_global_thresh->>'verbal_acc_neutral')::int);
  va_t := COALESCE((v_effective_thresh->>'verbal_acc_target')::int,  (v_global_thresh->>'verbal_acc_target')::int);
  ma_n := COALESCE((v_effective_thresh->>'math_acc_neutral')::int,   (v_global_thresh->>'math_acc_neutral')::int);
  ma_t := COALESCE((v_effective_thresh->>'math_acc_target')::int,    (v_global_thresh->>'math_acc_target')::int);
  pa_n := COALESCE((v_effective_thresh->>'ps_acc_neutral')::int,     (v_global_thresh->>'ps_acc_neutral')::int);
  pa_t := COALESCE((v_effective_thresh->>'ps_acc_target')::int,      (v_global_thresh->>'ps_acc_target')::int);
  vs_n := COALESCE((v_effective_thresh->>'verbal_spd_neutral')::int, (v_global_thresh->>'verbal_spd_neutral')::int);
  vs_t := COALESCE((v_effective_thresh->>'verbal_spd_target')::int,  (v_global_thresh->>'verbal_spd_target')::int);
  ms_n := COALESCE((v_effective_thresh->>'math_spd_neutral')::int,   (v_global_thresh->>'math_spd_neutral')::int);
  ms_t := COALESCE((v_effective_thresh->>'math_spd_target')::int,    (v_global_thresh->>'math_spd_target')::int);
  ps_n := COALESCE((v_effective_thresh->>'ps_spd_neutral')::int,     (v_global_thresh->>'ps_spd_neutral')::int);
  ps_t := COALESCE((v_effective_thresh->>'ps_spd_target')::int,      (v_global_thresh->>'ps_spd_target')::int);

  w_va := COALESCE((p_weights->>'verbal_acc')::numeric, 0);
  w_ma := COALESCE((p_weights->>'math_acc')::numeric, 0);
  w_pa := COALESCE((p_weights->>'ps_acc')::numeric, 0);
  w_vs := COALESCE((p_weights->>'verbal_spd')::numeric, 0);
  w_ms := COALESCE((p_weights->>'math_spd')::numeric, 0);
  w_ps := COALESCE((p_weights->>'ps_spd')::numeric, 0);
  w_acc_agg := COALESCE((p_weights->>'acc_aggregate')::numeric, 0);
  w_spd_agg := COALESCE((p_weights->>'spd_aggregate')::numeric, 0);

  v_has_all_subtest := (va IS NOT NULL AND ma IS NOT NULL AND pa IS NOT NULL
                    AND vs IS NOT NULL AND ms IS NOT NULL AND ps IS NOT NULL);
  v_all_speed_null  := (vs IS NULL AND ms IS NULL AND ps IS NULL);
  v_any_acc         := (va IS NOT NULL OR ma IS NOT NULL OR pa IS NOT NULL);
  v_any_lss         := v_any_acc;

  IF v_has_all_subtest OR (v_all_speed_null AND v_any_acc) THEN
    s_va := CASE
              WHEN va IS NULL THEN 0
              WHEN va >= va_n THEN LEAST(1.0, (va - va_n)::numeric / NULLIF(va_t - va_n, 0))
              ELSE GREATEST(-1.0, (va - va_n)::numeric / NULLIF(va_n, 0))
            END;
    s_ma := CASE
              WHEN ma IS NULL THEN 0
              WHEN ma >= ma_n THEN LEAST(1.0, (ma - ma_n)::numeric / NULLIF(ma_t - ma_n, 0))
              ELSE GREATEST(-1.0, (ma - ma_n)::numeric / NULLIF(ma_n, 0))
            END;
    s_pa := CASE
              WHEN pa IS NULL THEN 0
              WHEN pa >= pa_n THEN LEAST(1.0, (pa - pa_n)::numeric / NULLIF(pa_t - pa_n, 0))
              ELSE GREATEST(-1.0, (pa - pa_n)::numeric / NULLIF(pa_n, 0))
            END;

    IF v_has_all_subtest THEN
      s_vs := CASE WHEN vs <= vs_n THEN LEAST(1.0, (vs_n - vs)::numeric / NULLIF(vs_n - vs_t, 0))
                   ELSE GREATEST(-1.0, (vs_n - vs)::numeric / NULLIF(vs_n, 0)) END;
      s_ms := CASE WHEN ms <= ms_n THEN LEAST(1.0, (ms_n - ms)::numeric / NULLIF(ms_n - ms_t, 0))
                   ELSE GREATEST(-1.0, (ms_n - ms)::numeric / NULLIF(ms_n, 0)) END;
      s_ps := CASE WHEN ps <= ps_n THEN LEAST(1.0, (ps_n - ps)::numeric / NULLIF(ps_n - ps_t, 0))
                   ELSE GREATEST(-1.0, (ps_n - ps)::numeric / NULLIF(ps_n, 0)) END;

      IF w_vs > 0 AND s_va < 0 AND s_vs > 0 THEN s_vs := -s_vs; END IF;
      IF w_ms > 0 AND s_ma < 0 AND s_ms > 0 THEN s_ms := -s_ms; END IF;
      IF w_ps > 0 AND s_pa < 0 AND s_ps > 0 THEN s_ps := -s_ps; END IF;
    ELSE
      s_vs := 0; s_ms := 0; s_ps := 0;
    END IF;

    v_lin_signal := w_va*s_va + w_ma*s_ma + w_pa*s_pa + w_vs*s_vs + w_ms*s_ms + w_ps*s_ps;
    v_delta := 15.0 * v_lin_signal;
    IF v_lin_signal < 0 THEN v_delta := v_delta - 20.0 * v_lin_signal * v_lin_signal; END IF;

    RETURN jsonb_build_object(
      'delta', ROUND(v_delta, 2),
      'path', CASE WHEN v_has_all_subtest THEN 'per_subtest' ELSE 'per_subtest_acc_only' END,
      'instrument_source', v_source,
      'signals', jsonb_build_object(
        'verbal_acc', ROUND(s_va, 3), 'math_acc', ROUND(s_ma, 3), 'ps_acc', ROUND(s_pa, 3),
        'verbal_spd', ROUND(s_vs, 3), 'math_spd', ROUND(s_ms, 3), 'ps_spd', ROUND(s_ps, 3)),
      'lin_signal', ROUND(v_lin_signal, 3)
    );

  ELSIF v_any_lss THEN
    agg_acc_flags := (CASE WHEN va IS NOT NULL AND va >= va_n THEN 1 ELSE 0 END)
                   + (CASE WHEN ma IS NOT NULL AND ma >= ma_n THEN 1 ELSE 0 END)
                   + (CASE WHEN pa IS NOT NULL AND pa >= pa_n THEN 1 ELSE 0 END);
    agg_spd_flags := (CASE WHEN vs IS NOT NULL AND vs <= vs_n THEN 1 ELSE 0 END)
                   + (CASE WHEN ms IS NOT NULL AND ms <= ms_n THEN 1 ELSE 0 END)
                   + (CASE WHEN ps IS NOT NULL AND ps <= ps_n THEN 1 ELSE 0 END);
    agg_acc_signal := (agg_acc_flags - 1.5) / 1.5;
    agg_spd_signal := (agg_spd_flags - 1.5) / 1.5;
    IF w_spd_agg > 0 AND agg_acc_signal < 0 AND agg_spd_signal > 0 THEN agg_spd_signal := -agg_spd_signal; END IF;
    v_lin_signal := (w_acc_agg * agg_acc_signal + w_spd_agg * agg_spd_signal) / 2.0;
    v_delta := 15.0 * v_lin_signal;
    IF v_lin_signal < 0 THEN v_delta := v_delta - 20.0 * v_lin_signal * v_lin_signal; END IF;

    RETURN jsonb_build_object(
      'delta', ROUND(v_delta, 2),
      'path', 'aggregate_fallback',
      'instrument_source', v_source,
      'acc_flags', agg_acc_flags, 'acc_signal', ROUND(agg_acc_signal, 3),
      'spd_flags', agg_spd_flags, 'spd_signal', ROUND(agg_spd_signal, 3),
      'lin_signal', ROUND(v_lin_signal, 3)
    );
  ELSE
    RETURN jsonb_build_object('delta', 0, 'path', 'no_lss_data', 'instrument_source', v_source);
  END IF;
END;
$function$;

COMMIT;
