CREATE OR REPLACE FUNCTION public.cts_role_fit_aspirant_v2(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  c jsonb; m jsonb; g jsonb;
  v_hr numeric; v_ho numeric; v_mha numeric; v_ps numeric;
  v_hes numeric; v_ldn numeric; v_pic numeric; v_dcc numeric;
  v_cfr numeric; v_fso numeric; v_bleh numeric; v_pit numeric; v_rc numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
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
    v_floor_src := 'has_entrepreneurial_spirit'; v_floor_src_val := v_hes;
  ELSE
    v_floor_src := 'handles_rejection'; v_floor_src_val := v_hr;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates_v2(p_assessment_id, 'aspirant', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

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
      'adjusted_source', 'cts_aspirant_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v2_2026_07_21'
    )
  );
END;
$function$;
