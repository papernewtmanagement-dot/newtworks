-- Step B / Item 3 — settings split + primitive refactor
-- Splits the single global LSS threshold row into _cts and _v1 variants
-- Refactors hiregauge_lss_delta_v1 primitive to (a) look up thresholds by
-- p_candidate.assessment_source (defaulting to cts when NULL) and (b) support
-- the accuracy-only path (all 3 accuracy present, all 3 speed missing) by
-- treating speed signals as neutral 0 — allowing partial-timing candidates
-- (Peter, Alvi, any candidate answering v1 before per-item timing infra was
-- live) to still route through the per-subtest signal path instead of the
-- coarse aggregate fallback.

BEGIN;

-- (1) Settings split
-- Rename current _cts row (CTS-calibrated 12-item thresholds preserved).
INSERT INTO public.settings (agency_id, setting_key, setting_value, description)
SELECT agency_id,
       'hiregauge_lss_subtest_thresholds_cts',
       setting_value,
       'HireGauge LSS subtest thresholds — CTS instrument variant (12-item pools). neutral=pass point (zero-signal). target=excellence peak (+1 signal). Grounded in CTS cohort observation.'
FROM public.settings
WHERE setting_key = 'hiregauge_lss_subtest_thresholds'
ON CONFLICT DO NOTHING;

-- (2) Add v1-instrument threshold row (scaled proportionally to v1 item pool)
--   Subtest         v1 items  Neutral  Target
--   Verbal          13        9        13
--   Math            10        8        9
--   Problem Solving 2         1        2
-- Speed thresholds carried through from CTS proportionally (per-item timing
-- means, not per-pool). CTS: verbal 52s neutral / 15s target (per item).
-- v1 uses same per-item speed budget since the items are same-difficulty
-- shape; per-item mean-response-ms will populate as timing rolls forward.
INSERT INTO public.settings (agency_id, setting_key, setting_value, description)
SELECT DISTINCT agency_id,
       'hiregauge_lss_subtest_thresholds_v1',
       jsonb_build_object(
         'verbal_acc_neutral', 9,  'verbal_acc_target', 13,
         'math_acc_neutral',   8,  'math_acc_target',    9,
         'ps_acc_neutral',     1,  'ps_acc_target',      2,
         'verbal_spd_neutral', 52, 'verbal_spd_target', 15,
         'math_spd_neutral',   50, 'math_spd_target',   18,
         'ps_spd_neutral',     77, 'ps_spd_target',     25
       )::text,
       'HireGauge LSS subtest thresholds — v1 instrument variant. Scaled proportionally to v1 item counts (verbal 13, math 10, ps 2). PS pool at n=2 has poor measurement precision even with correct thresholds; author more hard PS items to lift n>=6 (see OQ Step D). Speed thresholds carried from CTS at per-item shape — will re-calibrate empirically after N>=30 v1 candidates.'
FROM public.settings
WHERE setting_key = 'hiregauge_lss_subtest_thresholds_cts'
ON CONFLICT DO NOTHING;

-- (3) Drop the deprecated global-name row now that both variants exist
DELETE FROM public.settings
WHERE setting_key = 'hiregauge_lss_subtest_thresholds';

-- (4) Refactored primitive
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
  v_has_acc_only    boolean;
  v_has_any_lss     boolean;
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
  -- Per-instrument threshold lookup: assessment_source drives which key we
  -- read. NULL is treated as CTS (all pre-instrument-tagging candidates).
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
  v_has_acc_only    := (va IS NOT NULL AND ma IS NOT NULL AND pa IS NOT NULL
                    AND vs IS NULL AND ms IS NULL AND ps IS NULL);
  v_has_any_lss     := v_has_all_subtest OR v_has_acc_only
                    OR (va IS NOT NULL OR ma IS NOT NULL OR pa IS NOT NULL);

  IF v_has_all_subtest OR v_has_acc_only THEN
    -- Per-subtest accuracy signals (identical math both paths)
    s_va := CASE WHEN va >= va_n THEN LEAST(1.0, (va - va_n)::numeric / NULLIF(va_t - va_n, 0))
                 ELSE GREATEST(-1.0, (va - va_n)::numeric / NULLIF(va_n, 0)) END;
    s_ma := CASE WHEN ma >= ma_n THEN LEAST(1.0, (ma - ma_n)::numeric / NULLIF(ma_t - ma_n, 0))
                 ELSE GREATEST(-1.0, (ma - ma_n)::numeric / NULLIF(ma_n, 0)) END;
    s_pa := CASE WHEN pa >= pa_n THEN LEAST(1.0, (pa - pa_n)::numeric / NULLIF(pa_t - pa_n, 0))
                 ELSE GREATEST(-1.0, (pa - pa_n)::numeric / NULLIF(pa_n, 0)) END;

    IF v_has_all_subtest THEN
      -- Full path: compute speed signals + apply fast-when-wrong flip
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
      -- Accuracy-only path: speed signals are neutral (unknown speed treated
      -- as pass-point-neutral, not penalized). Enables per-subtest routing
      -- for v1 candidates who predate per-item timing but have accuracy.
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

  ELSIF v_has_any_lss THEN
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
