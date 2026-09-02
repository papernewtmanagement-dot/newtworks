-- Ranking-block (Section 2, 75 forced-choice quads) validity checks.
-- Peter directive 2026-09-02: "Add the speed check."
--
-- WHY: on 2026-08-27 a candidate clicked through all 75 ranking blocks in 10 minutes
-- (median 2.7 seconds per block; every other completion sat between 14.5 and 53.5
-- seconds) and, in the 25 mixed blocks, ranked the flattering statement above the
-- unflattering one only 58% of the time (chance is 50%; the other 18 completions ran
-- 74% to 96%). Those answers are not personality data, yet the candidate's record read
-- reliability = high and protocol validity = high, because every careless-responding
-- check in hiregauge_v2_reliability_composite reads the rating-scale section
-- (newtworks_v2_personality) or the retest pairs, and the retest pairs were deleted on
-- 2026-08-25 with the old bank. Nothing looked at the ranking blocks at all.
--
-- WHAT: two new checks in the same shape as the existing careless-responding checks
-- (fired boolean + detail text), folded into hiregauge_v2_reliability_composite so
-- the reliability label carries them into protocol validity the way the design already
-- intends (Meade & Craig 2012, Psychological Methods 17:437-455, careless responding
-- degrades measurement; evidence-weighting, never score correction, per
-- _newtworks_protocol_validity). apply_newtworks_v2_reliability_to_candidate also writes a
-- non-blocking flag to assessment_flags and an alert, mirroring the Stint 1 pattern.
--
-- NEVER AN ELIMINATOR. Standing rule "Response speed is a FLAG, never an eliminator
-- (2026-08-16)". These checks lower the reliability label (high / moderate / low) and
-- raise a flag. They do not stop, decline, or cap anyone.
--
-- THRESHOLDS ARE PROVISIONAL (N = 19 completions, set 2026-09-02):
--   fast:         median under 8.0 seconds per block, OR 10%+ of blocks under 3 seconds.
--                 Four statements cannot be read and ranked in 8 seconds. Fastest
--                 apparently-honest median in the first 19 was 14.5 s.
--   inconsistent: in the mixed blocks (2 positive-pole + 2 negative-pole statements),
--                 fewer than 65% of positive-over-negative pairs ranked positive above
--                 negative. Chance = 50%. Range in the first 19 excluding the random
--                 responder: 74% to 96%. Requires at least 20 scorable pairs.
--   Revisit both at N >= 50 (same checkpoint as the other reliability bands).
--
-- POLE SEMANTICS: in hiregauge_instrument_items.choices->options, pole '+' is the
-- DESIRABLE end for every facet, including anger and anxiety (where '+' is the calm end).
-- So positive-above-negative is desirability-consistent for all 25 facets; no facet
-- special-casing here, unlike the scorer (compute_newtworks_v2fcq_facets_as_row).

CREATE OR REPLACE FUNCTION public.hiregauge_v2fcq_careless_fast_blocks(p_candidate_id uuid)
 RETURNS TABLE(fired boolean, detail text)
 LANGUAGE sql
 STABLE
AS $function$
  WITH blocks AS (
    SELECT EXTRACT(EPOCH FROM (r.answered_at - r.served_at))::numeric AS secs
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v2_personality_fc_quad'
      AND r.served_at IS NOT NULL
      AND r.answered_at IS NOT NULL
  ),
  agg AS (
    SELECT count(*)::int AS n_blocks,
           count(*) FILTER (WHERE secs < 3)::int AS n_under3,
           (percentile_cont(0.5) WITHIN GROUP (ORDER BY secs))::numeric AS median_secs
    FROM blocks
  )
  SELECT
    (n_blocks > 0 AND (median_secs < 8.0
                       OR n_under3::numeric / n_blocks >= 0.10)) AS fired,
    CASE WHEN n_blocks = 0
         THEN 'skipped - no ranking blocks with timing'
         ELSE format('median %ss per ranking block across %s blocks; %s under 3s (provisional: fires under 8s median or 10%% of blocks under 3s)',
                     round(COALESCE(median_secs, 0), 1)::text, n_blocks, n_under3)
    END AS detail
  FROM agg;
$function$;

CREATE OR REPLACE FUNCTION public.hiregauge_v2fcq_careless_pole_consistency(p_candidate_id uuid)
 RETURNS TABLE(fired boolean, detail text)
 LANGUAGE sql
 STABLE
AS $function$
  WITH blocks AS (
    SELECT r.response_label, i.choices->'options' AS opts
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v2_personality_fc_quad'
      AND i.choices->>'block_kind' = 'MX'
      AND r.response_label ~ '^[A-D]{4}$'
  ),
  pairs AS (
    SELECT (position(p.key IN b.response_label) < position(n.key IN b.response_label))::int AS pos_above
    FROM blocks b
    CROSS JOIN LATERAL jsonb_each(b.opts) p
    CROSS JOIN LATERAL jsonb_each(b.opts) n
    WHERE p.value->>'pole' = '+' AND n.value->>'pole' = '-'
  ),
  agg AS (
    SELECT count(*)::int AS n_pairs, avg(pos_above)::numeric AS share
    FROM pairs
  )
  SELECT
    (n_pairs >= 20 AND share < 0.65) AS fired,
    CASE WHEN n_pairs < 20
         THEN format('skipped - only %s mixed-block pairs scorable, need 20', n_pairs)
         ELSE format('flattering statement ranked above unflattering in %s%% of %s mixed-block pairs (chance 50%%; provisional: fires under 65%%)',
                     round(share * 100)::text, n_pairs)
    END AS detail
  FROM agg;
$function$;

CREATE OR REPLACE FUNCTION public.hiregauge_v2_reliability_composite(p_candidate_id uuid)
 RETURNS TABLE(reliability text, fired_count integer, reliability_detail jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
-- 2026-09-02: two ranking-block checks added (ranking_blocks_fast,
-- ranking_blocks_inconsistent). Bands unchanged: 0-1 checks fired = high,
-- 2 = moderate, 3+ = low. See migration fcq_ranking_block_validity_checks.
DECLARE
  r_fast RECORD;
  r_slow RECORD;
  r_straight RECORD;
  r_retest RECORD;
  r_evenodd RECORD;
  r_bogus RECORD;
  r_fcq_fast RECORD;
  r_fcq_pole RECORD;
  v_fired_count int;
  v_detail jsonb;
BEGIN
  SELECT * INTO r_fast FROM public.hiregauge_v2_careless_response_time_fast(p_candidate_id);
  SELECT * INTO r_slow FROM public.hiregauge_v2_careless_disengagement_slow(p_candidate_id);
  SELECT * INTO r_straight FROM public.hiregauge_v2_careless_straightlining(p_candidate_id);
  SELECT * INTO r_retest FROM public.hiregauge_v2_careless_retest_divergence(p_candidate_id);
  SELECT * INTO r_evenodd FROM public.hiregauge_v2_careless_evenodd_consistency(p_candidate_id);
  SELECT * INTO r_bogus FROM public.hiregauge_v2_careless_bogus_items(p_candidate_id);
  SELECT * INTO r_fcq_fast FROM public.hiregauge_v2fcq_careless_fast_blocks(p_candidate_id);
  SELECT * INTO r_fcq_pole FROM public.hiregauge_v2fcq_careless_pole_consistency(p_candidate_id);

  v_fired_count :=
    (r_fast.fired)::int + (r_slow.fired)::int + (r_straight.fired)::int +
    (r_retest.fired)::int + (r_evenodd.fired)::int + (r_bogus.fired)::int +
    (r_fcq_fast.fired)::int + (r_fcq_pole.fired)::int;

  v_detail := jsonb_build_object(
    'response_time_fast',          jsonb_build_object('fired', r_fast.fired,     'detail', r_fast.detail),
    'disengagement_slow',          jsonb_build_object('fired', r_slow.fired,     'detail', r_slow.detail),
    'straightlining',              jsonb_build_object('fired', r_straight.fired, 'detail', r_straight.detail),
    'retest_divergence',           jsonb_build_object('fired', r_retest.fired,   'detail', r_retest.detail),
    'evenodd_consistency',         jsonb_build_object('fired', r_evenodd.fired,  'detail', r_evenodd.detail),
    'bogus_items',                 jsonb_build_object('fired', r_bogus.fired,    'detail', r_bogus.detail),
    'ranking_blocks_fast',         jsonb_build_object('fired', r_fcq_fast.fired, 'detail', r_fcq_fast.detail),
    'ranking_blocks_inconsistent', jsonb_build_object('fired', r_fcq_pole.fired, 'detail', r_fcq_pole.detail),
    'fired_count',                 v_fired_count,
    'computed_at',                 now()
  );

  RETURN QUERY SELECT
    CASE
      WHEN v_fired_count <= 1 THEN 'high'
      WHEN v_fired_count = 2 THEN 'moderate'
      ELSE 'low'
    END,
    v_fired_count,
    v_detail;
END;
$function$;

CREATE OR REPLACE FUNCTION public.apply_newtworks_v2_reliability_to_candidate(p_candidate_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
-- 2026-09-02: after writing the reliability label, record the two ranking-block
-- checks as non-blocking flags in assessment_flags (same {flag, detail} shape as the
-- Stint 1 flags) and raise one 'assessment_flag' alert, mirroring
-- apply_hiregauge_v2_stint1_exit_gate. Flags are replaced by name on re-run so a
-- rescore never duplicates them. Nothing here stops or declines a candidate.
DECLARE
  v_row       RECORD;
  v_agency    uuid;
  v_name      text;
  v_position  text;
  v_existing  jsonb;
  v_new       jsonb := '[]'::jsonb;
  v_link      text;
BEGIN
  SELECT * INTO v_row FROM public.hiregauge_v2_reliability_composite(p_candidate_id);

  UPDATE public.hiring_candidates
  SET reliability = v_row.reliability,
      reliability_detail = v_row.reliability_detail
  WHERE id = p_candidate_id;

  IF (v_row.reliability_detail->'ranking_blocks_fast'->>'fired')::boolean THEN
    v_new := v_new || jsonb_build_array(jsonb_build_object(
      'flag', 'ranking_blocks_fast',
      'detail', 'Ranking blocks answered too fast to have been read: '
                || (v_row.reliability_detail->'ranking_blocks_fast'->>'detail')
                || '. Personality scores from this sitting should not be trusted. Interview probe or retake - not a decline reason.'));
  END IF;

  IF (v_row.reliability_detail->'ranking_blocks_inconsistent'->>'fired')::boolean THEN
    v_new := v_new || jsonb_build_array(jsonb_build_object(
      'flag', 'ranking_blocks_inconsistent',
      'detail', 'Ranking blocks look random: '
                || (v_row.reliability_detail->'ranking_blocks_inconsistent'->>'detail')
                || '. Personality scores from this sitting should not be trusted. Interview probe or retake - not a decline reason.'));
  END IF;

  IF jsonb_array_length(v_new) = 0 THEN
    RETURN;
  END IF;

  SELECT agency_id,
         NULLIF(trim(coalesce(first_name,'') || ' ' || coalesce(last_name,'')), ''),
         coalesce(position, 'unspecified role'),
         coalesce(assessment_flags, '[]'::jsonb)
  INTO v_agency, v_name, v_position, v_existing
  FROM public.hiring_candidates WHERE id = p_candidate_id;

  -- Replace any earlier copies of these two flags, keep everything else.
  SELECT coalesce(jsonb_agg(f), '[]'::jsonb) INTO v_existing
  FROM jsonb_array_elements(v_existing) f
  WHERE f->>'flag' NOT IN ('ranking_blocks_fast', 'ranking_blocks_inconsistent');

  UPDATE public.hiring_candidates
  SET assessment_flags = v_existing || v_new,
      updated_at = now()
  WHERE id = p_candidate_id;

  v_link := 'https://newtworks.vercel.app/?module=team&candidate=' || p_candidate_id::text;

  INSERT INTO public.alerts (
    agency_id, alert_type, severity, title, message,
    module_reference, related_id, is_read, is_resolved
  )
  SELECT v_agency,
         'assessment_flag',
         'warning',
         format('Ranking blocks not trustworthy: %s', coalesce(v_name, 'Unknown candidate')),
         format('%s (%s): %s The candidate was NOT stopped and was told nothing. %s',
                coalesce(v_name, 'This candidate'), v_position,
                (SELECT string_agg(f->>'detail', ' ') FROM jsonb_array_elements(v_new) f),
                v_link),
         'hiring',
         p_candidate_id,
         false,
         false
  WHERE NOT EXISTS (
    SELECT 1 FROM public.alerts
    WHERE agency_id = v_agency
      AND alert_type = 'assessment_flag'
      AND related_id = p_candidate_id
      AND title LIKE 'Ranking blocks not trustworthy%'
  );
END;
$function$;
