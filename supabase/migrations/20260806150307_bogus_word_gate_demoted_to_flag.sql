-- Demote the made-up-word check from an eliminator to an internal flag.
-- Peter directive 2026-08-06.
--
-- WHY. The old threshold (2 or more of 4 made-up words claimed) fired on
-- guessing, not on dishonesty. The items are forced-choice: four plausible
-- definitions plus "None of these". A candidate who does not know the word
-- and picks anyway claims on 4 of every 5 items by chance, so a random
-- guesser trips a 2-of-4 threshold 97% of the time. Even at the false-alarm
-- rate reported in the source paper's own normative sample (.25), about 26%
-- of honest candidates trip it. Paulhus, Harms, Bruce & Lysy 2003, Journal
-- of Personality and Social Psychology 84(4) 890-904, score claiming as a
-- CONTINUOUS bias index off familiarity ratings and never as a pass/fail
-- cutoff; and they correct claiming against accuracy on real items, which
-- this gate ignored entirely. The careless-responding literature that
-- licenses knockout bogus items (DeSimone, Harms & DeSimone 2015, Journal
-- of Organizational Behavior 36(2) 171-181) requires items that are obvious
-- or ridiculous, where every attentive person gives the same answer
-- ("I have 17 fingers"). Judging that "prontivate" is not a word is a
-- vocabulary judgement, not an attention check.
--
-- This also restores the original design record, which specified this
-- micro-instance as a "validity flag, not scored construct".
--
-- ALSO FIXED HERE: the claim count used "is_correct IS NOT TRUE", so an
-- ungraded or skipped item (NULL) counted as a false claim. Now "= false",
-- matching hiregauge_v2_careless_bogus_items, which always used "= false".
--
-- ALSO ADDED: real-word hit count. The instrument already serves 4 real
-- vocabulary words alongside the 4 made-up ones. Reporting both is what
-- makes the flag interpretable -- high claiming with high real-word accuracy
-- is a confident reader, not a faker.

CREATE OR REPLACE FUNCTION public.hiregauge_v2_stint1_exit_gate(p_candidate_id uuid, p_sitting integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_expected      int;
  v_answered      int;
  v_bogus_total   int;
  v_bogus_claimed int;
  v_real_total    int;
  v_real_correct  int;
  v_median_secs   numeric;
  v_rating_timed  int;
  v_run_len       int;
  v_integrity     numeric;
  v_integrity_n   int;
  v_gma_correct   int;
  v_gma_total     int;
  v_gate          text := NULL;
  v_reason        text := NULL;
  v_flags         jsonb := '[]'::jsonb;
BEGIN
  SELECT count(*)::int INTO v_expected
  FROM public.hiregauge_instrument_items i
  WHERE i.stint = 1 AND i.is_active = true
    AND i.section IN ('newtworks_v2_personality','newtworks_v2_cognitive_gma','newtworks_v2_sjt');

  SELECT count(*)::int INTO v_answered
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
  WHERE r.candidate_id = p_candidate_id
    AND r.sitting = p_sitting
    AND i.stint = 1 AND i.is_active = true;

  IF v_expected = 0 OR v_answered < v_expected THEN
    RETURN jsonb_build_object(
      'stint1_complete', false,
      'gate_fired', NULL,
      'flags', v_flags,
      'answered', v_answered,
      'expected', v_expected
    );
  END IF;

  -- FLAG (no longer a gate): made-up words claimed as known, reported
  -- alongside accuracy on the real words from the same block. Interpret the
  -- pair, never the claim count alone. See the WHY block on this migration.
  SELECT count(*)::int,
         count(*) FILTER (WHERE r.is_correct = false)::int
  INTO v_bogus_total, v_bogus_claimed
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
  WHERE r.candidate_id = p_candidate_id
    AND r.sitting = p_sitting
    AND i.stint = 1 AND i.is_active = true
    AND i.is_nonsense = true;

  SELECT count(*)::int,
         count(*) FILTER (WHERE r.is_correct = true)::int
  INTO v_real_total, v_real_correct
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
  WHERE r.candidate_id = p_candidate_id
    AND r.sitting = p_sitting
    AND i.stint = 1 AND i.is_active = true
    AND i.is_nonsense = false
    AND i.item_text ILIKE 'What does the word%';

  IF v_bogus_total > 0 AND v_bogus_claimed >= 2 THEN
    v_flags := v_flags || jsonb_build_object(
      'flag', 'vocabulary_overclaiming',
      'detail', format('Claimed to know %s of %s made-up words, and got %s of %s real words right. Interview probe only — not a decline reason.',
                       v_bogus_claimed, v_bogus_total, v_real_correct, v_real_total)
    );
  END IF;

  -- GATE A2: median time per rating-scale item under 2 seconds.
  -- Existing Newtworks standard; consistent with Huang, Curran, Keeney,
  -- Poposki & DeShon 2012, Journal of Business and Psychology 27(1) 99-114.
  SELECT count(*)::int,
         percentile_cont(0.5) WITHIN GROUP (
           ORDER BY EXTRACT(EPOCH FROM (r.answered_at - r.served_at))::numeric)
  INTO v_rating_timed, v_median_secs
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
  WHERE r.candidate_id = p_candidate_id
    AND r.sitting = p_sitting
    AND i.stint = 1 AND i.is_active = true
    AND i.section = 'newtworks_v2_personality'
    AND i.scale_max IS NOT NULL AND i.scale_max > 1
    AND r.served_at IS NOT NULL AND r.answered_at IS NOT NULL;

  -- GATE A3: same answer position on 10 or more consecutive rating-scale
  -- items, where at least one item in the run is reverse-worded (so agreeing
  -- straight down the column is self-contradictory).
  -- Long-string index: Meade & Craig 2012, Psychological Methods 17(3) 437-455.
  WITH ordered AS (
    SELECT r.response_value,
           i.reverse_coded,
           ROW_NUMBER() OVER (ORDER BY r.served_at, r.id) AS pos
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND r.sitting = p_sitting
      AND i.stint = 1 AND i.is_active = true
      AND i.section = 'newtworks_v2_personality'
      AND i.scale_max IS NOT NULL AND i.scale_max > 1
      AND r.response_value IS NOT NULL
      AND r.served_at IS NOT NULL
  ),
  grouped AS (
    SELECT response_value,
           reverse_coded,
           pos - ROW_NUMBER() OVER (PARTITION BY response_value ORDER BY pos) AS run_key
    FROM ordered
  ),
  runs AS (
    SELECT count(*)::int AS run_length,
           bool_or(reverse_coded) AS has_reverse
    FROM grouped
    GROUP BY response_value, run_key
  )
  SELECT COALESCE(max(run_length) FILTER (WHERE has_reverse), 0)
  INTO v_run_len
  FROM runs;

  -- GATE B: equally-weighted composite of the three honesty facets, 0-100.
  -- Floor set deliberately low. Self-report honesty scales cluster high
  -- because of social desirability, with an expected mean near 65-70, so
  -- below 30 is a candidate stating in writing that they behave dishonestly.
  -- Ones, Viswesvaran & Schmidt 1993, Journal of Applied Psychology 78(4)
  -- 679-703 support the construct but warn against hard cut scores without
  -- local validation. That warning is why this is 30 and not 50.
  SELECT AVG(f.facet_score)::numeric, count(*)::int
  INTO v_integrity, v_integrity_n
  FROM public.compute_newtworks_v2_facets_as_row(p_candidate_id, 1, p_sitting) f
  WHERE f.hypothesized_trait IN ('sincerity','fairness','greed_avoidance');

  -- GATE C: reasoning at or below chance.
  -- With three to six answer choices, random guessing yields about 3.5 correct
  -- out of 16. At or below that, the candidate either could not engage with the
  -- questions or was not trying. Anchored to chance, NOT to a percentile: these
  -- reasoning items are home-grown, have no published norms and no response
  -- data, so any percentile cutoff today would be invented. Explicitly do not
  -- use the hiregauge_role_ideal_ranges floors here -- those sit on a composite
  -- scale that cannot be computed for these items.
  SELECT count(*) FILTER (WHERE r.is_correct IS TRUE)::int,
         count(*)::int
  INTO v_gma_correct, v_gma_total
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
  WHERE r.candidate_id = p_candidate_id
    AND r.sitting = p_sitting
    AND i.stint = 1 AND i.is_active = true
    AND i.section = 'newtworks_v2_cognitive_gma';

  -- Order matters. First failure wins. The made-up-word check is NOT in this
  -- chain any more -- it is a flag only. Do not re-add it without new
  -- direction from Peter; see the WHY block on this migration.
  IF v_rating_timed > 0 AND v_median_secs IS NOT NULL AND v_median_secs < 2 THEN
    v_gate := 'gate_a_honest_answering';
    v_reason := format('Median time per rating item was %s seconds across %s items.',
                       round(v_median_secs, 2), v_rating_timed);
  ELSIF v_run_len >= 10 THEN
    v_gate := 'gate_a_honest_answering';
    v_reason := format('Same answer position on %s consecutive rating items, including reverse-worded ones.', v_run_len);
  ELSIF v_integrity_n = 3 AND v_integrity IS NOT NULL AND v_integrity < 30 THEN
    v_gate := 'gate_b_integrity';
    v_reason := format('Honesty composite %s of 100 (sincerity, fairness, greed-avoidance equally weighted).',
                       round(v_integrity, 1));
  ELSIF v_gma_total > 0 AND v_gma_correct <= 3 THEN
    v_gate := 'gate_c_reasoning';
    v_reason := format('%s of %s reasoning items correct, at or below the guessing baseline of about 3.5.',
                       v_gma_correct, v_gma_total);
  END IF;

  RETURN jsonb_build_object(
    'stint1_complete', true,
    'gate_fired', v_gate,
    'reason', v_reason,
    'flags', v_flags,
    'checks', jsonb_build_object(
      'bogus_words_claimed', v_bogus_claimed,
      'bogus_words_total', v_bogus_total,
      'real_words_correct', v_real_correct,
      'real_words_total', v_real_total,
      'median_rating_seconds', v_median_secs,
      'rating_items_timed', v_rating_timed,
      'longest_identical_run_with_reverse', v_run_len,
      'integrity_composite', v_integrity,
      'integrity_facets_scored', v_integrity_n,
      'reasoning_correct', v_gma_correct,
      'reasoning_total', v_gma_total
    ),
    'evaluated_at', now()
  );
END;
$function$;

-- Home for non-blocking flags. Deliberately NOT assessment_exit_detail --
-- that column means "why we stopped them" and must keep meaning that.
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS assessment_flags jsonb;

COMMENT ON COLUMN public.hiring_candidates.assessment_flags IS
  'Non-blocking assessment observations for interview probing. Never a decline reason. Written by apply_hiregauge_v2_stint1_exit_gate.';

CREATE OR REPLACE FUNCTION public.apply_hiregauge_v2_stint1_exit_gate(p_candidate_id uuid, p_sitting integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_enabled   text;
  v_agency    uuid;
  v_existing  text;
  v_verdict   jsonb;
  v_gate      text;
  v_reason    text;
  v_flags     jsonb;
  v_name      text;
  v_position  text;
  v_chat      bigint;
  v_link      text;
  v_dm_err    text := NULL;
BEGIN
  SELECT setting_value INTO v_enabled
  FROM public.settings WHERE setting_key = 'hiregauge_exit_gates_enabled';

  SELECT agency_id,
         NULLIF(trim(coalesce(first_name,'') || ' ' || coalesce(last_name,'')), ''),
         coalesce(position, 'unspecified role'),
         assessment_exit_gate
  INTO v_agency, v_name, v_position, v_existing
  FROM public.hiring_candidates WHERE id = p_candidate_id;

  IF v_agency IS NULL THEN
    RETURN jsonb_build_object('error', 'candidate_not_found', 'candidate_id', p_candidate_id);
  END IF;

  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('gate_fired', v_existing, 'already_recorded', true);
  END IF;

  IF coalesce(v_enabled, 'false') <> 'true' THEN
    RETURN jsonb_build_object('gate_fired', NULL, 'skipped', 'gates_disabled');
  END IF;

  v_verdict := public.hiregauge_v2_stint1_exit_gate(p_candidate_id, p_sitting);
  v_gate := v_verdict->>'gate_fired';
  v_reason := v_verdict->>'reason';
  v_flags := coalesce(v_verdict->'flags', '[]'::jsonb);

  v_link := 'https://newtworks.vercel.app/?module=team&candidate=' || p_candidate_id::text;

  -- Flags are recorded whether or not a gate fired, and never block. Written
  -- before the gate branch so a flagged-and-gated candidate keeps both records.
  IF jsonb_array_length(v_flags) > 0 THEN
    UPDATE public.hiring_candidates
    SET assessment_flags = v_flags,
        updated_at = now()
    WHERE id = p_candidate_id;

    INSERT INTO public.alerts (
      agency_id, alert_type, severity, title, message,
      module_reference, related_id, is_read, is_resolved
    )
    SELECT v_agency,
           'assessment_flag',
           'info',
           format('Assessment flag: %s', coalesce(v_name, 'Unknown candidate')),
           format('%s (%s) picked up a non-blocking assessment flag. %s The candidate was NOT stopped and was told nothing. %s',
                  coalesce(v_name, 'This candidate'), v_position,
                  (SELECT string_agg(f->>'detail', ' ') FROM jsonb_array_elements(v_flags) f),
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
    );
  END IF;

  IF v_gate IS NULL THEN
    RETURN v_verdict || jsonb_build_object('wrote', false, 'flags_written', jsonb_array_length(v_flags) > 0);
  END IF;

  UPDATE public.hiring_candidates
  SET assessment_exit_gate = v_gate,
      assessment_exit_detail = v_verdict,
      assessment_exited_at = now(),
      updated_at = now()
  WHERE id = p_candidate_id;

  INSERT INTO public.alerts (
    agency_id, alert_type, severity, title, message,
    module_reference, related_id, is_read, is_resolved
  )
  SELECT v_agency,
         'assessment_exit_gate',
         'warning',
         format('Assessment stopped early: %s', coalesce(v_name, 'Unknown candidate')),
         format('%s did not pass the Stint 1 screen for %s. Gate: %s. %s The candidate was shown a neutral completion screen and told nothing. All responses collected so far are kept. %s',
                coalesce(v_name, 'This candidate'), v_position, v_gate, v_reason, v_link),
         'hiring',
         p_candidate_id,
         false,
         false
  WHERE NOT EXISTS (
    SELECT 1 FROM public.alerts
    WHERE agency_id = v_agency
      AND alert_type = 'assessment_exit_gate'
      AND related_id = p_candidate_id
  );

  SELECT telegram_user_id INTO v_chat
  FROM public.team
  WHERE agency_id = v_agency
    AND role_level = 'Owner'
    AND is_admin_backoffice = false
    AND archived_at IS NULL
  LIMIT 1;

  IF v_chat IS NOT NULL THEN
    BEGIN
      PERFORM public.paper_newt_send_message(
        p_chat_id := v_chat,
        p_text := format(E'\u26D4 Assessment stopped early: %s (%s)\n%s\n%s\nCandidate was told nothing. Responses kept.\n%s',
                         coalesce(v_name, 'Unknown candidate'), v_position, v_gate, v_reason, v_link)
      );
    EXCEPTION WHEN OTHERS THEN
      v_dm_err := SQLERRM;
    END;
  ELSE
    v_dm_err := 'owner_chat_id_missing';
  END IF;

  RETURN v_verdict || jsonb_build_object('wrote', true, 'dm_error', v_dm_err, 'flags_written', jsonb_array_length(v_flags) > 0);
END;
$function$;
