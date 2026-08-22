-- Integrity gate (a) rebuild per Peter directive 2026-08-03 (shadow mode).
-- Full rationale in function docstrings below.

-- New columns for shadow-mode record-keeping + the one live consequence.
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS integrity_gate_shadow_result text;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS integrity_gate_shadow_reason jsonb;
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS integrity_flag boolean DEFAULT false;

CREATE OR REPLACE FUNCTION public._newtworks_integrity_decline_gate(p_candidate hiring_candidates)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
-- SHADOW MODE per Peter directive 2026-08-03. This gate NEVER hard-declines
-- live -- integrity self-report validity is contested, not settled (Ones,
-- Viswesvaran & Schmidt 1993: .41 vs supervisor ratings, 665 coefficients;
-- Van Iddekinge, Roth, Raymark & Odle-Dusseau 2012 JAP 97(3) 499-530 redid
-- it and got .15/.18 corrected; three rebuttals + Sackett & Schmitt 2012 JAP
-- 97(3) 550-556 in the same issue, unresolved). Their own moderators point
-- the wrong way for a homemade instrument scored against future real
-- outcomes: .27 publisher-authored vs .12 non-publisher; .42 self-reported
-- misconduct vs .11 other-reported / .15 employment-record misconduct. Our
-- three self-report facets (sincerity, fairness, greed_avoidance) are also
-- the most-faked item type in selection -- applicant scores compress near
-- the top, so low scorers are disproportionately the candid and the
-- careless, not the dishonest.
--
-- ARCHITECTURE FIX vs the prior version of this function: compares the RAW
-- (undampened) self-report composite to the floor, NOT
-- newtworks_competency_integrity's dampened+reliability-shrunk 'adjusted'
-- value. Ellingson, Sackett & Hough 1999 (JAP 84 155-166): social-
-- desirability corrections do not recover an individual's honest score --
-- later reviews found they work at group level but not individual level and
-- do not improve prediction. Dampening stays in place for DISPLAY and the
-- compensatory role_fit average (newtworks_competency_integrity, untouched
-- by this migration) -- it must never feed this gate.
--
-- CONJUNCTIVE GATE -- all four conditions required for even the shadow
-- "would decline" record:
--   1. RAW self-report composite (mean of sincerity/fairness/greed_avoidance,
--      not run through the competency-layer dampen+shrink) < 40.
--   2. sjt_honesty_integrity component below its own floor -- the
--      contextualised scenario measure, hardest to fake, and per Sackett et
--      al. 2022 contextualised measures show far more stable validity than
--      decontextualised self-report. Floor set at 50% (2 of 4 items) --
--      PROVISIONAL, a build-session judgment call (no published norms exist
--      for a homemade 4-item scenario set), watch and revisit alongside the
--      raw-composite floor at N=25-30.
--   3. Careless-responding / reliability check CLEAN (reliability='high' AND
--      zero methods fired). A low score from a careless responder is a
--      measurement failure, not a red flag -- goes to human review, not this
--      gate.
--   4. Faking-good NOT flagged (impression_management_band='typical'). A
--      detected faker's low score is also a measurement failure, not a red
--      flag.
--
-- LIVE BEHAVIOUR (the only thing this gate does today): when all four
-- conditions hold, cap verdict at 'consider' + set a visible integrity flag
-- -- same soft treatment as a critical-floor breach. Never an auto-decline.
-- 'fired' stays permanently false (no consumer should ever treat this gate
-- as a hard-decline source) -- 'live_soft_flag' is the real live signal, and
-- 'shadow_would_decline' is the recorded-but-inactive full-strength result
-- for Peter to review once 25-30 real candidates have been scored. Flipping
-- this gate to an actual decline is Peter's call, not a build decision.
DECLARE
  v_raw_composite numeric;
  v_raw_floor CONSTANT numeric := 40;
  v_raw_low boolean := false;
  v_sjt_score numeric;
  v_sjt_floor CONSTANT numeric := 50;
  v_sjt_n int;
  v_sjt_low boolean := false;
  v_reliability_clean boolean := false;
  v_im_not_flagged boolean := false;
  v_all_four boolean := false;
  v_conditions jsonb;
BEGIN
  IF p_candidate.sincerity IS NOT NULL AND p_candidate.fairness IS NOT NULL
     AND p_candidate.greed_avoidance IS NOT NULL THEN
    v_raw_composite := ROUND((p_candidate.sincerity + p_candidate.fairness + p_candidate.greed_avoidance) / 3.0, 1);
    v_raw_low := v_raw_composite < v_raw_floor;
  END IF;

  v_sjt_n := NULLIF(p_candidate.sjt_topic_detail->'sjt_honesty_integrity'->>'n', '')::int;
  IF v_sjt_n IS NOT NULL AND v_sjt_n > 0 THEN
    v_sjt_score := ROUND(100.0 * (p_candidate.sjt_topic_detail->'sjt_honesty_integrity'->>'correct')::numeric / v_sjt_n, 1);
    v_sjt_low := v_sjt_score < v_sjt_floor;
  END IF;

  v_reliability_clean := p_candidate.reliability = 'high'
    AND COALESCE(NULLIF(p_candidate.reliability_detail->>'fired_count','')::int, 0) = 0;

  v_im_not_flagged := p_candidate.impression_management_band = 'typical';

  v_all_four := v_raw_low AND v_sjt_low AND v_reliability_clean AND v_im_not_flagged;

  v_conditions := jsonb_build_object(
    'raw_composite_low', jsonb_build_object('met', v_raw_low, 'value', v_raw_composite, 'floor', v_raw_floor),
    'sjt_honesty_low',   jsonb_build_object('met', v_sjt_low, 'value', v_sjt_score, 'floor', v_sjt_floor, 'n', v_sjt_n),
    'reliability_clean', jsonb_build_object('met', v_reliability_clean, 'reliability', p_candidate.reliability,
                                             'fired_count', NULLIF(p_candidate.reliability_detail->>'fired_count','')::int),
    'faking_not_flagged', jsonb_build_object('met', v_im_not_flagged, 'band', p_candidate.impression_management_band)
  );

  RETURN jsonb_build_object(
    'gate', 'integrity_decline',
    'fired', false,
    'shadow_would_decline', v_all_four,
    'live_soft_flag', v_all_four,
    'conditions', v_conditions,
    'mode', 'shadow'
  );
END;
$function$;

-- Wire the new shape into the gated core: 'fired' is permanently false now
-- so hard_decline via this path is structurally impossible (matches "decline
-- nobody"). live_soft_flag drives the one live consequence: cap at
-- 'consider' + gates_fired entry, same treatment as critical_floor.
CREATE OR REPLACE FUNCTION public._newtworks_role_fit_gated_core(p_candidate hiring_candidates, p_role_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_fit jsonb;
  v_comp jsonb;
  v_comp_name text;
  v_critical_breaches jsonb := '[]'::jsonb;
  v_integrity_gate jsonb;
  v_reasoning_gate jsonb;
  v_gates_fired text[] := ARRAY[]::text[];
  v_verdict_cap text := NULL;
  v_hard_decline boolean := false;
BEGIN
  v_fit := public._newtworks_role_fit_core(p_candidate, p_role_category);

  IF v_fit ? 'error' THEN
    RETURN v_fit;
  END IF;

  FOR v_comp_name, v_comp IN SELECT * FROM jsonb_each(v_fit->'competencies') LOOP
    IF v_comp->>'tier' = 'critical'
       AND (v_comp->>'floor') IS NOT NULL
       AND (v_comp->>'adjusted') IS NOT NULL
       AND (v_comp->>'adjusted')::numeric < (v_comp->>'floor')::numeric
    THEN
      v_critical_breaches := v_critical_breaches || jsonb_build_array(jsonb_build_object(
        'competency', v_comp_name,
        'value', (v_comp->>'adjusted')::numeric,
        'threshold', (v_comp->>'floor')::numeric
      ));
    END IF;
  END LOOP;

  IF jsonb_array_length(v_critical_breaches) > 0 THEN
    v_gates_fired := array_append(v_gates_fired, 'critical_floor');
    v_verdict_cap := 'consider';
  END IF;

  -- Gate (a): shadow mode. See _newtworks_integrity_decline_gate docstring.
  v_integrity_gate := public._newtworks_integrity_decline_gate(p_candidate);
  IF (v_integrity_gate->>'live_soft_flag')::boolean THEN
    v_gates_fired := array_append(v_gates_fired, 'integrity_flag');
    v_verdict_cap := 'consider';
  END IF;

  v_reasoning_gate := public._newtworks_reasoning_gate(p_candidate, p_role_category);
  IF (v_reasoning_gate->>'fired')::boolean THEN
    v_gates_fired := array_append(v_gates_fired, 'reasoning_floor');
    v_verdict_cap := 'consider';
  END IF;

  RETURN v_fit || jsonb_build_object(
    'gates_fired', to_jsonb(v_gates_fired),
    'verdict_cap', CASE WHEN v_hard_decline THEN 'decline' ELSE v_verdict_cap END,
    'hard_decline', v_hard_decline,
    'churn_risk', COALESCE((v_reasoning_gate->>'churn_risk_fired')::boolean, false),
    'gate_detail', jsonb_build_object(
      'critical_floor_breaches', v_critical_breaches,
      'integrity_decline', v_integrity_gate,
      'reasoning', v_reasoning_gate
    )
  );
END;
$function$;
