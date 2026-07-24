-- 20260724022557_hiregauge_lss_delta_primitive_v1_1_skip_flip_neg_weights.sql
-- Bug fix v1.1 for hiregauge_lss_delta_v1 primitive.
--
-- Problem in initial v1 (20260724022121): fast-when-wrong flip did not check
-- weight sign. On competencies with NEGATIVE speed weights (e.g. attention_to_detail
-- which uses -0.05/-0.05/-0.10 for verbal_spd/math_spd/ps_spd), the flip
-- would fire and then the negative weight would double-flip the sign,
-- producing a positive contribution from a low-accuracy fast candidate.
--
-- Fix: gate every flip on (weight > 0). Negative weights already model
-- "fast HURTS this competency" — no additional flip needed. Signature
-- unchanged, so this CREATE OR REPLACE swaps the body cleanly.
--
-- Signature: hiregauge_lss_delta_v1(hiring_candidates, jsonb, jsonb) RETURNS jsonb

CREATE OR REPLACE FUNCTION public.hiregauge_lss_delta_v1(p_candidate hiring_candidates, p_weights jsonb, p_thresholds jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_global_thresh jsonb;
  va int := p_candidate.lss_verbal_accuracy;
  ma int := p_candidate.lss_math_accuracy;
  pa int := p_candidate.lss_problem_solving_accuracy;
  vs int := p_candidate.lss_verbal_speed_seconds;
  ms int := p_candidate.lss_math_speed_seconds;
  ps int := p_candidate.lss_problem_solving_speed_seconds;
  v_has_subtest boolean;
  v_has_lss boolean;
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
  SELECT setting_value::jsonb INTO v_global_thresh FROM public.settings
  WHERE agency_id = p_candidate.agency_id AND setting_key = 'hiregauge_lss_subtest_thresholds';
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

  v_has_subtest := (va IS NOT NULL AND ma IS NOT NULL AND pa IS NOT NULL
                AND vs IS NOT NULL AND ms IS NOT NULL AND ps IS NOT NULL);
  v_has_lss := v_has_subtest OR (va IS NOT NULL OR ma IS NOT NULL OR pa IS NOT NULL);

  IF v_has_subtest THEN
    s_va := CASE WHEN va >= va_n THEN LEAST(1.0, (va - va_n)::numeric / NULLIF(va_t - va_n, 0))
                 ELSE GREATEST(-1.0, (va - va_n)::numeric / NULLIF(va_n, 0)) END;
    s_ma := CASE WHEN ma >= ma_n THEN LEAST(1.0, (ma - ma_n)::numeric / NULLIF(ma_t - ma_n, 0))
                 ELSE GREATEST(-1.0, (ma - ma_n)::numeric / NULLIF(ma_n, 0)) END;
    s_pa := CASE WHEN pa >= pa_n THEN LEAST(1.0, (pa - pa_n)::numeric / NULLIF(pa_t - pa_n, 0))
                 ELSE GREATEST(-1.0, (pa - pa_n)::numeric / NULLIF(pa_n, 0)) END;
    s_vs := CASE WHEN vs <= vs_n THEN LEAST(1.0, (vs_n - vs)::numeric / NULLIF(vs_n - vs_t, 0))
                 ELSE GREATEST(-1.0, (vs_n - vs)::numeric / NULLIF(vs_n, 0)) END;
    s_ms := CASE WHEN ms <= ms_n THEN LEAST(1.0, (ms_n - ms)::numeric / NULLIF(ms_n - ms_t, 0))
                 ELSE GREATEST(-1.0, (ms_n - ms)::numeric / NULLIF(ms_n, 0)) END;
    s_ps := CASE WHEN ps <= ps_n THEN LEAST(1.0, (ps_n - ps)::numeric / NULLIF(ps_n - ps_t, 0))
                 ELSE GREATEST(-1.0, (ps_n - ps)::numeric / NULLIF(ps_n, 0)) END;

    -- Per-subtest fast-when-wrong flip — SKIP when speed weight is <= 0 (already handled by weight sign)
    IF w_vs > 0 AND s_va < 0 AND s_vs > 0 THEN s_vs := -s_vs; END IF;
    IF w_ms > 0 AND s_ma < 0 AND s_ms > 0 THEN s_ms := -s_ms; END IF;
    IF w_ps > 0 AND s_pa < 0 AND s_ps > 0 THEN s_ps := -s_ps; END IF;

    v_lin_signal := w_va*s_va + w_ma*s_ma + w_pa*s_pa + w_vs*s_vs + w_ms*s_ms + w_ps*s_ps;
    v_delta := 15.0 * v_lin_signal;
    IF v_lin_signal < 0 THEN v_delta := v_delta - 20.0 * v_lin_signal * v_lin_signal; END IF;
    RETURN jsonb_build_object('delta', ROUND(v_delta, 2), 'path', 'per_subtest',
      'signals', jsonb_build_object('verbal_acc', ROUND(s_va, 3), 'math_acc', ROUND(s_ma, 3), 'ps_acc', ROUND(s_pa, 3),
        'verbal_spd', ROUND(s_vs, 3), 'math_spd', ROUND(s_ms, 3), 'ps_spd', ROUND(s_ps, 3)),
      'lin_signal', ROUND(v_lin_signal, 3));
  ELSIF v_has_lss THEN
    agg_acc_flags := (CASE WHEN va >= va_n THEN 1 ELSE 0 END) + (CASE WHEN ma >= ma_n THEN 1 ELSE 0 END) + (CASE WHEN pa >= pa_n THEN 1 ELSE 0 END);
    agg_spd_flags := (CASE WHEN vs <= vs_n THEN 1 ELSE 0 END) + (CASE WHEN ms <= ms_n THEN 1 ELSE 0 END) + (CASE WHEN ps <= ps_n THEN 1 ELSE 0 END);
    agg_acc_signal := (agg_acc_flags - 1.5) / 1.5;
    agg_spd_signal := (agg_spd_flags - 1.5) / 1.5;
    -- Aggregate flip also gated on positive weight
    IF w_spd_agg > 0 AND agg_acc_signal < 0 AND agg_spd_signal > 0 THEN agg_spd_signal := -agg_spd_signal; END IF;
    v_lin_signal := (w_acc_agg * agg_acc_signal + w_spd_agg * agg_spd_signal) / 2.0;
    v_delta := 15.0 * v_lin_signal;
    IF v_lin_signal < 0 THEN v_delta := v_delta - 20.0 * v_lin_signal * v_lin_signal; END IF;
    RETURN jsonb_build_object('delta', ROUND(v_delta, 2), 'path', 'aggregate_fallback',
      'acc_flags', agg_acc_flags, 'acc_signal', ROUND(agg_acc_signal, 3),
      'spd_flags', agg_spd_flags, 'spd_signal', ROUND(agg_spd_signal, 3),
      'lin_signal', ROUND(v_lin_signal, 3));
  ELSE
    RETURN jsonb_build_object('delta', 0, 'path', 'no_lss_data');
  END IF;
END; $function$
;
