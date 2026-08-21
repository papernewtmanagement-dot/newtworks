CREATE OR REPLACE FUNCTION public.cts_role_fit_retention_escalation_v2(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  c jsonb; m jsonb; g jsonb;
  v_ho numeric; v_ldn numeric; v_rw numeric; v_ptd numeric; v_cul numeric;
  v_ps numeric; v_hr numeric; v_mha numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
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
  v_hr  := (c->>'handles_rejection')::numeric;
  v_mha := (c->>'maintains_high_activity')::numeric;
  v_rc  := (c->>'receives_coaching')::numeric;
  v_pit := (c->>'positively_influences_team')::numeric;

  v_raw := v_ho*0.16 + v_ldn*0.12 + v_rw*0.14 + v_ptd*0.14 + v_cul*0.14
         + v_ps*0.10 + v_hr*0.06 + v_mha*0.04 + v_rc*0.05 + v_pit*0.05;

  IF v_ho <= v_cul THEN
    v_floor_src := 'handles_objections'; v_floor_src_val := v_ho;
  ELSE
    v_floor_src := 'composure_under_load'; v_floor_src_val := v_cul;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates_v2(p_assessment_id, 'retention_escalation', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

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
      'adjusted_source', 'cts_retention_escalation_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v2_2026_07_21'
    )
  );
END;
$function$;
