CREATE OR REPLACE FUNCTION public.cts_role_fit_sales_inbound_v2(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  c jsonb; m jsonb; g jsonb;
  v_rrw numeric; v_cc numeric; v_ho numeric; v_ps numeric; v_ldn numeric;
  v_mha numeric; v_hr numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
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
    v_floor_src := 'rapid_rapport_warm'; v_floor_src_val := v_rrw;
  ELSE
    v_floor_src := 'cadence_compliance'; v_floor_src_val := v_cc;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates_v2(p_assessment_id, 'sales_inbound', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

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
      'adjusted_source', 'cts_sales_inbound_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v2_2026_07_21'
    )
  );
END;
$function$;
