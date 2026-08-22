INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'cross_sell_instinct',
  55,
  $notes$Floor set at 55 for Cross-Sell Instinct (LSS Step 4 rewire fn #7).

Rationale:
- Hybrid cognitive-emotional competency: base formula weights compassion (0.21) and analytical (0.21) equally.
- Requires: working-memory maintenance (customer's full picture), analogical reasoning (this situation → that coverage pattern), emotional attunement.
- Below composite 55, working-memory strain compromises the "hold whole picture + generate cross-sell suggestions on-the-fly" workflow — same tier as attention_to_detail.
- Not analytical-tier (60) because the reasoning is pattern-recognition-driven rather than abstract; developed through experience with compassion as enabler.

Citations:
- Vinchur, Schippmann, Switzer & Roth 1998 (JAP 83, 586-597) — cognitive-ability meta-analysis for sales
- Frei & McDaniel 1998 — customer service orientation moderates need identification
- Barrick & Mount 1991 — Agreeableness (compassion proxy) meta-analytic weight in service roles
- Salthouse 1996 — working-memory maintenance under multi-attribute load
- Zhou/Kuncel/Sackett 2024; Kane 1996; Sweller 1988; Coward/Sackett 1990 — curve shape (see helper)$notes$,
  'claude_conversation'
)
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor = EXCLUDED.floor, notes = EXCLUDED.notes,
    updated_at = now(), updated_by = EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_cross_sell_instinct(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $function$
/*
Competency: Cross-Sell Instinct (LSS Step 4 rewire — v2 signal + 2c curve via helper).
Base = 5.26 + 0.21*compassion + 0.21*analytical + 0.16*self_promotion
     + 0.11*belief_in_others + 0.11*recognition_drive + 0.11*assertiveness
     + 0.05*deadline_motivation - 0.05*independent_spirit.
LSS penalty via hiregauge_lss_penalty_v2. Floor row: 'cross_sell_instinct' (55).
*/
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
  dm numeric := p_candidate.deadline_motivation;
  rd numeric := p_candidate.recognition_drive;
  ass numeric := p_candidate.assertiveness;
  is_val numeric := p_candidate.independent_spirit;
  an numeric := p_candidate.analytical;
  com numeric := public._assessment_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  sp numeric := public._assessment_dampen_trait_by_distortion(p_candidate.self_promotion, 'self_promotion', p_candidate.response_distortion);
  bo numeric := public._assessment_dampen_trait_by_distortion(p_candidate.belief_in_others, 'belief_in_others', p_candidate.response_distortion);
BEGIN
  IF com IS NULL THEN
    v_base := NULL;
  ELSE
    v_base := GREATEST(0, LEAST(100, ROUND(
      (5.263158) + (+0.210526)*com + (+0.210526)*an + (+0.157895)*sp + (+0.105263)*bo + (+0.105263)*rd + (+0.105263)*ass + (+0.052632)*dm + (-0.052632)*is_val
    )::int));
  END IF;

  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;

  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'cross_sell_instinct';

  v_mult := public.hiregauge_lss_penalty_v2(v_composite, v_floor);

  IF v_base IS NULL THEN
    v_adjusted := NULL; v_delta := 0;
  ELSE
    v_pre_rel := v_base * v_mult;
    v_delta := v_pre_rel - v_base;
    v_rel_factor := COALESCE(public._assessment_reliability_confidence(p_candidate.reliability), 1.0);
    IF v_pre_rel >= 50 THEN
      v_adjusted := GREATEST(0, LEAST(100, ROUND(50 + (v_pre_rel - 50) * v_rel_factor)))::int;
    ELSE
      v_adjusted := GREATEST(0, LEAST(100, ROUND(v_pre_rel)))::int;
    END IF;
  END IF;

  RETURN jsonb_build_object('base', v_base, 'adjusted', v_adjusted, 'delta', v_delta,
    'composite', v_composite, 'floor', v_floor, 'lss_multiplier', v_mult, 'components', v_lss_result);
END; $function$;
