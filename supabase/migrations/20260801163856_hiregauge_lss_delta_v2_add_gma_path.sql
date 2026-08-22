CREATE OR REPLACE FUNCTION public.hiregauge_lss_delta_v2(p_candidate hiring_candidates)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_source text;
  v_calib jsonb;
  v_src   jsonb;
  v_k numeric;

  -- ===== NEW 4-domain GMA fields =====
  gp_raw int := p_candidate.gma_pattern_accuracy;
  gd_raw int := p_candidate.gma_deductive_accuracy;
  gn_raw int := p_candidate.gma_numerical_accuracy;
  gv_raw int := p_candidate.gma_verbal_accuracy;
  gp_sec int := p_candidate.gma_pattern_speed_seconds;
  gd_sec int := p_candidate.gma_deductive_speed_seconds;
  gn_sec int := p_candidate.gma_numerical_speed_seconds;
  gv_sec int := p_candidate.gma_verbal_speed_seconds;
  v_any_gma_acc boolean;

  gp_items int; gd_items int; gn_items int; gv_items int;
  gp_base numeric; gd_base numeric; gn_base numeric; gv_base numeric;
  gp_p25 numeric;  gd_p25 numeric;  gn_p25 numeric;  gv_p25 numeric;
  gp_p975 numeric; gd_p975 numeric; gn_p975 numeric; gv_p975 numeric;
  gp_chance numeric; gd_chance numeric; gn_chance numeric; gv_chance numeric;

  gp_prop numeric; gd_prop numeric; gn_prop numeric; gv_prop numeric;
  gacc_p numeric; gacc_d numeric; gacc_n numeric; gacc_v numeric;
  geff_p numeric; geff_d numeric; geff_n numeric; geff_v numeric;
  gmult_p numeric; gmult_d numeric; gmult_n numeric; gmult_v numeric;
  gt_p numeric; gt_d numeric; gt_n numeric; gt_v numeric;

  v_gma_composite numeric;
  v_gma_n_valid int := 0;
  v_gma_path text;
  v_gma_all_speed boolean;

  -- ===== LEGACY 3-domain LSS fields (unchanged) =====
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
  v_any_gma_acc := (gp_raw IS NOT NULL OR gd_raw IS NOT NULL OR gn_raw IS NOT NULL OR gv_raw IS NOT NULL);

  -- =========================================================================
  -- PATH A: candidate has GMA v2 (4-domain) data saved -- take this path
  -- regardless of assessment_source, since presence of the gma_* columns is
  -- the actual signal, per Peter's spec.
  -- =========================================================================
  IF v_any_gma_acc THEN
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
    v_src := v_calib->'gma';
    IF v_src IS NULL THEN
      RAISE EXCEPTION
        'hiregauge_lss_delta_v2: gma calibration block missing in hiregauge_lss_calibration_v2 for agency % -- seed settings.hiregauge_lss_calibration_v2->gma with items/baseline_seconds/p2_5_seconds/p97_5_seconds/chance_rate per domain before scoring GMA candidates',
        p_candidate.agency_id;
    END IF;

    gp_items := (v_src->'pattern'->>'items')::int;
    gp_base  := (v_src->'pattern'->>'baseline_seconds')::numeric;
    gp_p25   := (v_src->'pattern'->>'p2_5_seconds')::numeric;
    gp_p975  := (v_src->'pattern'->>'p97_5_seconds')::numeric;
    gp_chance:= (v_src->'pattern'->>'chance_rate')::numeric;

    gd_items := (v_src->'deductive'->>'items')::int;
    gd_base  := (v_src->'deductive'->>'baseline_seconds')::numeric;
    gd_p25   := (v_src->'deductive'->>'p2_5_seconds')::numeric;
    gd_p975  := (v_src->'deductive'->>'p97_5_seconds')::numeric;
    gd_chance:= (v_src->'deductive'->>'chance_rate')::numeric;

    gn_items := (v_src->'numerical'->>'items')::int;
    gn_base  := (v_src->'numerical'->>'baseline_seconds')::numeric;
    gn_p25   := (v_src->'numerical'->>'p2_5_seconds')::numeric;
    gn_p975  := (v_src->'numerical'->>'p97_5_seconds')::numeric;
    gn_chance:= (v_src->'numerical'->>'chance_rate')::numeric;

    gv_items := (v_src->'verbal'->>'items')::int;
    gv_base  := (v_src->'verbal'->>'baseline_seconds')::numeric;
    gv_p25   := (v_src->'verbal'->>'p2_5_seconds')::numeric;
    gv_p975  := (v_src->'verbal'->>'p97_5_seconds')::numeric;
    gv_chance:= (v_src->'verbal'->>'chance_rate')::numeric;

    v_gma_all_speed := (gp_sec IS NOT NULL AND gd_sec IS NOT NULL AND gn_sec IS NOT NULL AND gv_sec IS NOT NULL);

    IF gp_raw IS NOT NULL THEN
      gp_prop := gp_raw::numeric / NULLIF(gp_items, 0);
      gacc_p  := ROUND(LEAST(100, GREATEST(0, gp_prop * 100)), 2);
      v_gma_n_valid := v_gma_n_valid + 1;
    END IF;
    IF gd_raw IS NOT NULL THEN
      gd_prop := gd_raw::numeric / NULLIF(gd_items, 0);
      gacc_d  := ROUND(LEAST(100, GREATEST(0, gd_prop * 100)), 2);
      v_gma_n_valid := v_gma_n_valid + 1;
    END IF;
    IF gn_raw IS NOT NULL THEN
      gn_prop := gn_raw::numeric / NULLIF(gn_items, 0);
      gacc_n  := ROUND(LEAST(100, GREATEST(0, gn_prop * 100)), 2);
      v_gma_n_valid := v_gma_n_valid + 1;
    END IF;
    IF gv_raw IS NOT NULL THEN
      gv_prop := gv_raw::numeric / NULLIF(gv_items, 0);
      gacc_v  := ROUND(LEAST(100, GREATEST(0, gv_prop * 100)), 2);
      v_gma_n_valid := v_gma_n_valid + 1;
    END IF;

    IF v_gma_all_speed THEN
      v_gma_path := 'gma_per_subtest';

      IF gp_raw IS NOT NULL THEN
        IF gp_prop < gp_chance THEN geff_p := 0;
        ELSIF gp_prop <= gp_chance THEN geff_p := ROUND(LEAST(100, GREATEST(0, gp_prop * 100)), 2);
        ELSE
          gt_p := LEAST(gp_p975, GREATEST(gp_p25, gp_sec::numeric));
          gmult_p := exp(-v_k * (ln(gt_p) - ln(gp_base)));
          geff_p := ROUND(LEAST(100, GREATEST(0, gp_prop * gmult_p * 100)), 2);
        END IF;
      END IF;

      IF gd_raw IS NOT NULL THEN
        IF gd_prop < gd_chance THEN geff_d := 0;
        ELSIF gd_prop <= gd_chance THEN geff_d := ROUND(LEAST(100, GREATEST(0, gd_prop * 100)), 2);
        ELSE
          gt_d := LEAST(gd_p975, GREATEST(gd_p25, gd_sec::numeric));
          gmult_d := exp(-v_k * (ln(gt_d) - ln(gd_base)));
          geff_d := ROUND(LEAST(100, GREATEST(0, gd_prop * gmult_d * 100)), 2);
        END IF;
      END IF;

      IF gn_raw IS NOT NULL THEN
        IF gn_prop < gn_chance THEN geff_n := 0;
        ELSIF gn_prop <= gn_chance THEN geff_n := ROUND(LEAST(100, GREATEST(0, gn_prop * 100)), 2);
        ELSE
          gt_n := LEAST(gn_p975, GREATEST(gn_p25, gn_sec::numeric));
          gmult_n := exp(-v_k * (ln(gt_n) - ln(gn_base)));
          geff_n := ROUND(LEAST(100, GREATEST(0, gn_prop * gmult_n * 100)), 2);
        END IF;
      END IF;

      IF gv_raw IS NOT NULL THEN
        IF gv_prop < gv_chance THEN geff_v := 0;
        ELSIF gv_prop <= gv_chance THEN geff_v := ROUND(LEAST(100, GREATEST(0, gv_prop * 100)), 2);
        ELSE
          gt_v := LEAST(gv_p975, GREATEST(gv_p25, gv_sec::numeric));
          gmult_v := exp(-v_k * (ln(gt_v) - ln(gv_base)));
          geff_v := ROUND(LEAST(100, GREATEST(0, gv_prop * gmult_v * 100)), 2);
        END IF;
      END IF;

      v_gma_composite := ROUND(
        (COALESCE(geff_p,0) + COALESCE(geff_d,0) + COALESCE(geff_n,0) + COALESCE(geff_v,0))
        / NULLIF(v_gma_n_valid, 0)::numeric, 2
      );
    ELSE
      v_gma_path := 'gma_per_subtest_acc_only';
      v_gma_composite := ROUND(
        (COALESCE(gacc_p,0) + COALESCE(gacc_d,0) + COALESCE(gacc_n,0) + COALESCE(gacc_v,0))
        / NULLIF(v_gma_n_valid, 0)::numeric, 2
      );
    END IF;

    RETURN jsonb_build_object(
      'path', v_gma_path,
      'instrument_source', 'gma',
      'intelligence_composite', v_gma_composite,
      'accuracy', jsonb_build_object(
        'pattern', gacc_p, 'deductive', gacc_d, 'numerical', gacc_n, 'verbal', gacc_v
      ),
      'efficiency', jsonb_build_object(
        'pattern', geff_p, 'deductive', geff_d, 'numerical', geff_n, 'verbal', geff_v
      ),
      'n_valid_subtests', v_gma_n_valid
    );
  END IF;

  -- =========================================================================
  -- PATH B: legacy 3-domain LSS data (CTS or v1) -- unchanged from prior version
  -- =========================================================================
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
