-- Step 5 fn #1 of 7: assessment_role_fit_sales_outbound v2 LSS 2d rewire
--
-- Adds the LSS 2d role-fit curve on top of the existing weighted-competency
-- composite. Two multipliers applied at the role scale to composite intelligence:
--   1. Below-floor exponential (k=3.0) via hiregauge_lss_penalty_v2 helper.
--   2. Above-ceiling quadratic (coeff 0.4) via hiregauge_lss_ceiling_penalty_v2 helper.
--
-- Range for sales_outbound: floor 55, ceiling 90 per hiregauge_role_ideal_ranges.
--
-- Compounds with per-competency 2c penalty already baked into each competency
-- adjusted value (each of the 25 competency inputs already has its own
-- per-competency LSS multiplier applied at composite × per-competency floor).
--
-- Base formula weights, drive_gated gate, hwe_gated gate, overthinker penalty,
-- and clamp range [0,100] all unchanged from v3.9. Meta enriched with LSS
-- provenance fields for auditability.

CREATE OR REPLACE FUNCTION public.assessment_role_fit_sales_outbound(p_assessment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  ta hiring_candidates;
  s jsonb;
  drive_gated numeric;
  hwe_gated numeric;
  fit numeric;
  fit_base numeric;
  v_lss jsonb;
  v_composite numeric;
  v_floor numeric;
  v_ceiling numeric;
  v_floor_mult numeric;
  v_ceiling_mult numeric;
  v_lss_mult numeric;
BEGIN
  SELECT * INTO ta FROM public.hiring_candidates WHERE id = p_assessment_id;
  IF NOT FOUND OR ta.deadline_motivation IS NULL THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'sales_outbound');
  END IF;

  s := jsonb_build_object(
    'maintains_high_activity',         (public.assessment_competency_maintains_high_activity(ta)         ->> 'adjusted')::numeric,
    'handles_rejection',               (public.assessment_competency_handles_rejection(ta)               ->> 'adjusted')::numeric,
    'handles_objections',              (public.assessment_competency_handles_objections(ta)              ->> 'adjusted')::numeric,
    'dials_cold_calls',                (public.assessment_competency_dials_cold_calls(ta)                ->> 'adjusted')::numeric,
    'analytical',                      (public.assessment_competency_analytical(ta)                      ->> 'adjusted')::numeric,
    'presents_solutions',              (public.assessment_competency_presents_solutions(ta)              ->> 'adjusted')::numeric,
    'listens_discovers_needs',         (public.assessment_competency_listens_discovers_needs(ta)         ->> 'adjusted')::numeric,
    'works_without_close_supervision', (public.assessment_competency_works_without_close_supervision(ta) ->> 'adjusted')::numeric,
    'competes_for_recognition',        (public.assessment_competency_competes_for_recognition(ta)        ->> 'adjusted')::numeric,
    'rapid_rapport_warm',              (public.assessment_competency_rapid_rapport_warm(ta)              ->> 'adjusted')::numeric,
    'cadence_compliance',              (public.assessment_competency_cadence_compliance(ta)              ->> 'adjusted')::numeric,
    'makes_decisions_quickly',         (public.assessment_competency_makes_decisions_quickly(ta)         ->> 'adjusted')::numeric,
    'is_fast_start_oriented',          (public.assessment_competency_is_fast_start_oriented(ta)          ->> 'adjusted')::numeric,
    'has_entrepreneurial_spirit',      (public.assessment_competency_has_entrepreneurial_spirit(ta)      ->> 'adjusted')::numeric,
    'receives_coaching',               (public.assessment_competency_receives_coaching(ta)               ->> 'adjusted')::numeric,
    'queue_throughput_discipline',     (public.assessment_competency_queue_throughput_discipline(ta)     ->> 'adjusted')::numeric,
    'attention_to_detail',             (public.assessment_competency_attention_to_detail(ta)             ->> 'adjusted')::numeric,
    'prospects_in_community',          (public.assessment_competency_prospects_in_community(ta)          ->> 'adjusted')::numeric,
    'positively_influences_team',      (public.assessment_competency_positively_influences_team(ta)      ->> 'adjusted')::numeric,
    'routing_judgment',                (public.assessment_competency_routing_judgment(ta)                ->> 'adjusted')::numeric,
    'retention_watchfulness',          (public.assessment_competency_retention_watchfulness(ta)          ->> 'adjusted')::numeric,
    'signal_hwe',                      (public.assessment_signal_hwe(ta)                                 ->> 'adjusted')::numeric,
    'signal_drive_engine',             (public.assessment_signal_drive_engine(ta)                        ->> 'adjusted')::numeric,
    'signal_honesty',                  (public.assessment_signal_honesty(ta)                             ->> 'adjusted')::numeric,
    'signal_overthinker_penalty',      (public.assessment_signal_overthinker_penalty(ta)                 ->> 'adjusted')::numeric
  );

  drive_gated := CASE
    WHEN (s->>'signal_drive_engine')::numeric < 50 THEN 0
    WHEN (s->>'signal_drive_engine')::numeric > 70 THEN (s->>'signal_drive_engine')::numeric
    ELSE ((s->>'signal_drive_engine')::numeric - 50) * ((s->>'signal_drive_engine')::numeric / 20.0)
  END;

  hwe_gated := GREATEST(0, (s->>'signal_hwe')::numeric - 55) * 100.0 / 45.0;

  fit := (s->>'maintains_high_activity')::numeric         * 0.16
       + (s->>'handles_rejection')::numeric               * 0.12
       + (s->>'handles_objections')::numeric              * 0.12
       + (s->>'dials_cold_calls')::numeric                * 0.10
       + drive_gated                                       * 0.08
       + (s->>'analytical')::numeric                      * 0.06
       + (s->>'presents_solutions')::numeric              * 0.07
       + (s->>'listens_discovers_needs')::numeric         * 0.07
       + (s->>'works_without_close_supervision')::numeric * 0.05
       + (s->>'cadence_compliance')::numeric              * 0.05
       + hwe_gated                                         * 0.06
       + (s->>'competes_for_recognition')::numeric        * 0.02
       + (s->>'rapid_rapport_warm')::numeric              * 0.04
       + (s->>'makes_decisions_quickly')::numeric         * 0.04
       + (s->>'signal_honesty')::numeric                  * 0.03
       + (s->>'has_entrepreneurial_spirit')::numeric      * 0.03
       + (s->>'receives_coaching')::numeric               * 0.03
       + (s->>'is_fast_start_oriented')::numeric          * 0.03
       + (s->>'queue_throughput_discipline')::numeric     * 0.02
       + (s->>'attention_to_detail')::numeric             * 0.01
       + (s->>'prospects_in_community')::numeric          * 0.02
       + (s->>'positively_influences_team')::numeric      * 0.02
       + (s->>'signal_overthinker_penalty')::numeric      * (-0.15)
       + (s->>'routing_judgment')::numeric                * (-0.04)
       + (s->>'retention_watchfulness')::numeric          * (-0.04);

  fit_base := fit;

  -- LSS 2d role-fit curve: below-floor exponential + above-ceiling quadratic
  -- Below-floor uses hiregauge_lss_penalty_v2 (same k=3.0 shape as 2c comp-side)
  -- Above-ceiling uses hiregauge_lss_ceiling_penalty_v2 (quadratic, coeff 0.4)
  -- Applied at role scale to composite intelligence; compounds with the
  -- per-competency 2c penalty already baked into each 'adjusted' value above.
  v_lss := public.hiregauge_lss_delta_v2(ta);
  v_composite := (v_lss->>'intelligence_composite')::numeric;
  SELECT intelligence_ideal_min, intelligence_ideal_max
    INTO v_floor, v_ceiling
    FROM public.hiregauge_role_ideal_ranges
    WHERE agency_id = ta.agency_id
      AND role_category = 'sales_outbound'
      AND role_level = 'default';
  v_floor_mult   := public.hiregauge_lss_penalty_v2(v_composite, v_floor);
  v_ceiling_mult := public.hiregauge_lss_ceiling_penalty_v2(v_composite, v_ceiling);
  v_lss_mult     := v_floor_mult * v_ceiling_mult;

  fit := fit_base * v_lss_mult;

  RETURN jsonb_build_object(
    'fit_score', ROUND(GREATEST(0, LEAST(100, fit)))::int,
    'role', 'sales_outbound',
    'adjusted', s,
    'meta', jsonb_build_object(
      'model', 'role_fit_v4_0_lss_2d_2026_08_01',
      'changes_from_v3_9', 'Added LSS 2d role-fit curve: below-floor exp helper hiregauge_lss_penalty_v2 + above-ceiling quadratic helper hiregauge_lss_ceiling_penalty_v2 applied to the weighted-competency fit. Floor 55 / ceiling 90 for sales_outbound per hiregauge_role_ideal_ranges. Compounds with per-competency 2c penalty already baked into each competency adjusted value. Base formula weights, drive_gated, hwe_gated, and clamp range [0,100] unchanged.',
      'drive_gated', drive_gated,
      'hwe_gated', hwe_gated,
      'fit_base_pre_lss', ROUND(fit_base, 2),
      'lss_composite', v_composite,
      'lss_floor', v_floor,
      'lss_ceiling', v_ceiling,
      'lss_floor_mult', ROUND(v_floor_mult, 4),
      'lss_ceiling_mult', ROUND(v_ceiling_mult, 4),
      'lss_total_mult', ROUND(v_lss_mult, 4)
    )
  );
END;
$function$;
