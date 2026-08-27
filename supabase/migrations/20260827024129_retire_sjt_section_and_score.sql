-- CUT THE SCENARIOS (Peter directive 2026-08-26: "Cut the scenarios and the situational
-- judgement score"). Basis: 54 scored candidates, median 14 of 15 correct, top 10% perfect --
-- a ceiling test that ranks nobody; its floor function (honesty, composure, rules) is
-- covered by Section 1, the personality traits, and week-one training.
--
--   1. delete the 15 scenario items (stint 4) and their answers (FK cascade)
--   2. clear sjt_score / sjt_topic_detail for everyone
--   3. drop the scorer apply_newtworks_v2_sjt_to_candidate; remove the 'sjt' role-fit weight
--      rows (role fit renormalizes over the remaining inputs) and the 'sjt' pool-norm row
--   4. the shadow integrity gate loses its SJT condition: it becomes a 2-condition gate
--      (raw self-report composite < 40 AND clean reliability). Still shadow, still never
--      hard-declines.
--   5. section check constraint drops newtworks_v2_sjt. The edge function drops stint 4 in
--      the companion commit (stint 5 follows stint 2).
-- NOT touched: Section 1, the quad blocks, the written screen, GMA scoring.

DELETE FROM public.hiregauge_instrument_items WHERE section = 'newtworks_v2_sjt' OR stint = 4;

UPDATE public.hiring_candidates SET sjt_score = NULL, sjt_topic_detail = NULL
WHERE sjt_score IS NOT NULL OR sjt_topic_detail IS NOT NULL;

DROP FUNCTION IF EXISTS public.apply_newtworks_v2_sjt_to_candidate(uuid);
DELETE FROM public.hiregauge_role_facet_weights WHERE input_name = 'sjt';
DELETE FROM public.hiregauge_facet_norms WHERE facet = 'sjt';

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
-- CONJUNCTIVE GATE -- 2 conditions required for even the shadow "would
-- decline" record. (Condition 4, impression_management_band='typical',
-- REMOVED 2026-08-13: faking-good is handled upstream by protocol-validity
-- weighting. Condition 2, the sjt_honesty_integrity scenario floor, REMOVED
-- 2026-08-26 when Peter cut the scenario section -- 54 candidates showed it
-- was a ceiling test with no ranking power.)
--   1. RAW self-report composite (mean of sincerity/fairness/greed_avoidance, no dampening or shrinkage
--      applied) < 40.
--   2. Careless-responding / reliability check CLEAN (reliability='high' AND
--      zero methods fired). A low score from a careless responder is a
--      measurement failure, not a red flag -- goes to human review, not this
--      gate.
--
-- LIVE BEHAVIOUR (the only thing this gate does today): when both
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
  v_reliability_clean boolean := false;
  v_both boolean := false;
  v_conditions jsonb;
BEGIN
  IF p_candidate.sincerity IS NOT NULL AND p_candidate.fairness IS NOT NULL
     AND p_candidate.greed_avoidance IS NOT NULL THEN
    v_raw_composite := ROUND((p_candidate.sincerity + p_candidate.fairness + p_candidate.greed_avoidance) / 3.0, 1);
    v_raw_low := v_raw_composite < v_raw_floor;
  END IF;

  v_reliability_clean := p_candidate.reliability = 'high'
    AND COALESCE(NULLIF(p_candidate.reliability_detail->>'fired_count','')::int, 0) = 0;

  v_both := v_raw_low AND v_reliability_clean;

  v_conditions := jsonb_build_object(
    'raw_composite_low', jsonb_build_object('met', v_raw_low, 'value', v_raw_composite, 'floor', v_raw_floor),
    'reliability_clean', jsonb_build_object('met', v_reliability_clean, 'reliability', p_candidate.reliability,
                                             'fired_count', NULLIF(p_candidate.reliability_detail->>'fired_count','')::int)
  );

  RETURN jsonb_build_object(
    'gate', 'integrity_decline',
    'fired', false,
    'shadow_would_decline', v_both,
    'live_soft_flag', v_both,
    'conditions', v_conditions,
    'mode', 'shadow'
  );
END;
$function$;

ALTER TABLE public.hiregauge_instrument_items
  DROP CONSTRAINT IF EXISTS hiregauge_instrument_items_section_check;
ALTER TABLE public.hiregauge_instrument_items
  ADD CONSTRAINT hiregauge_instrument_items_section_check
  CHECK (section = ANY (ARRAY['instructions'::text,'vct'::text,'cognitive'::text,'cts'::text,
    'newtworks_v1_personality'::text,'newtworks_v1_impression_mgmt'::text,'newtworks_v1_vct'::text,
    'newtworks_v2_personality'::text,'newtworks_v2_cognitive_gma'::text,'newtworks_v2_impression_mgmt'::text,
    'newtworks_v2_vct'::text,'newtworks_v2_screen'::text,
    'newtworks_v2_personality_fc_quad'::text]));
