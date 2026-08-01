-- Step 4 rewire fn #4: assessment_competency_cadence_compliance → v2 signal + 2c curve

INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'cadence_compliance',
  40,
  $notes$Floor set at 40 for Cadence Compliance (LSS Step 4 rewire fn #4).

Rationale:
- Routine schedule adherence: attendance, weekly reports on time, follow-through on standing checklists. Personality-heavy competency (base weights deadline_motivation 0.45).
- Two failure modes: personality (base score catches via deadline_motivation weight) and cognitive (working-memory strain around remembering schedules).
- Cognitive floor kicks in near composite 40 — below this, working-memory limits interact with routine cadence.
- Above 40, personality traits (conscientiousness proxies) carry the score fully.

Citations:
- Hunter & Hunter 1984 — low-complexity band, validity r≈.40
- Barrick & Mount 1991 — conscientiousness meta-analysis (r≈.22); personality dominates at this cognitive level
- Frei & McDaniel 1998 — service work: conscientiousness carries more variance than g at moderate complexity
- Zhou/Kuncel/Sackett 2024; Kane 1996; Sweller 1988; Coward/Sackett 1990 — curve shape rationale$notes$,
  'claude_conversation'
)
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor = EXCLUDED.floor, notes = EXCLUDED.notes,
    updated_at = now(), updated_by = EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_cadence_compliance(p_candidate hiring_candidates)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
/*
Competency: Cadence Compliance (LSS Step 4 rewire — v2 signal + 2c curve).

Base score: unit-weighted linear composite (Wainer 1976; Ree/Earles/Teachout 1994).
  base = 15 + 0.15*recognition_drive + 0.10*assertiveness + 0.10*analytical + 0.45*deadline_motivation
       - 0.10*independent_spirit - 0.05*self_promotion + 0.05*optimism

LSS penalty: 2c monotonic floor curve on intelligence composite (hiregauge_lss_delta_v2).
Floor lookup: hiregauge_competency_floors WHERE competency_name='cadence_compliance'.
Reliability adjustment: applied around 50 midpoint (unchanged from v1).

Research: Barrick & Mount 1991; Frei & McDaniel 1998; Hunter & Hunter 1984; Zhou/Kuncel/Sackett 2024; Kane 1996; Sweller 1988; Coward/Sackett 1990; Sheppard/Vernon 2008; Ratcliff 1993; van Zandt 2000.
*/
DECLARE
  v_base int;
  v_lss_result jsonb;
  v_composite numeric;
  v_floor numeric;
  v_mult numeric;
  v_pre_rel numeric;
  v_rel_factor numeric;
  v_adjusted int;
  v_delta numeric;
  rd numeric := p_candidate.recognition_drive;
  ass numeric := p_candidate.assertiveness;
  an numeric := p_candidate.analytical;
  dm numeric := p_candidate.deadline_motivation;
  is_val numeric := p_candidate.independent_spirit;
  sp numeric := public._assessment_dampen_trait_by_distortion(p_candidate.self_promotion, 'self_promotion', p_candidate.response_distortion);
  op numeric := public._assessment_dampen_trait_by_distortion(p_candidate.optimism, 'optimism', p_candidate.response_distortion);
BEGIN
  IF dm IS NULL THEN
    v_base := NULL;
  ELSE
    v_base := GREATEST(0, LEAST(100, ROUND(
      (15.000000) + (+0.150000)*rd + (+0.100000)*ass + (+0.100000)*an + (+0.450000)*dm + (-0.100000)*is_val + (-0.050000)*sp + (+0.050000)*op
    )::int));
  END IF;

  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;

  SELECT floor INTO v_floor
  FROM public.hiregauge_competency_floors
  WHERE agency_id = p_candidate.agency_id AND competency_name = 'cadence_compliance';

  IF v_composite IS NULL OR v_floor IS NULL THEN
    v_mult := 1.0;
  ELSIF v_composite >= v_floor THEN
    v_mult := 1.0;
  ELSE
    v_mult := exp(-3.0 * (v_floor - v_composite) / v_floor);
  END IF;

  IF v_base IS NULL THEN
    v_adjusted := NULL;
    v_delta := 0;
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

  RETURN jsonb_build_object(
    'base',           v_base,
    'adjusted',       v_adjusted,
    'delta',          v_delta,
    'composite',      v_composite,
    'floor',          v_floor,
    'lss_multiplier', v_mult,
    'components',     v_lss_result
  );
END;
$function$;
