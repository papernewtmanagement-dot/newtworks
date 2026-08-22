-- ============================================================================
-- Stint 1 exit gate (Step 3 of the 2026-08-02 assessment build handoff).
--
-- Fires once Stint 1 is complete and before Stint 2 is served. Three gates are
-- evaluated in order; the first failure wins and records its reason.
--
-- LEGAL NOTE: any fixed cutoff used to exclude applicants is a selection
-- procedure under the Uniform Guidelines on Employee Selection Procedures
-- (29 CFR Part 1607). These thresholds are anchored either to chance
-- performance or to self-admitted dishonesty, which is the most defensible
-- form available before local validation data exists. Every number here is
-- PROVISIONAL and must be revisited after 30 completed assessments against
-- real distributions. Do not raise any threshold without that data.
--
-- The gate ends the assessment. It does NOT change candidate status and does
-- NOT decline anyone. Hiring decisions stay with the owner and stay subject to
-- the document-before-you-decide rule.
-- ============================================================================

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS assessment_exit_gate text,
  ADD COLUMN IF NOT EXISTS assessment_exit_detail jsonb,
  ADD COLUMN IF NOT EXISTS assessment_exited_at timestamptz;

COMMENT ON COLUMN public.hiring_candidates.assessment_exit_gate IS
  'Which Stint 1 exit gate ended the assessment: gate_a_honest_answering, gate_b_integrity, gate_c_reasoning. NULL = no gate fired.';

INSERT INTO public.settings (agency_id, setting_key, setting_value, setting_type, description)
SELECT '126794dd-25ff-47d2-a436-724499733365'::uuid,
       'hiregauge_exit_gates_enabled',
       'true',
       'boolean',
       'Master switch for the Stint 1 exit gates. Set to anything other than true and the assessment runs straight through with no early exit.'
WHERE NOT EXISTS (
  SELECT 1 FROM public.settings WHERE setting_key = 'hiregauge_exit_gates_enabled'
);

-- ---------------------------------------------------------------------------
-- Evaluator. Read-only. Returns the verdict plus every underlying number so a
-- decision can be audited later without re-running anything.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.hiregauge_v2_stint1_exit_gate(
  p_candidate_id uuid,
  p_sitting integer DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
  v_expected      int;
  v_answered      int;
  v_bogus_total   int;
  v_bogus_claimed int;
  v_median_secs   numeric;
  v_rating_timed  int;
  v_run_len       int;
  v_integrity     numeric;
  v_integrity_n   int;
  v_gma_correct   int;
  v_gma_total     int;
  v_gate          text := NULL;
  v_reason        text := NULL;
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
      'answered', v_answered,
      'expected', v_expected
    );
  END IF;

  -- GATE A1: made-up words claimed as known.
  -- A "none of these" choice is offered on every one, so claiming two or more
  -- of four is not chance. Over-claiming technique: Paulhus, Harms, Bruce &
  -- Lysy 2003, Journal of Personality and Social Psychology 84(4) 890-904.
  SELECT count(*)::int,
         count(*) FILTER (WHERE r.is_correct IS NOT TRUE)::int
  INTO v_bogus_total, v_bogus_claimed
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
  WHERE r.candidate_id = p_candidate_id
    AND r.sitting = p_sitting
    AND i.stint = 1 AND i.is_active = true
    AND i.is_nonsense = true;

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
  -- use the hiregauge_role_ideal_ranges floors here — those sit on a composite
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

  -- Order matters. First failure wins.
  IF v_bogus_total > 0 AND v_bogus_claimed >= 2 THEN
    v_gate := 'gate_a_honest_answering';
    v_reason := format('Claimed to know %s of %s made-up words.', v_bogus_claimed, v_bogus_total);
  ELSIF v_rating_timed > 0 AND v_median_secs IS NOT NULL AND v_median_secs < 2 THEN
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
    'checks', jsonb_build_object(
      'bogus_words_claimed', v_bogus_claimed,
      'bogus_words_total', v_bogus_total,
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
$fn$;

-- ---------------------------------------------------------------------------
-- Applier. Evaluates, and if a gate fired: records it on the candidate row,
-- raises an alert, and sends the owner a Telegram message. Every response
-- already collected is kept — a gated candidate still has a scorable honesty
-- and reasoning profile.
--
-- The candidate is never told which gate fired or why. Saying so coaches the
-- test and creates exposure.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_hiregauge_v2_stint1_exit_gate(
  p_candidate_id uuid,
  p_sitting integer DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_enabled   text;
  v_agency    uuid;
  v_existing  text;
  v_verdict   jsonb;
  v_gate      text;
  v_reason    text;
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

  IF v_gate IS NULL THEN
    RETURN v_verdict || jsonb_build_object('wrote', false);
  END IF;

  UPDATE public.hiring_candidates
  SET assessment_exit_gate = v_gate,
      assessment_exit_detail = v_verdict,
      assessment_exited_at = now(),
      updated_at = now()
  WHERE id = p_candidate_id;

  v_link := 'https://newtworks.vercel.app/?module=team&candidate=' || p_candidate_id::text;

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

  RETURN v_verdict || jsonb_build_object('wrote', true, 'dm_error', v_dm_err);
END;
$fn$;

