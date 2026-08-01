-- Step 4 rewire fn #5: assessment_competency_competes_for_recognition → v2 signal + helper

INSERT INTO public.hiregauge_competency_floors (agency_id, competency_name, floor, notes, updated_by)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'competes_for_recognition',
  35,
  $notes$Floor set at 35 for Competes for Recognition (LSS Step 4 rewire fn #5).

Rationale:
- Purely motivational competency (base formula = 1.0 * recognition_drive, single-trait passthrough).
- Internal drive for recognition doesn't require working-memory load. Someone highly competitive can pursue recognition independent of cognitive capacity.
- Below composite 35, general cognitive function is impaired enough that sustained self-monitoring + social comparison may become patchy — but only in extreme cases.
- Slightly below cadence_compliance floor (40): cadence needs working memory for schedule adherence; recognition drive doesn't.

Citations:
- Barrick & Mount 1991 (Personnel Psychology 44, 1-26) — Big Five meta-analysis; extraversion/ambition weakly correlated with g
- Judge et al. 1999 (Personnel Psychology 52, 621-652) — 5-factor model; recognition-related traits carry variance independent of g
- Hunter & Hunter 1984 — low-complexity motivational competencies at bottom of validity range
- Zhou/Kuncel/Sackett 2024; Kane 1996; Sweller 1988; Coward/Sackett 1990 — curve shape rationale (see helper docstring)$notes$,
  'claude_conversation'
)
ON CONFLICT (agency_id, competency_name) DO UPDATE
SET floor = EXCLUDED.floor, notes = EXCLUDED.notes,
    updated_at = now(), updated_by = EXCLUDED.updated_by;

CREATE OR REPLACE FUNCTION public.assessment_competency_competes_for_recognition(p_candidate hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $function$
/*
Competency: Competes for Recognition (LSS Step 4 rewire — v2 signal + 2c curve via helper).
Base = 1.0 * recognition_drive (single-trait passthrough).
LSS penalty via hiregauge_lss_penalty_v2(composite, floor).
Floor row: competency_name='competes_for_recognition' (35).
Reliability adjustment around 50 midpoint unchanged from v1.
*/
DECLARE
  v_base int; v_lss_result jsonb; v_composite numeric; v_floor numeric; v_mult numeric;
  v_pre_rel numeric; v_rel_factor numeric; v_adjusted int; v_delta numeric;
  rd numeric := p_candidate.recognition_drive;
BEGIN
  IF rd IS NULL THEN
    v_base := NULL;
  ELSE
    v_base := GREATEST(0, LEAST(100, ROUND((0.000000) + (+1.000000)*rd)::int));
  END IF;

  v_lss_result := public.hiregauge_lss_delta_v2(p_candidate);
  v_composite := (v_lss_result->>'intelligence_composite')::numeric;

  SELECT floor INTO v_floor FROM public.hiregauge_competency_floors
    WHERE agency_id = p_candidate.agency_id AND competency_name = 'competes_for_recognition';

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
