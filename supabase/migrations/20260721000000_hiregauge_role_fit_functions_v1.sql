-- Migration: cts_role_fit_<role> functions (7 total) + composure_under_load added to retention_escalation
-- 2026-07-21. Blind first-principles competency-based role-fit scoring.
-- Replaces cts_<role>_os as canonical role fit once validated against 25-candidate walkthroughs.

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1: Extend cts_retention_escalation_competencies (base) to include
--         composure_under_load. Same formula as retention_reception base.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.cts_retention_escalation_competencies(
  deadline_motivation integer, recognition_drive integer, assertiveness integer,
  independent_spirit integer, analytical integer, compassion integer,
  self_promotion integer, belief_in_others integer, optimism integer
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $function$
  SELECT jsonb_build_object(
    'maintains_high_activity', GREATEST(0, LEAST(100, ROUND((28.073729) + (0.285176)*deadline_motivation + (0.144217)*recognition_drive + (0.139653)*assertiveness + (0.142891)*independent_spirit + (-0.137245)*analytical + (-0.140148)*compassion + (-0.004295)*self_promotion + (-0.003630)*belief_in_others + (0.003141)*optimism)::int)),
    'listens_discovers_needs', GREATEST(0, LEAST(100, ROUND((14.551344) + (0.001424)*deadline_motivation + (0.284967)*recognition_drive + (0.290981)*assertiveness + (-0.005509)*independent_spirit + (-0.147511)*analytical + (0.138916)*compassion + (0.001697)*self_promotion + (0.140386)*belief_in_others + (-0.003336)*optimism)::int)),
    'presents_solutions', GREATEST(0, LEAST(100, ROUND((0.695513) + (-0.003482)*deadline_motivation + (0.402272)*recognition_drive + (0.406482)*assertiveness + (-0.007618)*independent_spirit + (0.000102)*analytical + (-0.003992)*compassion + (0.199087)*self_promotion + (-0.001307)*belief_in_others + (-0.009427)*optimism)::int)),
    'handles_objections', GREATEST(0, LEAST(100, ROUND((-1.877354) + (0.003006)*deadline_motivation + (0.332427)*recognition_drive + (0.323724)*assertiveness + (0.009307)*independent_spirit + (0.003828)*analytical + (0.004900)*compassion + (0.166451)*self_promotion + (0.004481)*belief_in_others + (0.174564)*optimism)::int)),
    'receives_coaching', GREATEST(0, LEAST(100, ROUND((33.550072) + (-0.005371)*deadline_motivation + (0.109720)*recognition_drive + (0.113558)*assertiveness + (-0.109892)*independent_spirit + (-0.112440)*analytical + (0.217015)*compassion + (-0.113273)*self_promotion + (0.113147)*belief_in_others + (0.110904)*optimism)::int)),
    'positively_influences_team', optimism,
    'retention_watchfulness', GREATEST(0, LEAST(100, ROUND((20.000000) + (0.250000)*compassion + (0.200000)*analytical + (0.100000)*belief_in_others + (0.050000)*assertiveness + (0.050000)*deadline_motivation + (-0.050000)*optimism)::int)),
    'proactive_touch_discipline', GREATEST(0, LEAST(100, ROUND((20.000000) + (0.250000)*deadline_motivation + (0.150000)*analytical + (0.150000)*compassion + (0.100000)*recognition_drive + (0.050000)*optimism)::int)),
    'composure_under_load', GREATEST(0, LEAST(100, ROUND((18.000000) + (0.250000)*optimism + (0.200000)*compassion + (0.100000)*assertiveness + (0.050000)*independent_spirit + (0.050000)*deadline_motivation + (0.050000)*belief_in_others + (-0.050000)*analytical)::int))
  );
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2: Extend cts_retention_escalation_competencies_adjusted to emit
--         composure_under_load (LSS-adjusted + dampened) and its lss_delta.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.cts_retention_escalation_competencies_adjusted(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  WITH adj AS (
    SELECT deadline_motivation AS dm, recognition_drive AS rd, assertiveness AS ass,
      independent_spirit AS is_val, analytical AS an,
      public._cts_dampen_trait_by_distortion(compassion, 'compassion', response_distortion) AS com,
      self_promotion AS sp,
      public._cts_dampen_trait_by_distortion(belief_in_others, 'belief_in_others', response_distortion) AS bo,
      public._cts_dampen_trait_by_distortion(optimism, 'optimism', response_distortion) AS op,
      (lss_math_accuracy IS NOT NULL AND lss_verbal_accuracy IS NOT NULL AND lss_problem_solving_accuracy IS NOT NULL
       AND lss_math_speed_seconds IS NOT NULL AND lss_verbal_speed_seconds IS NOT NULL AND lss_problem_solving_speed_seconds IS NOT NULL) AS has_lss,
      ((CASE WHEN lss_math_accuracy>=10 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_accuracy>=8 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_accuracy>=7 THEN 1 ELSE 0 END)-1.5)/1.5 AS acc_signal,
      ((CASE WHEN lss_math_speed_seconds<=50 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_speed_seconds<=52 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_speed_seconds<=77 THEN 1 ELSE 0 END)-1.5)/1.5 AS spd_signal,
      ((CASE WHEN lss_math_accuracy>=10 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_accuracy>=8 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_accuracy>=7 THEN 1 ELSE 0 END))::int AS acc_flags_int,
      ((CASE WHEN lss_math_speed_seconds<=50 THEN 1 ELSE 0 END)+(CASE WHEN lss_verbal_speed_seconds<=52 THEN 1 ELSE 0 END)+(CASE WHEN lss_problem_solving_speed_seconds<=77 THEN 1 ELSE 0 END))::int AS spd_flags_int,
      public._cts_reliability_confidence(reliability) AS rel_factor,
      public._cts_distortion_severity(response_distortion) AS dist_sev,
      reliability AS rel, response_distortion AS dist,
      (SELECT jsonb_object_agg(competency, jsonb_build_object('a', lss_acc_weight, 's', lss_spd_weight))
       FROM public.hiregauge_competencies) AS w
    FROM public.hiring_candidates
    WHERE id = p_assessment_id AND deadline_motivation IS NOT NULL
  )
  SELECT jsonb_build_object(
    'maintains_high_activity', public._cts_lss_apply_v4((28.073729) + (0.285176)*dm + (0.144217)*rd + (0.139653)*ass + (0.142891)*is_val + (-0.137245)*an + (-0.140148)*com + (-0.004295)*sp + (-0.003630)*bo + (0.003141)*op, (w->'maintains_high_activity'->>'a')::numeric, (w->'maintains_high_activity'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    'listens_discovers_needs', public._cts_lss_apply_v4((14.551344) + (0.001424)*dm + (0.284967)*rd + (0.290981)*ass + (-0.005509)*is_val + (-0.147511)*an + (0.138916)*com + (0.001697)*sp + (0.140386)*bo + (-0.003336)*op, (w->'listens_discovers_needs'->>'a')::numeric, (w->'listens_discovers_needs'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    'presents_solutions', public._cts_lss_apply_v4((0.695513) + (-0.003482)*dm + (0.402272)*rd + (0.406482)*ass + (-0.007618)*is_val + (0.000102)*an + (-0.003992)*com + (0.199087)*sp + (-0.001307)*bo + (-0.009427)*op, (w->'presents_solutions'->>'a')::numeric, (w->'presents_solutions'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    'handles_objections', public._cts_lss_apply_v4((-1.877354) + (0.003006)*dm + (0.332427)*rd + (0.323724)*ass + (0.009307)*is_val + (0.003828)*an + (0.004900)*com + (0.166451)*sp + (0.004481)*bo + (0.174564)*op, (w->'handles_objections'->>'a')::numeric, (w->'handles_objections'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    'receives_coaching', public._cts_lss_apply_v4((33.550072) + (-0.005371)*dm + (0.109720)*rd + (0.113558)*ass + (-0.109892)*is_val + (-0.112440)*an + (0.217015)*com + (-0.113273)*sp + (0.113147)*bo + (0.110904)*op, (w->'receives_coaching'->>'a')::numeric, (w->'receives_coaching'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    'positively_influences_team', public._cts_lss_apply_v4(op::numeric, (w->'positively_influences_team'->>'a')::numeric, (w->'positively_influences_team'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    'retention_watchfulness', public._cts_lss_apply_v4((20.000000) + (0.250000)*com + (0.200000)*an + (0.100000)*bo + (0.050000)*ass + (0.050000)*dm + (-0.050000)*op, (w->'retention_watchfulness'->>'a')::numeric, (w->'retention_watchfulness'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    'proactive_touch_discipline', public._cts_lss_apply_v4((20.000000) + (0.250000)*dm + (0.150000)*an + (0.150000)*com + (0.100000)*rd + (0.050000)*op, (w->'proactive_touch_discipline'->>'a')::numeric, (w->'proactive_touch_discipline'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    'composure_under_load', public._cts_lss_apply_v4((18.000000) + (0.250000)*op + (0.200000)*com + (0.100000)*ass + (0.050000)*is_val + (0.050000)*dm + (0.050000)*bo + (-0.050000)*an, (w->'composure_under_load'->>'a')::numeric, (w->'composure_under_load'->>'s')::numeric, acc_signal, spd_signal, rel_factor, has_lss),
    '_lss_deltas', jsonb_build_object(
      'maintains_high_activity',    public._cts_lss_delta_v4((w->'maintains_high_activity'->>'a')::numeric,    (w->'maintains_high_activity'->>'s')::numeric,    acc_signal, spd_signal, has_lss),
      'listens_discovers_needs',    public._cts_lss_delta_v4((w->'listens_discovers_needs'->>'a')::numeric,    (w->'listens_discovers_needs'->>'s')::numeric,    acc_signal, spd_signal, has_lss),
      'presents_solutions',         public._cts_lss_delta_v4((w->'presents_solutions'->>'a')::numeric,         (w->'presents_solutions'->>'s')::numeric,         acc_signal, spd_signal, has_lss),
      'handles_objections',         public._cts_lss_delta_v4((w->'handles_objections'->>'a')::numeric,         (w->'handles_objections'->>'s')::numeric,         acc_signal, spd_signal, has_lss),
      'receives_coaching',          public._cts_lss_delta_v4((w->'receives_coaching'->>'a')::numeric,          (w->'receives_coaching'->>'s')::numeric,          acc_signal, spd_signal, has_lss),
      'positively_influences_team', public._cts_lss_delta_v4((w->'positively_influences_team'->>'a')::numeric, (w->'positively_influences_team'->>'s')::numeric, acc_signal, spd_signal, has_lss),
      'retention_watchfulness',     public._cts_lss_delta_v4((w->'retention_watchfulness'->>'a')::numeric,     (w->'retention_watchfulness'->>'s')::numeric,     acc_signal, spd_signal, has_lss),
      'proactive_touch_discipline', public._cts_lss_delta_v4((w->'proactive_touch_discipline'->>'a')::numeric, (w->'proactive_touch_discipline'->>'s')::numeric, acc_signal, spd_signal, has_lss),
      'composure_under_load',       public._cts_lss_delta_v4((w->'composure_under_load'->>'a')::numeric,       (w->'composure_under_load'->>'s')::numeric,       acc_signal, spd_signal, has_lss)
    ),
    '_meta', jsonb_build_object(
      'has_lss', has_lss, 'acc_flags', acc_flags_int, 'spd_flags', spd_flags_int,
      'reliability', rel, 'distortion', dist,
      'reliability_factor', rel_factor, 'distortion_severity', dist_sev,
      'role', 'retention_escalation', 'model', 'sensitivity_weighted_v4_asymmetric'
    )
  )
  FROM adj;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 3: Helper — build contribution row for one competency
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public._cts_role_fit_contrib(
  p_value numeric, p_weight numeric, p_is_floor boolean DEFAULT false
) RETURNS jsonb
LANGUAGE sql IMMUTABLE
AS $function$
  SELECT jsonb_build_object(
    'value', p_value,
    'weight', p_weight,
    'weighted', ROUND(p_value * p_weight, 2),
    'is_floor', p_is_floor
  );
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 4: cts_role_fit_sales_outbound
--   Weights: HR .18, MHA .16, DCC .14, PIC .12, HO .12, PS .10, LDN .08, RC .05, PIT .05
--   Floors: handles_rejection, maintains_high_activity → cap MIN+15
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.cts_role_fit_sales_outbound(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  c jsonb;
  m jsonb;
  v_hr  numeric; v_mha numeric; v_dcc numeric; v_pic numeric;
  v_ho  numeric; v_ps  numeric; v_ldn numeric; v_rc  numeric; v_pit numeric;
  v_raw numeric;
  v_cap numeric; v_cap_src text; v_cap_src_val numeric;
  v_final int;
BEGIN
  c := public.cts_sales_outbound_competencies_adjusted(p_assessment_id);
  IF c IS NULL OR NOT (c ? 'handles_rejection') THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'sales_outbound');
  END IF;
  m := c->'_meta';

  v_hr  := (c->>'handles_rejection')::numeric;
  v_mha := (c->>'maintains_high_activity')::numeric;
  v_dcc := (c->>'dials_cold_calls')::numeric;
  v_pic := (c->>'prospects_in_community')::numeric;
  v_ho  := (c->>'handles_objections')::numeric;
  v_ps  := (c->>'presents_solutions')::numeric;
  v_ldn := (c->>'listens_discovers_needs')::numeric;
  v_rc  := (c->>'receives_coaching')::numeric;
  v_pit := (c->>'positively_influences_team')::numeric;

  v_raw := v_hr*0.18 + v_mha*0.16 + v_dcc*0.14 + v_pic*0.12
         + v_ho*0.12 + v_ps*0.10 + v_ldn*0.08 + v_rc*0.05 + v_pit*0.05;

  IF v_hr <= v_mha THEN
    v_cap_src := 'handles_rejection'; v_cap_src_val := v_hr;
  ELSE
    v_cap_src := 'maintains_high_activity'; v_cap_src_val := v_mha;
  END IF;
  v_cap := v_cap_src_val + 15;
  v_final := GREATEST(0, LEAST(100, ROUND(LEAST(v_raw, v_cap))));

  RETURN jsonb_build_object(
    'fit_score', v_final,
    'raw_score', ROUND(v_raw, 2),
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
      'triggered', (ROUND(v_raw,2) > ROUND(v_cap,2)),
      'cap_value', ROUND(v_cap, 2),
      'cap_source_competency', v_cap_src,
      'cap_source_value', v_cap_src_val
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_sales_outbound_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v1_2026_07_21'
    )
  );
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 5: cts_role_fit_sales_inbound
--   Weights: RRW .20, CC .16, HO .14, PS .14, LDN .12, MHA .08, HR .06, RC .05, PIT .05
--   Floors: rapid_rapport_warm, cadence_compliance → cap MIN+15
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.cts_role_fit_sales_inbound(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  c jsonb; m jsonb;
  v_rrw numeric; v_cc numeric; v_ho numeric; v_ps numeric; v_ldn numeric;
  v_mha numeric; v_hr numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_cap numeric; v_cap_src text; v_cap_src_val numeric;
  v_final int;
BEGIN
  c := public.cts_sales_inbound_competencies_adjusted(p_assessment_id);
  IF c IS NULL OR NOT (c ? 'rapid_rapport_warm') THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'sales_inbound');
  END IF;
  m := c->'_meta';

  v_rrw := (c->>'rapid_rapport_warm')::numeric;
  v_cc  := (c->>'cadence_compliance')::numeric;
  v_ho  := (c->>'handles_objections')::numeric;
  v_ps  := (c->>'presents_solutions')::numeric;
  v_ldn := (c->>'listens_discovers_needs')::numeric;
  v_mha := (c->>'maintains_high_activity')::numeric;
  v_hr  := (c->>'handles_rejection')::numeric;
  v_rc  := (c->>'receives_coaching')::numeric;
  v_pit := (c->>'positively_influences_team')::numeric;

  v_raw := v_rrw*0.20 + v_cc*0.16 + v_ho*0.14 + v_ps*0.14 + v_ldn*0.12
         + v_mha*0.08 + v_hr*0.06 + v_rc*0.05 + v_pit*0.05;

  IF v_rrw <= v_cc THEN
    v_cap_src := 'rapid_rapport_warm'; v_cap_src_val := v_rrw;
  ELSE
    v_cap_src := 'cadence_compliance'; v_cap_src_val := v_cc;
  END IF;
  v_cap := v_cap_src_val + 15;
  v_final := GREATEST(0, LEAST(100, ROUND(LEAST(v_raw, v_cap))));

  RETURN jsonb_build_object(
    'fit_score', v_final,
    'raw_score', ROUND(v_raw, 2),
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
      'triggered', (ROUND(v_raw,2) > ROUND(v_cap,2)),
      'cap_value', ROUND(v_cap, 2),
      'cap_source_competency', v_cap_src,
      'cap_source_value', v_cap_src_val
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_sales_inbound_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v1_2026_07_21'
    )
  );
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 6: cts_role_fit_sales_in_book
--   Weights: CSI .20, LDN .16, RW .14, HO .12, PS .12, MHA .08, HR .06, RC .06, PIT .06
--   Floors: cross_sell_instinct, listens_discovers_needs → cap MIN+15
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.cts_role_fit_sales_in_book(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  c jsonb; m jsonb;
  v_csi numeric; v_ldn numeric; v_rw numeric; v_ho numeric; v_ps numeric;
  v_mha numeric; v_hr numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_cap numeric; v_cap_src text; v_cap_src_val numeric;
  v_final int;
BEGIN
  c := public.cts_sales_in_book_competencies_adjusted(p_assessment_id);
  IF c IS NULL OR NOT (c ? 'cross_sell_instinct') THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'sales_in_book');
  END IF;
  m := c->'_meta';

  v_csi := (c->>'cross_sell_instinct')::numeric;
  v_ldn := (c->>'listens_discovers_needs')::numeric;
  v_rw  := (c->>'retention_watchfulness')::numeric;
  v_ho  := (c->>'handles_objections')::numeric;
  v_ps  := (c->>'presents_solutions')::numeric;
  v_mha := (c->>'maintains_high_activity')::numeric;
  v_hr  := (c->>'handles_rejection')::numeric;
  v_rc  := (c->>'receives_coaching')::numeric;
  v_pit := (c->>'positively_influences_team')::numeric;

  v_raw := v_csi*0.20 + v_ldn*0.16 + v_rw*0.14 + v_ho*0.12 + v_ps*0.12
         + v_mha*0.08 + v_hr*0.06 + v_rc*0.06 + v_pit*0.06;

  IF v_csi <= v_ldn THEN
    v_cap_src := 'cross_sell_instinct'; v_cap_src_val := v_csi;
  ELSE
    v_cap_src := 'listens_discovers_needs'; v_cap_src_val := v_ldn;
  END IF;
  v_cap := v_cap_src_val + 15;
  v_final := GREATEST(0, LEAST(100, ROUND(LEAST(v_raw, v_cap))));

  RETURN jsonb_build_object(
    'fit_score', v_final,
    'raw_score', ROUND(v_raw, 2),
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
      'triggered', (ROUND(v_raw,2) > ROUND(v_cap,2)),
      'cap_value', ROUND(v_cap, 2),
      'cap_source_competency', v_cap_src,
      'cap_source_value', v_cap_src_val
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_sales_in_book_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v1_2026_07_21'
    )
  );
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 7: cts_role_fit_aspirant
--   Weights: HR .12, HO .10, MHA .10, PS .10, HES .10, LDN .08, PIC .08,
--            DCC .06, CFR .06, FSO .06, BLEH .06, PIT .05, RC .03
--   Floors: has_entrepreneurial_spirit, handles_rejection → cap MIN+15
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.cts_role_fit_aspirant(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  c jsonb; m jsonb;
  v_hr numeric; v_ho numeric; v_mha numeric; v_ps numeric;
  v_hes numeric; v_ldn numeric; v_pic numeric; v_dcc numeric;
  v_cfr numeric; v_fso numeric; v_bleh numeric; v_pit numeric; v_rc numeric;
  v_raw numeric;
  v_cap numeric; v_cap_src text; v_cap_src_val numeric;
  v_final int;
BEGIN
  c := public.cts_aspirant_competencies_adjusted(p_assessment_id);
  IF c IS NULL OR NOT (c ? 'has_entrepreneurial_spirit') THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'aspirant');
  END IF;
  m := c->'_meta';

  v_hr   := (c->>'handles_rejection')::numeric;
  v_ho   := (c->>'handles_objections')::numeric;
  v_mha  := (c->>'maintains_high_activity')::numeric;
  v_ps   := (c->>'presents_solutions')::numeric;
  v_hes  := (c->>'has_entrepreneurial_spirit')::numeric;
  v_ldn  := (c->>'listens_discovers_needs')::numeric;
  v_pic  := (c->>'prospects_in_community')::numeric;
  v_dcc  := (c->>'dials_cold_calls')::numeric;
  v_cfr  := (c->>'competes_for_recognition')::numeric;
  v_fso  := (c->>'is_fast_start_oriented')::numeric;
  v_bleh := (c->>'balances_logic_and_emotion_when_hiring')::numeric;
  v_pit  := (c->>'positively_influences_team')::numeric;
  v_rc   := (c->>'receives_coaching')::numeric;

  v_raw := v_hr*0.12 + v_ho*0.10 + v_mha*0.10 + v_ps*0.10
         + v_hes*0.10 + v_ldn*0.08 + v_pic*0.08 + v_dcc*0.06
         + v_cfr*0.06 + v_fso*0.06 + v_bleh*0.06 + v_pit*0.05 + v_rc*0.03;

  IF v_hes <= v_hr THEN
    v_cap_src := 'has_entrepreneurial_spirit'; v_cap_src_val := v_hes;
  ELSE
    v_cap_src := 'handles_rejection'; v_cap_src_val := v_hr;
  END IF;
  v_cap := v_cap_src_val + 15;
  v_final := GREATEST(0, LEAST(100, ROUND(LEAST(v_raw, v_cap))));

  RETURN jsonb_build_object(
    'fit_score', v_final,
    'raw_score', ROUND(v_raw, 2),
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
      'triggered', (ROUND(v_raw,2) > ROUND(v_cap,2)),
      'cap_value', ROUND(v_cap, 2),
      'cap_source_competency', v_cap_src,
      'cap_source_value', v_cap_src_val
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_aspirant_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v1_2026_07_21'
    )
  );
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 8: cts_role_fit_retention_reception
--   Weights: RRW .18, LDN .16, CUL .14, RJ .14, PCN .12, MDQ .10, RC .08, PIT .08
--   Floors: rapid_rapport_warm, composure_under_load → cap MIN+15
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.cts_role_fit_retention_reception(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  c jsonb; m jsonb;
  v_rrw numeric; v_ldn numeric; v_cul numeric; v_rj numeric; v_pcn numeric;
  v_mdq numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_cap numeric; v_cap_src text; v_cap_src_val numeric;
  v_final int;
BEGIN
  c := public.cts_retention_reception_competencies_adjusted(p_assessment_id);
  IF c IS NULL OR NOT (c ? 'rapid_rapport_warm') THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'retention_reception');
  END IF;
  m := c->'_meta';

  v_rrw := (c->>'rapid_rapport_warm')::numeric;
  v_ldn := (c->>'listens_discovers_needs')::numeric;
  v_cul := (c->>'composure_under_load')::numeric;
  v_rj  := (c->>'routing_judgment')::numeric;
  v_pcn := (c->>'pivots_to_customer_need')::numeric;
  v_mdq := (c->>'makes_decisions_quickly')::numeric;
  v_rc  := (c->>'receives_coaching')::numeric;
  v_pit := (c->>'positively_influences_team')::numeric;

  v_raw := v_rrw*0.18 + v_ldn*0.16 + v_cul*0.14 + v_rj*0.14 + v_pcn*0.12
         + v_mdq*0.10 + v_rc*0.08 + v_pit*0.08;

  IF v_rrw <= v_cul THEN
    v_cap_src := 'rapid_rapport_warm'; v_cap_src_val := v_rrw;
  ELSE
    v_cap_src := 'composure_under_load'; v_cap_src_val := v_cul;
  END IF;
  v_cap := v_cap_src_val + 15;
  v_final := GREATEST(0, LEAST(100, ROUND(LEAST(v_raw, v_cap))));

  RETURN jsonb_build_object(
    'fit_score', v_final,
    'raw_score', ROUND(v_raw, 2),
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
      'triggered', (ROUND(v_raw,2) > ROUND(v_cap,2)),
      'cap_value', ROUND(v_cap, 2),
      'cap_source_competency', v_cap_src,
      'cap_source_value', v_cap_src_val
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_retention_reception_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v1_2026_07_21'
    )
  );
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 9: cts_role_fit_retention_escalation
--   Weights: HO .16, LDN .16, RW .14, PTD .14, CUL .12, PS .10, MHA .06, RC .06, PIT .06
--   Floors: handles_objections, listens_discovers_needs → cap MIN+15
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.cts_role_fit_retention_escalation(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  c jsonb; m jsonb;
  v_ho numeric; v_ldn numeric; v_rw numeric; v_ptd numeric; v_cul numeric;
  v_ps numeric; v_mha numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_cap numeric; v_cap_src text; v_cap_src_val numeric;
  v_final int;
BEGIN
  c := public.cts_retention_escalation_competencies_adjusted(p_assessment_id);
  IF c IS NULL OR NOT (c ? 'handles_objections') THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'retention_escalation');
  END IF;
  m := c->'_meta';

  v_ho  := (c->>'handles_objections')::numeric;
  v_ldn := (c->>'listens_discovers_needs')::numeric;
  v_rw  := (c->>'retention_watchfulness')::numeric;
  v_ptd := (c->>'proactive_touch_discipline')::numeric;
  v_cul := (c->>'composure_under_load')::numeric;
  v_ps  := (c->>'presents_solutions')::numeric;
  v_mha := (c->>'maintains_high_activity')::numeric;
  v_rc  := (c->>'receives_coaching')::numeric;
  v_pit := (c->>'positively_influences_team')::numeric;

  v_raw := v_ho*0.16 + v_ldn*0.16 + v_rw*0.14 + v_ptd*0.14 + v_cul*0.12
         + v_ps*0.10 + v_mha*0.06 + v_rc*0.06 + v_pit*0.06;

  IF v_ho <= v_ldn THEN
    v_cap_src := 'handles_objections'; v_cap_src_val := v_ho;
  ELSE
    v_cap_src := 'listens_discovers_needs'; v_cap_src_val := v_ldn;
  END IF;
  v_cap := v_cap_src_val + 15;
  v_final := GREATEST(0, LEAST(100, ROUND(LEAST(v_raw, v_cap))));

  RETURN jsonb_build_object(
    'fit_score', v_final,
    'raw_score', ROUND(v_raw, 2),
    'role', 'retention_escalation',
    'contributions', jsonb_build_object(
      'handles_objections',        public._cts_role_fit_contrib(v_ho,  0.16, true),
      'listens_discovers_needs',   public._cts_role_fit_contrib(v_ldn, 0.16, true),
      'retention_watchfulness',    public._cts_role_fit_contrib(v_rw,  0.14, false),
      'proactive_touch_discipline',public._cts_role_fit_contrib(v_ptd, 0.14, false),
      'composure_under_load',      public._cts_role_fit_contrib(v_cul, 0.12, false),
      'presents_solutions',        public._cts_role_fit_contrib(v_ps,  0.10, false),
      'maintains_high_activity',   public._cts_role_fit_contrib(v_mha, 0.06, false),
      'receives_coaching',         public._cts_role_fit_contrib(v_rc,  0.06, false),
      'positively_influences_team',public._cts_role_fit_contrib(v_pit, 0.06, false)
    ),
    'floors', jsonb_build_object(
      'triggered', (ROUND(v_raw,2) > ROUND(v_cap,2)),
      'cap_value', ROUND(v_cap, 2),
      'cap_source_competency', v_cap_src,
      'cap_source_value', v_cap_src_val
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_retention_escalation_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v1_2026_07_21'
    )
  );
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PART 10: cts_role_fit_retention_support
--   Weights: AD .20, QTD .18, WWCS .14, MTE .12, AN .10, MDQ .10, RC .08, PIT .08
--   Floors: attention_to_detail, queue_throughput_discipline → cap MIN+15
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.cts_role_fit_retention_support(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  c jsonb; m jsonb;
  v_ad numeric; v_qtd numeric; v_wwcs numeric; v_mte numeric;
  v_an numeric; v_mdq numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_cap numeric; v_cap_src text; v_cap_src_val numeric;
  v_final int;
BEGIN
  c := public.cts_retention_support_competencies_adjusted(p_assessment_id);
  IF c IS NULL OR NOT (c ? 'attention_to_detail') THEN
    RETURN jsonb_build_object('fit_score', NULL, 'error', 'no_trait_data', 'role', 'retention_support');
  END IF;
  m := c->'_meta';

  v_ad   := (c->>'attention_to_detail')::numeric;
  v_qtd  := (c->>'queue_throughput_discipline')::numeric;
  v_wwcs := (c->>'works_without_close_supervision')::numeric;
  v_mte  := (c->>'manages_time_effectively')::numeric;
  v_an   := (c->>'analytical')::numeric;
  v_mdq  := (c->>'makes_decisions_quickly')::numeric;
  v_rc   := (c->>'receives_coaching')::numeric;
  v_pit  := (c->>'positively_influences_team')::numeric;

  v_raw := v_ad*0.20 + v_qtd*0.18 + v_wwcs*0.14 + v_mte*0.12
         + v_an*0.10 + v_mdq*0.10 + v_rc*0.08 + v_pit*0.08;

  IF v_ad <= v_qtd THEN
    v_cap_src := 'attention_to_detail'; v_cap_src_val := v_ad;
  ELSE
    v_cap_src := 'queue_throughput_discipline'; v_cap_src_val := v_qtd;
  END IF;
  v_cap := v_cap_src_val + 15;
  v_final := GREATEST(0, LEAST(100, ROUND(LEAST(v_raw, v_cap))));

  RETURN jsonb_build_object(
    'fit_score', v_final,
    'raw_score', ROUND(v_raw, 2),
    'role', 'retention_support',
    'contributions', jsonb_build_object(
      'attention_to_detail',           public._cts_role_fit_contrib(v_ad,   0.20, true),
      'queue_throughput_discipline',   public._cts_role_fit_contrib(v_qtd,  0.18, true),
      'works_without_close_supervision',public._cts_role_fit_contrib(v_wwcs, 0.14, false),
      'manages_time_effectively',      public._cts_role_fit_contrib(v_mte,  0.12, false),
      'analytical',                    public._cts_role_fit_contrib(v_an,   0.10, false),
      'makes_decisions_quickly',       public._cts_role_fit_contrib(v_mdq,  0.10, false),
      'receives_coaching',             public._cts_role_fit_contrib(v_rc,   0.08, false),
      'positively_influences_team',    public._cts_role_fit_contrib(v_pit,  0.08, false)
    ),
    'floors', jsonb_build_object(
      'triggered', (ROUND(v_raw,2) > ROUND(v_cap,2)),
      'cap_value', ROUND(v_cap, 2),
      'cap_source_competency', v_cap_src,
      'cap_source_value', v_cap_src_val
    ),
    'meta', jsonb_build_object(
      'weight_sum', 1.00,
      'adjusted_source', 'cts_retention_support_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v1_2026_07_21'
    )
  );
END;
$function$;
