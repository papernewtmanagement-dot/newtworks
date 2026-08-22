-- HireGauge Phase 3C.1: additive rewire of 7 assessment_role_fit_* functions.
-- Each was reading competency scores + _meta from cts_<role>_competencies_adjusted (v1 chain).
-- Now sources competency scores from cts_competency_<n>_v2(candidate.*) .adjusted directly,
-- and reconstructs meta fields (has_lss, reliability, distortion) from the candidate row.
-- Weights, floor logic, gate calls, output shape all preserved byte-for-byte from prior fns.
-- Preps Phase 3C.2 destructive drop (43 fns) — after this ships, deprecated chain has zero callers.


CREATE OR REPLACE FUNCTION public.assessment_role_fit_sales_outbound(p_assessment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  ta hiring_candidates;
  g jsonb;
  v_hr numeric; v_mha numeric; v_dcc numeric; v_pic numeric;
  v_ho numeric; v_ps numeric; v_ldn numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
  v_has_lss boolean;
BEGIN
  SELECT * INTO ta FROM public.hiring_candidates WHERE id = p_assessment_id;
  IF NOT FOUND OR ta.deadline_motivation IS NULL THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'sales_outbound');
  END IF;

  v_hr  := (public.cts_competency_handles_rejection_v2(ta)          ->> 'adjusted')::numeric;
  v_mha := (public.cts_competency_maintains_high_activity_v2(ta)    ->> 'adjusted')::numeric;
  v_dcc := (public.cts_competency_dials_cold_calls_v2(ta)           ->> 'adjusted')::numeric;
  v_pic := (public.cts_competency_prospects_in_community_v2(ta)     ->> 'adjusted')::numeric;
  v_ho  := (public.cts_competency_handles_objections_v2(ta)         ->> 'adjusted')::numeric;
  v_ps  := (public.cts_competency_presents_solutions_v2(ta)         ->> 'adjusted')::numeric;
  v_ldn := (public.cts_competency_listens_discovers_needs_v2(ta)    ->> 'adjusted')::numeric;
  v_rc  := (public.cts_competency_receives_coaching_v2(ta)          ->> 'adjusted')::numeric;
  v_pit := (public.cts_competency_positively_influences_team_v2(ta) ->> 'adjusted')::numeric;

  v_has_lss := (ta.lss_math_accuracy IS NOT NULL AND ta.lss_verbal_accuracy IS NOT NULL AND ta.lss_problem_solving_accuracy IS NOT NULL
                AND ta.lss_math_speed_seconds IS NOT NULL AND ta.lss_verbal_speed_seconds IS NOT NULL AND ta.lss_problem_solving_speed_seconds IS NOT NULL);

  v_raw := v_hr*0.18 + v_mha*0.16 + v_dcc*0.14 + v_pic*0.12
         + v_ho*0.12 + v_ps*0.10 + v_ldn*0.08 + v_rc*0.05 + v_pit*0.05;

  IF v_hr <= v_mha THEN
    v_floor_src := 'handles_rejection'; v_floor_src_val := v_hr;
  ELSE
    v_floor_src := 'maintains_high_activity'; v_floor_src_val := v_mha;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates(p_assessment_id, 'sales_outbound', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

  RETURN jsonb_build_object(
    'fit_score', (g->>'fit_score')::int,
    'raw_score', (g->'raw_score'),
    'role', 'sales_outbound',
    'contributions', jsonb_build_object(
      'handles_rejection',         public._cts_role_fit_contrib(v_hr,  0.18, true),
      'maintains_high_activity',   public._cts_role_fit_contrib(v_mha, 0.16, true),
      'dials_cold_calls',          public._cts_role_fit_contrib(v_dcc, 0.14, false),
      'prospects_in_community',    public._cts_role_fit_contrib(v_pic, 0.12, false),
      'handles_objections',        public._cts_role_fit_contrib(v_ho,  0.12, false),
      'presents_solutions',        public._cts_role_fit_contrib(v_ps,  0.10, false),
      'listens_discovers_needs',   public._cts_role_fit_contrib(v_ldn, 0.08, false),
      'receives_coaching',         public._cts_role_fit_contrib(v_rc,  0.05, false),
      'positively_influences_team',public._cts_role_fit_contrib(v_pit, 0.05, false)
    ),
    'floors', jsonb_build_object(
      'cap_value', v_floor_cap,
      'cap_source_competency', v_floor_src,
      'cap_source_value', v_floor_src_val
    ),
    'adjustments', g->'adjustments',
    'gates', g->'gates',
    'trace', jsonb_build_object(
      'raw', g->'raw_score',
      'dampened', g->'dampened_score',
      'after_comp_cap', g->'after_comp_cap',
      'final', g->'fit_score'
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_competency_*_v2 (direct, phase_3c1)',
      'has_lss', v_has_lss,
      'reliability', ta.reliability,
      'distortion', ta.response_distortion,
      'model', 'competency_fit_v2_2_2026_07_21'
    )
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.assessment_role_fit_sales_inbound(p_assessment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  ta hiring_candidates;
  g jsonb;
  v_rrw numeric; v_cc numeric; v_ho numeric; v_ps numeric; v_ldn numeric;
  v_mha numeric; v_hr numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
  v_has_lss boolean;
BEGIN
  SELECT * INTO ta FROM public.hiring_candidates WHERE id = p_assessment_id;
  IF NOT FOUND OR ta.deadline_motivation IS NULL THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'sales_inbound');
  END IF;

  v_rrw := (public.cts_competency_rapid_rapport_warm_v2(ta)         ->> 'adjusted')::numeric;
  v_cc  := (public.cts_competency_cadence_compliance_v2(ta)         ->> 'adjusted')::numeric;
  v_ho  := (public.cts_competency_handles_objections_v2(ta)         ->> 'adjusted')::numeric;
  v_ps  := (public.cts_competency_presents_solutions_v2(ta)         ->> 'adjusted')::numeric;
  v_ldn := (public.cts_competency_listens_discovers_needs_v2(ta)    ->> 'adjusted')::numeric;
  v_mha := (public.cts_competency_maintains_high_activity_v2(ta)    ->> 'adjusted')::numeric;
  v_hr  := (public.cts_competency_handles_rejection_v2(ta)          ->> 'adjusted')::numeric;
  v_rc  := (public.cts_competency_receives_coaching_v2(ta)          ->> 'adjusted')::numeric;
  v_pit := (public.cts_competency_positively_influences_team_v2(ta) ->> 'adjusted')::numeric;

  v_has_lss := (ta.lss_math_accuracy IS NOT NULL AND ta.lss_verbal_accuracy IS NOT NULL AND ta.lss_problem_solving_accuracy IS NOT NULL
                AND ta.lss_math_speed_seconds IS NOT NULL AND ta.lss_verbal_speed_seconds IS NOT NULL AND ta.lss_problem_solving_speed_seconds IS NOT NULL);

  v_raw := v_rrw*0.20 + v_cc*0.16 + v_ho*0.14 + v_ps*0.14 + v_ldn*0.12
         + v_mha*0.08 + v_hr*0.06 + v_rc*0.05 + v_pit*0.05;

  IF v_rrw <= v_cc THEN
    v_floor_src := 'rapid_rapport_warm'; v_floor_src_val := v_rrw;
  ELSE
    v_floor_src := 'cadence_compliance'; v_floor_src_val := v_cc;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates(p_assessment_id, 'sales_inbound', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

  RETURN jsonb_build_object(
    'fit_score', (g->>'fit_score')::int,
    'raw_score', (g->'raw_score'),
    'role', 'sales_inbound',
    'contributions', jsonb_build_object(
      'rapid_rapport_warm',        public._cts_role_fit_contrib(v_rrw, 0.20, true),
      'cadence_compliance',        public._cts_role_fit_contrib(v_cc,  0.16, true),
      'handles_objections',        public._cts_role_fit_contrib(v_ho,  0.14, false),
      'presents_solutions',        public._cts_role_fit_contrib(v_ps,  0.14, false),
      'listens_discovers_needs',   public._cts_role_fit_contrib(v_ldn, 0.12, false),
      'maintains_high_activity',   public._cts_role_fit_contrib(v_mha, 0.08, false),
      'handles_rejection',         public._cts_role_fit_contrib(v_hr,  0.06, false),
      'receives_coaching',         public._cts_role_fit_contrib(v_rc,  0.05, false),
      'positively_influences_team',public._cts_role_fit_contrib(v_pit, 0.05, false)
    ),
    'floors', jsonb_build_object(
      'cap_value', v_floor_cap,
      'cap_source_competency', v_floor_src,
      'cap_source_value', v_floor_src_val
    ),
    'adjustments', g->'adjustments',
    'gates', g->'gates',
    'trace', jsonb_build_object(
      'raw', g->'raw_score',
      'dampened', g->'dampened_score',
      'after_comp_cap', g->'after_comp_cap',
      'final', g->'fit_score'
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_competency_*_v2 (direct, phase_3c1)',
      'has_lss', v_has_lss,
      'reliability', ta.reliability,
      'distortion', ta.response_distortion,
      'model', 'competency_fit_v2_2_2026_07_21'
    )
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.assessment_role_fit_sales_in_book(p_assessment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  ta hiring_candidates;
  g jsonb;
  v_csi numeric; v_ldn numeric; v_rw numeric; v_ho numeric; v_ps numeric;
  v_mha numeric; v_hr numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
  v_has_lss boolean;
BEGIN
  SELECT * INTO ta FROM public.hiring_candidates WHERE id = p_assessment_id;
  IF NOT FOUND OR ta.deadline_motivation IS NULL THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'sales_in_book');
  END IF;

  v_csi := (public.cts_competency_cross_sell_instinct_v2(ta)        ->> 'adjusted')::numeric;
  v_ldn := (public.cts_competency_listens_discovers_needs_v2(ta)    ->> 'adjusted')::numeric;
  v_rw  := (public.cts_competency_retention_watchfulness_v2(ta)     ->> 'adjusted')::numeric;
  v_ho  := (public.cts_competency_handles_objections_v2(ta)         ->> 'adjusted')::numeric;
  v_ps  := (public.cts_competency_presents_solutions_v2(ta)         ->> 'adjusted')::numeric;
  v_mha := (public.cts_competency_maintains_high_activity_v2(ta)    ->> 'adjusted')::numeric;
  v_hr  := (public.cts_competency_handles_rejection_v2(ta)          ->> 'adjusted')::numeric;
  v_rc  := (public.cts_competency_receives_coaching_v2(ta)          ->> 'adjusted')::numeric;
  v_pit := (public.cts_competency_positively_influences_team_v2(ta) ->> 'adjusted')::numeric;

  v_has_lss := (ta.lss_math_accuracy IS NOT NULL AND ta.lss_verbal_accuracy IS NOT NULL AND ta.lss_problem_solving_accuracy IS NOT NULL
                AND ta.lss_math_speed_seconds IS NOT NULL AND ta.lss_verbal_speed_seconds IS NOT NULL AND ta.lss_problem_solving_speed_seconds IS NOT NULL);

  v_raw := v_csi*0.20 + v_ldn*0.16 + v_rw*0.14 + v_ho*0.12 + v_ps*0.12
         + v_mha*0.08 + v_hr*0.06 + v_rc*0.06 + v_pit*0.06;

  IF v_csi <= v_ldn THEN
    v_floor_src := 'cross_sell_instinct'; v_floor_src_val := v_csi;
  ELSE
    v_floor_src := 'listens_discovers_needs'; v_floor_src_val := v_ldn;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates(p_assessment_id, 'sales_in_book', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

  RETURN jsonb_build_object(
    'fit_score', (g->>'fit_score')::int,
    'raw_score', (g->'raw_score'),
    'role', 'sales_in_book',
    'contributions', jsonb_build_object(
      'cross_sell_instinct',       public._cts_role_fit_contrib(v_csi, 0.20, true),
      'listens_discovers_needs',   public._cts_role_fit_contrib(v_ldn, 0.16, true),
      'retention_watchfulness',    public._cts_role_fit_contrib(v_rw,  0.14, false),
      'handles_objections',        public._cts_role_fit_contrib(v_ho,  0.12, false),
      'presents_solutions',        public._cts_role_fit_contrib(v_ps,  0.12, false),
      'maintains_high_activity',   public._cts_role_fit_contrib(v_mha, 0.08, false),
      'handles_rejection',         public._cts_role_fit_contrib(v_hr,  0.06, false),
      'receives_coaching',         public._cts_role_fit_contrib(v_rc,  0.06, false),
      'positively_influences_team',public._cts_role_fit_contrib(v_pit, 0.06, false)
    ),
    'floors', jsonb_build_object(
      'cap_value', v_floor_cap,
      'cap_source_competency', v_floor_src,
      'cap_source_value', v_floor_src_val
    ),
    'adjustments', g->'adjustments',
    'gates', g->'gates',
    'trace', jsonb_build_object(
      'raw', g->'raw_score',
      'dampened', g->'dampened_score',
      'after_comp_cap', g->'after_comp_cap',
      'final', g->'fit_score'
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_competency_*_v2 (direct, phase_3c1)',
      'has_lss', v_has_lss,
      'reliability', ta.reliability,
      'distortion', ta.response_distortion,
      'model', 'competency_fit_v2_2_2026_07_21'
    )
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.assessment_role_fit_retention_reception(p_assessment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  ta hiring_candidates;
  g jsonb;
  v_rrw numeric; v_ldn numeric; v_cul numeric; v_rj numeric; v_pcn numeric;
  v_mdq numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
  v_has_lss boolean;
BEGIN
  SELECT * INTO ta FROM public.hiring_candidates WHERE id = p_assessment_id;
  IF NOT FOUND OR ta.deadline_motivation IS NULL THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'retention_reception');
  END IF;

  v_rrw := (public.cts_competency_rapid_rapport_warm_v2(ta)         ->> 'adjusted')::numeric;
  v_ldn := (public.cts_competency_listens_discovers_needs_v2(ta)    ->> 'adjusted')::numeric;
  v_cul := (public.cts_competency_composure_under_load_v2(ta)       ->> 'adjusted')::numeric;
  v_rj  := (public.cts_competency_routing_judgment_v2(ta)           ->> 'adjusted')::numeric;
  v_pcn := (public.cts_competency_pivots_to_customer_need_v2(ta)    ->> 'adjusted')::numeric;
  v_mdq := (public.cts_competency_makes_decisions_quickly_v2(ta)    ->> 'adjusted')::numeric;
  v_rc  := (public.cts_competency_receives_coaching_v2(ta)          ->> 'adjusted')::numeric;
  v_pit := (public.cts_competency_positively_influences_team_v2(ta) ->> 'adjusted')::numeric;

  v_has_lss := (ta.lss_math_accuracy IS NOT NULL AND ta.lss_verbal_accuracy IS NOT NULL AND ta.lss_problem_solving_accuracy IS NOT NULL
                AND ta.lss_math_speed_seconds IS NOT NULL AND ta.lss_verbal_speed_seconds IS NOT NULL AND ta.lss_problem_solving_speed_seconds IS NOT NULL);

  v_raw := v_rrw*0.18 + v_ldn*0.16 + v_cul*0.14 + v_rj*0.14 + v_pcn*0.12
         + v_mdq*0.10 + v_rc*0.08 + v_pit*0.08;

  IF v_rrw <= v_cul THEN
    v_floor_src := 'rapid_rapport_warm'; v_floor_src_val := v_rrw;
  ELSE
    v_floor_src := 'composure_under_load'; v_floor_src_val := v_cul;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates(p_assessment_id, 'retention_reception', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

  RETURN jsonb_build_object(
    'fit_score', (g->>'fit_score')::int,
    'raw_score', (g->'raw_score'),
    'role', 'retention_reception',
    'contributions', jsonb_build_object(
      'rapid_rapport_warm',        public._cts_role_fit_contrib(v_rrw, 0.18, true),
      'listens_discovers_needs',   public._cts_role_fit_contrib(v_ldn, 0.16, false),
      'composure_under_load',      public._cts_role_fit_contrib(v_cul, 0.14, true),
      'routing_judgment',          public._cts_role_fit_contrib(v_rj,  0.14, false),
      'pivots_to_customer_need',   public._cts_role_fit_contrib(v_pcn, 0.12, false),
      'makes_decisions_quickly',   public._cts_role_fit_contrib(v_mdq, 0.10, false),
      'receives_coaching',         public._cts_role_fit_contrib(v_rc,  0.08, false),
      'positively_influences_team',public._cts_role_fit_contrib(v_pit, 0.08, false)
    ),
    'floors', jsonb_build_object(
      'cap_value', v_floor_cap,
      'cap_source_competency', v_floor_src,
      'cap_source_value', v_floor_src_val
    ),
    'adjustments', g->'adjustments',
    'gates', g->'gates',
    'trace', jsonb_build_object(
      'raw', g->'raw_score',
      'dampened', g->'dampened_score',
      'after_comp_cap', g->'after_comp_cap',
      'final', g->'fit_score'
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_competency_*_v2 (direct, phase_3c1)',
      'has_lss', v_has_lss,
      'reliability', ta.reliability,
      'distortion', ta.response_distortion,
      'model', 'competency_fit_v2_2_2026_07_21'
    )
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.assessment_role_fit_retention_escalation(p_assessment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  ta hiring_candidates;
  g jsonb;
  v_ho numeric; v_ldn numeric; v_rw numeric; v_ptd numeric; v_cul numeric;
  v_ps numeric; v_hr numeric; v_mha numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
  v_has_lss boolean;
BEGIN
  SELECT * INTO ta FROM public.hiring_candidates WHERE id = p_assessment_id;
  IF NOT FOUND OR ta.deadline_motivation IS NULL THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'retention_escalation');
  END IF;

  v_ho  := (public.cts_competency_handles_objections_v2(ta)         ->> 'adjusted')::numeric;
  v_ldn := (public.cts_competency_listens_discovers_needs_v2(ta)    ->> 'adjusted')::numeric;
  v_rw  := (public.cts_competency_retention_watchfulness_v2(ta)     ->> 'adjusted')::numeric;
  v_ptd := (public.cts_competency_proactive_touch_discipline_v2(ta) ->> 'adjusted')::numeric;
  v_cul := (public.cts_competency_composure_under_load_v2(ta)       ->> 'adjusted')::numeric;
  v_ps  := (public.cts_competency_presents_solutions_v2(ta)         ->> 'adjusted')::numeric;
  v_hr  := (public.cts_competency_handles_rejection_v2(ta)          ->> 'adjusted')::numeric;
  v_mha := (public.cts_competency_maintains_high_activity_v2(ta)    ->> 'adjusted')::numeric;
  v_rc  := (public.cts_competency_receives_coaching_v2(ta)          ->> 'adjusted')::numeric;
  v_pit := (public.cts_competency_positively_influences_team_v2(ta) ->> 'adjusted')::numeric;

  v_has_lss := (ta.lss_math_accuracy IS NOT NULL AND ta.lss_verbal_accuracy IS NOT NULL AND ta.lss_problem_solving_accuracy IS NOT NULL
                AND ta.lss_math_speed_seconds IS NOT NULL AND ta.lss_verbal_speed_seconds IS NOT NULL AND ta.lss_problem_solving_speed_seconds IS NOT NULL);

  v_raw := v_ho*0.16 + v_ldn*0.12 + v_rw*0.14 + v_ptd*0.14 + v_cul*0.14
         + v_ps*0.10 + v_hr*0.06 + v_mha*0.04 + v_rc*0.05 + v_pit*0.05;

  IF v_ho <= v_cul THEN
    v_floor_src := 'handles_objections'; v_floor_src_val := v_ho;
  ELSE
    v_floor_src := 'composure_under_load'; v_floor_src_val := v_cul;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates(p_assessment_id, 'retention_escalation', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

  RETURN jsonb_build_object(
    'fit_score', (g->>'fit_score')::int,
    'raw_score', (g->'raw_score'),
    'role', 'retention_escalation',
    'contributions', jsonb_build_object(
      'handles_objections',        public._cts_role_fit_contrib(v_ho,  0.16, true),
      'listens_discovers_needs',   public._cts_role_fit_contrib(v_ldn, 0.12, false),
      'retention_watchfulness',    public._cts_role_fit_contrib(v_rw,  0.14, false),
      'proactive_touch_discipline',public._cts_role_fit_contrib(v_ptd, 0.14, false),
      'composure_under_load',      public._cts_role_fit_contrib(v_cul, 0.14, true),
      'presents_solutions',        public._cts_role_fit_contrib(v_ps,  0.10, false),
      'handles_rejection',         public._cts_role_fit_contrib(v_hr,  0.06, false),
      'maintains_high_activity',   public._cts_role_fit_contrib(v_mha, 0.04, false),
      'receives_coaching',         public._cts_role_fit_contrib(v_rc,  0.05, false),
      'positively_influences_team',public._cts_role_fit_contrib(v_pit, 0.05, false)
    ),
    'floors', jsonb_build_object(
      'cap_value', v_floor_cap,
      'cap_source_competency', v_floor_src,
      'cap_source_value', v_floor_src_val
    ),
    'adjustments', g->'adjustments',
    'gates', g->'gates',
    'trace', jsonb_build_object(
      'raw', g->'raw_score',
      'dampened', g->'dampened_score',
      'after_comp_cap', g->'after_comp_cap',
      'final', g->'fit_score'
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_competency_*_v2 (direct, phase_3c1)',
      'has_lss', v_has_lss,
      'reliability', ta.reliability,
      'distortion', ta.response_distortion,
      'model', 'competency_fit_v2_2_2026_07_21'
    )
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.assessment_role_fit_retention_support(p_assessment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  ta hiring_candidates;
  g jsonb;
  v_ad numeric; v_qtd numeric; v_wwcs numeric; v_mte numeric;
  v_an numeric; v_mdq numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
  v_has_lss boolean;
BEGIN
  SELECT * INTO ta FROM public.hiring_candidates WHERE id = p_assessment_id;
  IF NOT FOUND OR ta.deadline_motivation IS NULL THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'retention_support');
  END IF;

  v_ad   := (public.cts_competency_attention_to_detail_v2(ta)             ->> 'adjusted')::numeric;
  v_qtd  := (public.cts_competency_queue_throughput_discipline_v2(ta)     ->> 'adjusted')::numeric;
  v_wwcs := (public.cts_competency_works_without_close_supervision_v2(ta) ->> 'adjusted')::numeric;
  v_mte  := (public.cts_competency_manages_time_effectively_v2(ta)        ->> 'adjusted')::numeric;
  v_an   := (public.cts_competency_analytical_v2(ta)                      ->> 'adjusted')::numeric;
  v_mdq  := (public.cts_competency_makes_decisions_quickly_v2(ta)         ->> 'adjusted')::numeric;
  v_rc   := (public.cts_competency_receives_coaching_v2(ta)               ->> 'adjusted')::numeric;
  v_pit  := (public.cts_competency_positively_influences_team_v2(ta)      ->> 'adjusted')::numeric;

  v_has_lss := (ta.lss_math_accuracy IS NOT NULL AND ta.lss_verbal_accuracy IS NOT NULL AND ta.lss_problem_solving_accuracy IS NOT NULL
                AND ta.lss_math_speed_seconds IS NOT NULL AND ta.lss_verbal_speed_seconds IS NOT NULL AND ta.lss_problem_solving_speed_seconds IS NOT NULL);

  v_raw := v_ad*0.20 + v_qtd*0.20 + v_wwcs*0.14 + v_mte*0.14
         + v_an*0.06 + v_mdq*0.10 + v_rc*0.08 + v_pit*0.08;

  IF v_ad <= v_qtd THEN
    v_floor_src := 'attention_to_detail'; v_floor_src_val := v_ad;
  ELSE
    v_floor_src := 'queue_throughput_discipline'; v_floor_src_val := v_qtd;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates(p_assessment_id, 'retention_support', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

  RETURN jsonb_build_object(
    'fit_score', (g->>'fit_score')::int,
    'raw_score', (g->'raw_score'),
    'role', 'retention_support',
    'contributions', jsonb_build_object(
      'attention_to_detail',           public._cts_role_fit_contrib(v_ad,   0.20, true),
      'queue_throughput_discipline',   public._cts_role_fit_contrib(v_qtd,  0.20, true),
      'works_without_close_supervision',public._cts_role_fit_contrib(v_wwcs, 0.14, false),
      'manages_time_effectively',      public._cts_role_fit_contrib(v_mte,  0.14, false),
      'analytical',                    public._cts_role_fit_contrib(v_an,   0.06, false),
      'makes_decisions_quickly',       public._cts_role_fit_contrib(v_mdq,  0.10, false),
      'receives_coaching',             public._cts_role_fit_contrib(v_rc,   0.08, false),
      'positively_influences_team',    public._cts_role_fit_contrib(v_pit,  0.08, false)
    ),
    'floors', jsonb_build_object(
      'cap_value', v_floor_cap,
      'cap_source_competency', v_floor_src,
      'cap_source_value', v_floor_src_val
    ),
    'adjustments', g->'adjustments',
    'gates', g->'gates',
    'trace', jsonb_build_object(
      'raw', g->'raw_score',
      'dampened', g->'dampened_score',
      'after_comp_cap', g->'after_comp_cap',
      'final', g->'fit_score'
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_competency_*_v2 (direct, phase_3c1)',
      'has_lss', v_has_lss,
      'reliability', ta.reliability,
      'distortion', ta.response_distortion,
      'model', 'competency_fit_v2_2_2026_07_21'
    )
  );
END;
$function$;


CREATE OR REPLACE FUNCTION public.assessment_role_fit_aspirant(p_assessment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  ta hiring_candidates;
  g jsonb;
  v_hr numeric; v_ho numeric; v_mha numeric; v_ps numeric;
  v_hes numeric; v_ldn numeric; v_pic numeric; v_dcc numeric;
  v_cfr numeric; v_fso numeric; v_bleh numeric; v_pit numeric; v_rc numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
  v_has_lss boolean;
BEGIN
  SELECT * INTO ta FROM public.hiring_candidates WHERE id = p_assessment_id;
  IF NOT FOUND OR ta.deadline_motivation IS NULL THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'aspirant');
  END IF;

  v_hr   := (public.cts_competency_handles_rejection_v2(ta)                      ->> 'adjusted')::numeric;
  v_ho   := (public.cts_competency_handles_objections_v2(ta)                     ->> 'adjusted')::numeric;
  v_mha  := (public.cts_competency_maintains_high_activity_v2(ta)                ->> 'adjusted')::numeric;
  v_ps   := (public.cts_competency_presents_solutions_v2(ta)                     ->> 'adjusted')::numeric;
  v_hes  := (public.cts_competency_has_entrepreneurial_spirit_v2(ta)             ->> 'adjusted')::numeric;
  v_ldn  := (public.cts_competency_listens_discovers_needs_v2(ta)                ->> 'adjusted')::numeric;
  v_pic  := (public.cts_competency_prospects_in_community_v2(ta)                 ->> 'adjusted')::numeric;
  v_dcc  := (public.cts_competency_dials_cold_calls_v2(ta)                       ->> 'adjusted')::numeric;
  v_cfr  := (public.cts_competency_competes_for_recognition_v2(ta)               ->> 'adjusted')::numeric;
  v_fso  := (public.cts_competency_is_fast_start_oriented_v2(ta)                 ->> 'adjusted')::numeric;
  v_bleh := (public.cts_competency_balances_logic_and_emotion_when_hiring_v2(ta) ->> 'adjusted')::numeric;
  v_pit  := (public.cts_competency_positively_influences_team_v2(ta)             ->> 'adjusted')::numeric;
  v_rc   := (public.cts_competency_receives_coaching_v2(ta)                      ->> 'adjusted')::numeric;

  v_has_lss := (ta.lss_math_accuracy IS NOT NULL AND ta.lss_verbal_accuracy IS NOT NULL AND ta.lss_problem_solving_accuracy IS NOT NULL
                AND ta.lss_math_speed_seconds IS NOT NULL AND ta.lss_verbal_speed_seconds IS NOT NULL AND ta.lss_problem_solving_speed_seconds IS NOT NULL);

  v_raw := v_hr*0.12 + v_ho*0.10 + v_mha*0.10 + v_ps*0.10
         + v_hes*0.10 + v_ldn*0.08 + v_pic*0.08 + v_dcc*0.06
         + v_cfr*0.06 + v_fso*0.06 + v_bleh*0.06 + v_pit*0.05 + v_rc*0.03;

  IF v_hes <= v_hr THEN
    v_floor_src := 'has_entrepreneurial_spirit'; v_floor_src_val := v_hes;
  ELSE
    v_floor_src := 'handles_rejection'; v_floor_src_val := v_hr;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates(p_assessment_id, 'aspirant', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

  RETURN jsonb_build_object(
    'fit_score', (g->>'fit_score')::int,
    'raw_score', (g->'raw_score'),
    'role', 'aspirant',
    'contributions', jsonb_build_object(
      'handles_rejection',                     public._cts_role_fit_contrib(v_hr,   0.12, true),
      'handles_objections',                    public._cts_role_fit_contrib(v_ho,   0.10, false),
      'maintains_high_activity',               public._cts_role_fit_contrib(v_mha,  0.10, false),
      'presents_solutions',                    public._cts_role_fit_contrib(v_ps,   0.10, false),
      'has_entrepreneurial_spirit',            public._cts_role_fit_contrib(v_hes,  0.10, true),
      'listens_discovers_needs',               public._cts_role_fit_contrib(v_ldn,  0.08, false),
      'prospects_in_community',                public._cts_role_fit_contrib(v_pic,  0.08, false),
      'dials_cold_calls',                      public._cts_role_fit_contrib(v_dcc,  0.06, false),
      'competes_for_recognition',              public._cts_role_fit_contrib(v_cfr,  0.06, false),
      'is_fast_start_oriented',                public._cts_role_fit_contrib(v_fso,  0.06, false),
      'balances_logic_and_emotion_when_hiring',public._cts_role_fit_contrib(v_bleh, 0.06, false),
      'positively_influences_team',            public._cts_role_fit_contrib(v_pit,  0.05, false),
      'receives_coaching',                     public._cts_role_fit_contrib(v_rc,   0.03, false)
    ),
    'floors', jsonb_build_object(
      'cap_value', v_floor_cap,
      'cap_source_competency', v_floor_src,
      'cap_source_value', v_floor_src_val
    ),
    'adjustments', g->'adjustments',
    'gates', g->'gates',
    'trace', jsonb_build_object(
      'raw', g->'raw_score',
      'dampened', g->'dampened_score',
      'after_comp_cap', g->'after_comp_cap',
      'final', g->'fit_score'
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_competency_*_v2 (direct, phase_3c1)',
      'has_lss', v_has_lss,
      'reliability', ta.reliability,
      'distortion', ta.response_distortion,
      'model', 'competency_fit_v2_2_2026_07_21'
    )
  );
END;
$function$;
