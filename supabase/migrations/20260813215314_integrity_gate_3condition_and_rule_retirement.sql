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
-- ARCHITECTURE: compares the RAW (undampened) self-report composite to the
-- floor -- never a dampened or reliability-shrunk 'adjusted' value.
-- Ellingson, Sackett & Hough 1999 (JAP 84 155-166): social-
-- desirability corrections do not recover an individual's honest score --
-- later reviews found they work at group level but not individual level and
-- do not improve prediction. Raw values are the only permitted input to
-- this gate -- never a dampened or adjusted display value.
--
-- CONJUNCTIVE GATE -- 3 conditions required for even the shadow "would
-- decline" record (condition 4, impression_management_band='typical',
-- REMOVED 2026-08-13: faking-good is now handled upstream by protocol-
-- validity weighting -- _newtworks_protocol_validity down-weights the
-- self-report layer feeding role fit AND shrinks Character/Commitment
-- toward the population mean when faking is detected, so a flagged faker's
-- low raw composite no longer needs a separate carve-out here; the
-- upstream mechanism already accounts for the reduced trustworthiness of
-- that low score):
--   1. RAW self-report composite (mean of sincerity/fairness/greed_avoidance, no dampening or shrinkage
--      applied) < 40.
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
--
-- LIVE BEHAVIOUR (the only thing this gate does today): when all three
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
  v_all_three boolean := false;
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

  v_all_three := v_raw_low AND v_sjt_low AND v_reliability_clean;

  v_conditions := jsonb_build_object(
    'raw_composite_low', jsonb_build_object('met', v_raw_low, 'value', v_raw_composite, 'floor', v_raw_floor),
    'sjt_honesty_low',   jsonb_build_object('met', v_sjt_low, 'value', v_sjt_score, 'floor', v_sjt_floor, 'n', v_sjt_n),
    'reliability_clean', jsonb_build_object('met', v_reliability_clean, 'reliability', p_candidate.reliability,
                                             'fired_count', NULLIF(p_candidate.reliability_detail->>'fired_count','')::int)
  );

  RETURN jsonb_build_object(
    'gate', 'integrity_decline',
    'fired', false,
    'shadow_would_decline', v_all_three,
    'live_soft_flag', v_all_three,
    'conditions', v_conditions,
    'mode', 'shadow'
  );
END;
$function$;

UPDATE public.hiregauge_rules
SET is_active = false,
    notes = COALESCE(notes || ' | ', '') || 'Superseded 2026-08-13 by protocol-validity weighting (v in role fit + verdict). Old rule keyed to retired CTS column response_distortion.'
WHERE rule_name = 'HIGH distortion → decline';

UPDATE public.hiregauge_rules
SET is_active = false,
    notes = COALESCE(notes || ' | ', '') || 'Superseded 2026-08-13; references retired lss_total_accuracy column.'
WHERE rule_name = 'Validity-LSS-Compound (Invalid Profile)';

UPDATE public.hiregauge_rules
SET is_active = false,
    notes = COALESCE(notes || ' | ', '') || 'Superseded 2026-08-13: low reliability now down-weights the self-report layer (rel_mult 0.50) instead of requiring retest.'
WHERE rule_name = 'LOW reliability → retest required';
