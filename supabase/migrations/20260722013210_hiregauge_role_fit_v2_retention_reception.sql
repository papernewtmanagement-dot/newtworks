CREATE OR REPLACE FUNCTION public.cts_role_fit_retention_reception_v2(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  c jsonb; m jsonb; g jsonb;
  v_rrw numeric; v_ldn numeric; v_cul numeric; v_rj numeric; v_pcn numeric;
  v_mdq numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
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
    v_floor_src := 'rapid_rapport_warm'; v_floor_src_val := v_rrw;
  ELSE
    v_floor_src := 'composure_under_load'; v_floor_src_val := v_cul;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates_v2(p_assessment_id, 'retention_reception', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

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
      'adjusted_source', 'cts_retention_reception_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v2_2026_07_21'
    )
  );
END;
$function$;
