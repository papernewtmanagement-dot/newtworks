-- =========================================================================
-- Migration: hiregauge_lss_delta_v2 + calibration settings row
-- Step 4 kickoff for the LSS per-subtest ideal range scoring rebuild.
-- =========================================================================
-- Ships the v2 signal source alongside hiregauge_lss_delta_v1. Consumers
-- (27 competency fns + 7 role-fit fns) migrate one at a time with
-- 36-candidate cohort validation per rewire. v1 dropped in the final
-- migration of Step 4.
--
-- v2 rejects v1's per-subtest per-role ideal-range model. Emits a
-- research-backed structured signal:
--   - Intelligence composite (0-100, unit-weighted mean of subtest efficiencies)
--   - Per-subtest accuracy (0-100, proportion correct scaled)
--   - Per-subtest efficiency (0-100, accuracy modulated by log-RT speed)
--
-- Consumers apply role-appropriate floor/ceiling curves against the
-- Intelligence composite in their own bodies (2c comp-side monotonic
-- floor; 2d fit-side asymmetric under-floor exponential + over-ceiling
-- quadratic). Consumers own their competency-specific weights.
-- =========================================================================


-- 1. Calibration settings row ----------------------------------------------
-- Seeded 2026-07-31 from CTS cohort n=42 (all-three-speed complete),
-- v1 cohort n=6 (all-three-speed complete; provisional pending growth).
-- Baseline_seconds = cohort median RT (log-RT median = geometric mean;
--   robust reference per van Zandt 2000).
-- p2_5_seconds / p97_5_seconds = Ratcliff 1993 winsorization bounds.
-- Item counts verified against hiregauge_lss_subtest_thresholds_{cts,v1}
--   plus observed cohort max scores.

INSERT INTO public.settings (agency_id, setting_key, setting_value, setting_type, description, updated_by)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'hiregauge_lss_calibration_v2',
  jsonb_build_object(
    'k', 0.30,
    'meta', jsonb_build_object(
      'seeded_at', '2026-07-31',
      'citations',
        'Sheppard & Vernon 2008 (k=0.30 log-RT); Ratcliff 1993 (winsorization at 2.5/97.5); '
        || 'van Zandt 2000 (log-RT distributions); Wainer 1976 + Ree/Earles/Teachout 1994 '
        || '(unit-weighted composite within measurement error of optimal); '
        || 'Schmidt & Hunter 1998 (g monotonic for performance, r=.51); '
        || 'Jensen 1998; Salthouse 1996 (mental chronometry)',
      'notes',
        'CTS cohort n=42 (baselines stable). v1 cohort n=6 (baselines provisional; '
        || 'recalibrate when v1 cohort reaches n>=30). v1 baselines seeded from v1''s own '
        || 'cohort, not borrowed from CTS: per-item seconds differ ~1.5-2.5x between the '
        || 'two tests, so borrowing would systematically over-penalize v1 candidates for '
        || 'being "slow." Chance rate 0.25 assumes 4-option multiple choice; adjust per '
        || 'subtest if item format differs.'
    ),
    'cts', jsonb_build_object(
      'n_cohort', 42,
      'verbal',          jsonb_build_object('items', 13, 'baseline_seconds', 23.50, 'p2_5_seconds', 13.03, 'p97_5_seconds',  43.90, 'chance_rate', 0.25),
      'math',            jsonb_build_object('items', 11, 'baseline_seconds', 28.00, 'p2_5_seconds', 15.03, 'p97_5_seconds',  64.53, 'chance_rate', 0.25),
      'problem_solving', jsonb_build_object('items', 11, 'baseline_seconds', 42.50, 'p2_5_seconds', 22.00, 'p97_5_seconds', 115.33, 'chance_rate', 0.25)
    ),
    'v1', jsonb_build_object(
      'n_cohort', 6,
      'provisional', true,
      'verbal',          jsonb_build_object('items', 6, 'baseline_seconds', 17.50, 'p2_5_seconds',  9.13, 'p97_5_seconds',  74.63, 'chance_rate', 0.25),
      'math',            jsonb_build_object('items', 6, 'baseline_seconds', 26.00, 'p2_5_seconds', 15.13, 'p97_5_seconds', 178.13, 'chance_rate', 0.25),
      'problem_solving', jsonb_build_object('items', 5, 'baseline_seconds', 49.50, 'p2_5_seconds', 11.50, 'p97_5_seconds', 383.38, 'chance_rate', 0.25)
    )
  )::text,
  'json',
  'HireGauge LSS v2 calibration: per-source log-RT baselines (cohort median), Ratcliff 1993 winsorization bounds (p2.5/p97.5), item counts, chance rates. Consumed by hiregauge_lss_delta_v2. v1 baselines are provisional pending cohort growth.',
  'claude_conversation'
)
ON CONFLICT (agency_id, setting_key) DO UPDATE
SET setting_value = EXCLUDED.setting_value,
    description   = EXCLUDED.description,
    setting_type  = EXCLUDED.setting_type,
    updated_by    = EXCLUDED.updated_by,
    updated_at    = NOW();


-- 2. hiregauge_lss_delta_v2 ------------------------------------------------

CREATE OR REPLACE FUNCTION public.hiregauge_lss_delta_v2(
  p_candidate hiring_candidates
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_source text;
  v_calib jsonb;
  v_src   jsonb;
  v_k numeric;

  va_raw int := p_candidate.lss_verbal_accuracy;
  ma_raw int := p_candidate.lss_math_accuracy;
  pa_raw int := p_candidate.lss_problem_solving_accuracy;
  vs_sec int := p_candidate.lss_verbal_speed_seconds;
  ms_sec int := p_candidate.lss_math_speed_seconds;
  ps_sec int := p_candidate.lss_problem_solving_speed_seconds;

  v_items int;   m_items int;   p_items int;
  v_base numeric; m_base numeric; p_base numeric;
  v_p25 numeric;  m_p25 numeric;  p_p25 numeric;
  v_p975 numeric; m_p975 numeric; p_p975 numeric;
  v_chance numeric; m_chance numeric; p_chance numeric;

  va_prop numeric; ma_prop numeric; pa_prop numeric;
  acc_v numeric; acc_m numeric; acc_p numeric;
  eff_v numeric; eff_m numeric; eff_p numeric;
  mult_v numeric; mult_m numeric; mult_p numeric;
  t_v numeric; t_m numeric; t_p numeric;

  v_composite numeric;
  v_n_valid int := 0;
  v_path text;
  v_any_acc boolean;
  v_all_speed boolean;
BEGIN
  v_source := COALESCE(p_candidate.assessment_source, 'cts');

  SELECT setting_value::jsonb INTO v_calib
    FROM public.settings
   WHERE agency_id = p_candidate.agency_id
     AND setting_key = 'hiregauge_lss_calibration_v2';

  IF v_calib IS NULL THEN
    RAISE EXCEPTION
      'hiregauge_lss_delta_v2: calibration missing (settings.hiregauge_lss_calibration_v2 for agency %)',
      p_candidate.agency_id;
  END IF;

  v_k := (v_calib->>'k')::numeric;
  v_src := v_calib->v_source;
  IF v_src IS NULL THEN
    v_src := v_calib->'cts';
    v_source := 'cts';
  END IF;

  v_items  := (v_src->'verbal'->>'items')::int;
  v_base   := (v_src->'verbal'->>'baseline_seconds')::numeric;
  v_p25    := (v_src->'verbal'->>'p2_5_seconds')::numeric;
  v_p975   := (v_src->'verbal'->>'p97_5_seconds')::numeric;
  v_chance := (v_src->'verbal'->>'chance_rate')::numeric;

  m_items  := (v_src->'math'->>'items')::int;
  m_base   := (v_src->'math'->>'baseline_seconds')::numeric;
  m_p25    := (v_src->'math'->>'p2_5_seconds')::numeric;
  m_p975   := (v_src->'math'->>'p97_5_seconds')::numeric;
  m_chance := (v_src->'math'->>'chance_rate')::numeric;

  p_items  := (v_src->'problem_solving'->>'items')::int;
  p_base   := (v_src->'problem_solving'->>'baseline_seconds')::numeric;
  p_p25    := (v_src->'problem_solving'->>'p2_5_seconds')::numeric;
  p_p975   := (v_src->'problem_solving'->>'p97_5_seconds')::numeric;
  p_chance := (v_src->'problem_solving'->>'chance_rate')::numeric;

  v_any_acc   := (va_raw IS NOT NULL OR ma_raw IS NOT NULL OR pa_raw IS NOT NULL);
  v_all_speed := (vs_sec IS NOT NULL AND ms_sec IS NOT NULL AND ps_sec IS NOT NULL);

  IF NOT v_any_acc THEN
    RETURN jsonb_build_object(
      'path', 'no_lss_data',
      'instrument_source', v_source,
      'intelligence_composite', NULL,
      'accuracy',   jsonb_build_object('verbal', NULL, 'math', NULL, 'problem_solving', NULL),
      'efficiency', jsonb_build_object('verbal', NULL, 'math', NULL, 'problem_solving', NULL),
      'n_valid_subtests', 0
    );
  END IF;

  IF va_raw IS NOT NULL THEN
    va_prop   := va_raw::numeric / NULLIF(v_items, 0);
    acc_v     := ROUND(LEAST(100, GREATEST(0, va_prop * 100)), 2);
    v_n_valid := v_n_valid + 1;
  END IF;
  IF ma_raw IS NOT NULL THEN
    ma_prop   := ma_raw::numeric / NULLIF(m_items, 0);
    acc_m     := ROUND(LEAST(100, GREATEST(0, ma_prop * 100)), 2);
    v_n_valid := v_n_valid + 1;
  END IF;
  IF pa_raw IS NOT NULL THEN
    pa_prop   := pa_raw::numeric / NULLIF(p_items, 0);
    acc_p     := ROUND(LEAST(100, GREATEST(0, pa_prop * 100)), 2);
    v_n_valid := v_n_valid + 1;
  END IF;

  IF v_all_speed THEN
    v_path := 'per_subtest';

    IF va_raw IS NOT NULL THEN
      IF va_prop < v_chance THEN
        eff_v := 0;
      ELSIF va_prop <= v_chance THEN
        eff_v := ROUND(LEAST(100, GREATEST(0, va_prop * 100)), 2);
      ELSE
        t_v    := LEAST(v_p975, GREATEST(v_p25, vs_sec::numeric));
        mult_v := exp(-v_k * (ln(t_v) - ln(v_base)));
        eff_v  := ROUND(LEAST(100, GREATEST(0, va_prop * mult_v * 100)), 2);
      END IF;
    END IF;

    IF ma_raw IS NOT NULL THEN
      IF ma_prop < m_chance THEN
        eff_m := 0;
      ELSIF ma_prop <= m_chance THEN
        eff_m := ROUND(LEAST(100, GREATEST(0, ma_prop * 100)), 2);
      ELSE
        t_m    := LEAST(m_p975, GREATEST(m_p25, ms_sec::numeric));
        mult_m := exp(-v_k * (ln(t_m) - ln(m_base)));
        eff_m  := ROUND(LEAST(100, GREATEST(0, ma_prop * mult_m * 100)), 2);
      END IF;
    END IF;

    IF pa_raw IS NOT NULL THEN
      IF pa_prop < p_chance THEN
        eff_p := 0;
      ELSIF pa_prop <= p_chance THEN
        eff_p := ROUND(LEAST(100, GREATEST(0, pa_prop * 100)), 2);
      ELSE
        t_p    := LEAST(p_p975, GREATEST(p_p25, ps_sec::numeric));
        mult_p := exp(-v_k * (ln(t_p) - ln(p_base)));
        eff_p  := ROUND(LEAST(100, GREATEST(0, pa_prop * mult_p * 100)), 2);
      END IF;
    END IF;

    v_composite := ROUND(
      ( COALESCE(eff_v, 0) + COALESCE(eff_m, 0) + COALESCE(eff_p, 0) )
      / NULLIF(v_n_valid, 0)::numeric,
      2
    );

  ELSE
    v_path := 'per_subtest_acc_only';
    v_composite := ROUND(
      ( COALESCE(acc_v, 0) + COALESCE(acc_m, 0) + COALESCE(acc_p, 0) )
      / NULLIF(v_n_valid, 0)::numeric,
      2
    );
  END IF;

  RETURN jsonb_build_object(
    'path', v_path,
    'instrument_source', v_source,
    'intelligence_composite', v_composite,
    'accuracy', jsonb_build_object(
      'verbal', acc_v, 'math', acc_m, 'problem_solving', acc_p
    ),
    'efficiency', jsonb_build_object(
      'verbal', eff_v, 'math', eff_m, 'problem_solving', eff_p
    ),
    'n_valid_subtests', v_n_valid
  );
END;
$function$;


COMMENT ON FUNCTION public.hiregauge_lss_delta_v2(hiring_candidates)
IS 'HireGauge LSS Step 4 signal source. Emits Intelligence composite + per-subtest accuracy + per-subtest efficiency. Consumers (27 competency fns + 7 role-fit fns) apply role-appropriate floor/ceiling curves. Migrates alongside hiregauge_lss_delta_v1; v1 dropped after all 34 callers rewired and cohort-validated. See open_questions "LSS per-subtest ideal range scoring — build + rewire".';

