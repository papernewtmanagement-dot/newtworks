CREATE OR REPLACE FUNCTION public.cts_role_fit_retention_support_v2(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  c jsonb; m jsonb; g jsonb;
  v_ad numeric; v_qtd numeric; v_wwcs numeric; v_mte numeric;
  v_an numeric; v_mdq numeric; v_rc numeric; v_pit numeric;
  v_raw numeric;
  v_floor_cap numeric; v_floor_src text; v_floor_src_val numeric;
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

  v_raw := v_ad*0.20 + v_qtd*0.20 + v_wwcs*0.14 + v_mte*0.14
         + v_an*0.06 + v_mdq*0.10 + v_rc*0.08 + v_pit*0.08;

  IF v_ad <= v_qtd THEN
    v_floor_src := 'attention_to_detail'; v_floor_src_val := v_ad;
  ELSE
    v_floor_src := 'queue_throughput_discipline'; v_floor_src_val := v_qtd;
  END IF;
  v_floor_cap := v_floor_src_val + 15;

  g := public._cts_role_fit_apply_gates_v2(p_assessment_id, 'retention_support', v_raw, v_floor_cap, v_floor_src, v_floor_src_val);

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
      'adjusted_source', 'cts_retention_support_competencies_adjusted',
      'has_lss', COALESCE(m->>'has_lss','false')::boolean,
      'reliability', m->>'reliability',
      'distortion', m->>'distortion',
      'model', 'competency_fit_v2_2026_07_21'
    )
  );
END;
$function$;
