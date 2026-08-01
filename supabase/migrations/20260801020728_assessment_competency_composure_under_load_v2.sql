-- Step 4 rewire fn #6: assessment_competency_composure_under_load → v2 signal + helper

INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'composure_under_load',
  45,
  $notes$Floor set at 45 for Composure Under Load (LSS Step 4 rewire fn #6).

Rationale:
- Emotional regulation under time/stakes pressure. Hybrid competency: trait-based stress reactivity + executive-function underpinning.
- Base formula: optimism weighted heaviest (0.38); analytical carries NEGATIVE weight (-0.08) — over-analysis under duress backfires.
- Under load, cognitive resources are partially consumed. Below composite 45, cognitive strain compounds with stress; spare capacity for emotion regulation drops.
- Above 45, trait-based emotional stability (Big Five Neuroticism dimension) carries the competency.
- Slotting: cadence_compliance (40) < composure_under_load (45) < attention_to_detail (55). Midpoint reflects hybrid personality + moderate cognitive load.

Citations:
- Barrick & Mount 1991 (Personnel Psychology 44, 1-26) — Neuroticism/emotional stability meta-analysis
- Baumeister et al. 1998 (JPSP 74, 1252-1265) — ego depletion; executive-function-under-load
- Judge & Ilies 2002 (JAP 87, 797-807) — personality traits + performance under stress
- Vinchur, Schippmann, Switzer & Roth 1998 — emotional stability in sales performance
- Zhou/Kuncel/Sackett 2024; Kane 1996; Sweller 1988; Coward/Sackett 1990 — curve shape (see helper)$notes$,
  'claude_conversation'
)
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor = EXCLUDED.floor, notes = EXCLUDED.notes,
    updated_at = now(), updated_by = EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_composure_under_load(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $function$
/*
Competency: Composure Under Load (LSS Step 4 rewire — v2 signal + 2c curve via helper).
Base = 7.69 + 0.38*optimism + 0.15*compassion + 0.15*assertiveness
     + 0.08*independent_spirit + 0.08*deadline_motivation + 0.08*belief_in_others - 0.08*analytical.
LSS penalty via hiregauge_lss_penalty_v2(composite, floor). Floor row: 'composure_under_load' (45).
Reliability adjustment around 50 midpoint unchanged.
*/
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
  dm numeric := p_candidate.deadline_motivation;
  ass numeric := p_candidate.assertiveness;
  is_val numeric := p_candidate.independent_spirit;
  an numeric := p_candidate.analytical;
  com numeric := public._assessment_dampen_trait_by_distortion(p_candidate.compassion, 'compassion', p_candidate.response_distortion);
  bo numeric := public._assessment_dampen_trait_by_distortion(p_candidate.belief_in_others, 'belief_in_others', p_candidate.response_distortion);
  op numeric := public._assessment_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF dm IS NULL THEN
    v_base := NULL;
  ELSE
    v_base := GREATEST(0, LEAST(100, ROUND(
      (7.692308) + (+0.384615)*op + (+0.153846)*com + (+0.153846)*ass + (+0.076923)*is_val + (+0.076923)*dm + (+0.076923)*bo + (-0.076923)*an
    )::int));
  END IF;

  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;

  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'composure_under_load';

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
