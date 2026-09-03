CREATE OR REPLACE FUNCTION public.hiregauge_v2_stint1_exit_gate(p_candidate_id uuid, p_sitting integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_expected      int;
  v_answered      int;
  v_fake_n        int;
  v_fake_avg      numeric;
  v_real_n        int;
  v_real_avg      numeric;
  v_median_secs   numeric;
  v_rating_timed  int;
  v_run_len       int;
  v_integrity     numeric;
  v_integrity_n   int;
  v_gma_correct   int;
  v_gma_total     int;
  v_gma_set       text;
  v_floor         jsonb;
  v_gate_c_max    int;
  v_gate          text := NULL;
  v_reason        text := NULL;
  v_flags         jsonb := '[]'::jsonb;
BEGIN
  -- 2026-09-02: GMA items are counted from the candidate's locked item set
  -- (hiregauge_gma_candidate_set), not from is_active. A candidate who
  -- started Section 1 on a since-retired set finishes on that set; counting
  -- only currently-active GMA items would report stint 1 as incomplete for
  -- them and skip every gate below (same failure shape as the 2026-08-14
  -- stint-2 cutover). Personality items keep the is_active filter.
  v_gma_set := public.hiregauge_gma_candidate_set(p_candidate_id);

  SELECT count(*)::int INTO v_expected
  FROM public.hiregauge_instrument_items i
  WHERE (i.stint = 1 AND i.is_active = true
         AND i.section IN ('newtworks_v2_personality','newtworks_v2_sjt'))
     OR i.id IN (SELECT m.item_id FROM public.hiregauge_gma_item_set_members m WHERE m.set_key = v_gma_set);

  SELECT count(*)::int INTO v_answered
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
  WHERE r.candidate_id = p_candidate_id
    AND r.sitting = p_sitting
    AND ((i.stint = 1 AND i.is_active = true
          AND i.section IN ('newtworks_v2_personality','newtworks_v2_sjt'))
      OR i.id IN (SELECT m.item_id FROM public.hiregauge_gma_item_set_members m WHERE m.set_key = v_gma_set));

  IF v_expected = 0 OR v_answered < v_expected THEN
    RETURN jsonb_build_object(
      'stint1_complete', false,
      'gate_fired', NULL,
      'flags', v_flags,
      'answered', v_answered,
      'expected', v_expected
    );
  END IF;

  -- FLAG (never a gate): mean familiarity rating (1-5) on the fabricated
  -- words vs. the real words in the same block. A genuinely unknown word has
  -- exactly one honest rating -- 1, "never heard of it" -- so any sustained
  -- elevation above that floor across all four fake words is worth an
  -- interview question. Both means always reported in 'checks' regardless
  -- of whether the flag threshold is met; the flag entry is the only
  -- threshold-gated part, and it is explicitly provisional.
  SELECT count(*)::int, AVG(r.response_value::numeric)
  INTO v_fake_n, v_fake_avg
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
  WHERE r.candidate_id = p_candidate_id
    AND r.sitting = p_sitting
    AND i.stint = 1 AND i.is_active = true
    AND i.is_nonsense = true
    AND i.response_format = 'vocab_familiarity';

  SELECT count(*)::int, AVG(r.response_value::numeric)
  INTO v_real_n, v_real_avg
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
  WHERE r.candidate_id = p_candidate_id
    AND r.sitting = p_sitting
    AND i.stint = 1 AND i.is_active = true
    AND i.is_nonsense = false
    AND i.response_format = 'vocab_familiarity';

  IF v_fake_n > 0 AND v_fake_avg IS NOT NULL AND v_fake_avg >= 2.5 THEN
    v_flags := v_flags || jsonb_build_object(
      'flag', 'vocabulary_overclaiming',
      'detail', format('Mean familiarity rating on %s made-up words was %s of 5 (real-word mean %s of 5, %s items). Interview probe only — not a decline reason, no local validation on this format yet.',
                       v_fake_n, round(v_fake_avg, 2),
                       CASE WHEN v_real_avg IS NULL THEN 'n/a' ELSE round(v_real_avg, 2)::text END,
                       v_real_n)
    );
  END IF;

  -- Median time per rating-scale item. Consistent with Huang, Curran,
  -- Keeney, Poposki & DeShon 2012, Journal of Business and Psychology
  -- 27(1) 99-114 as a carelessness SIGNAL. Downgraded to a non-blocking
  -- FLAG 2026-08-16 (was a hard eliminator, "gate_a_honest_answering",
  -- under 2 seconds median) -- speed is an inference about why someone
  -- answered fast, not direct evidence, and a fast honest reader can trip
  -- 2 seconds by accident. See migration
  -- fc_downgrade_response_speed_to_flag for the full incident writeup.
  -- Vocabulary familiarity items are themselves rating-scale items, so this
  -- timing check naturally covers them too -- no change needed here.
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

  IF v_rating_timed > 0 AND v_median_secs IS NOT NULL AND v_median_secs < 2 THEN
    v_flags := v_flags || jsonb_build_object(
      'flag', 'response_speed',
      'detail', format('Median time per rating item was %s seconds across %s items. Interview probe only — not a decline reason on its own; a fast, decisive reader can trip this without answering carelessly.',
                       round(v_median_secs, 2), v_rating_timed)
    );
  END IF;

  -- GATE A: same answer position on 10 or more consecutive rating-scale
  -- items, where at least one item in the run is reverse-worded (so agreeing
  -- straight down the column is self-contradictory). Structurally hard to
  -- trip honestly: a reverse-worded item forces a genuine reader's answer to
  -- flip, so surviving it with an identical value is direct evidence of not
  -- reading, not an inference. Long-string index: Meade & Craig 2012,
  -- Psychological Methods 17(3) 437-455.
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
  -- With three to six answer choices, random guessing yields about 3.3 correct
  -- out of 16. At or below that, the candidate either could not engage with the
  -- questions or was not trying. Anchored to chance, NOT to a percentile: these
  -- reasoning items are home-grown, have no published norms and no response
  -- data, so any percentile cutoff today would be invented. Explicitly do not
  -- use the hiregauge_role_ideal_ranges floors here -- those sit on a composite
  -- scale that cannot be computed for these items.
  -- 2026-09-02: the threshold is no longer a literal. hiregauge_gma_chance_floor
  -- derives the guessing mean from the real option counts of the candidate's
  -- item set (6-option pattern/numerical/verbal, 3-option deductive), so a
  -- future set change cannot silently widen or narrow this eliminator. The
  -- retired 2026-08 set is pinned to its ruled value by override.
  v_floor := public.hiregauge_gma_chance_floor(p_candidate_id);
  v_gate_c_max := COALESCE((v_floor->>'gate_c_max_correct')::int, 3);

  SELECT count(*) FILTER (WHERE r.is_correct IS TRUE)::int,
         count(*)::int
  INTO v_gma_correct, v_gma_total
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
  WHERE r.candidate_id = p_candidate_id
    AND r.sitting = p_sitting
    AND i.id IN (SELECT m.item_id FROM public.hiregauge_gma_item_set_members m WHERE m.set_key = v_gma_set);

  -- Order matters. First failure wins. Vocabulary familiarity and response
  -- speed are NOT in this chain -- flags only. Do not re-add speed as an
  -- eliminator (in any form, including a compound/conditional one) without
  -- new direction from Peter; see op-rule "Response speed is a FLAG, never
  -- an eliminator (2026-08-16)".
  IF v_run_len >= 10 THEN
    v_gate := 'gate_a_honest_answering';
    v_reason := format('Same answer position on %s consecutive rating items, including reverse-worded ones.', v_run_len);
  ELSIF v_integrity_n = 3 AND v_integrity IS NOT NULL AND v_integrity < 30 THEN
    v_gate := 'gate_b_integrity';
    v_reason := format('Honesty composite %s of 100 (sincerity, fairness, greed-avoidance equally weighted).',
                       round(v_integrity, 1));
  ELSIF v_gma_total > 0 AND v_gma_correct <= v_gate_c_max THEN
    v_gate := 'gate_c_reasoning';
    v_reason := format('%s of %s reasoning items correct, at or below the guessing baseline of about %s.',
                       v_gma_correct, v_gma_total, COALESCE(v_floor->>'chance_mean_items', '3.3'));
  END IF;

  RETURN jsonb_build_object(
    'stint1_complete', true,
    'gate_fired', v_gate,
    'reason', v_reason,
    'flags', v_flags,
    'checks', jsonb_build_object(
      'vocab_fake_words_rated', v_fake_n,
      'vocab_fake_familiarity_mean', v_fake_avg,
      'vocab_real_words_rated', v_real_n,
      'vocab_real_familiarity_mean', v_real_avg,
      'median_rating_seconds', v_median_secs,
      'rating_items_timed', v_rating_timed,
      'longest_identical_run_with_reverse', v_run_len,
      'integrity_composite', v_integrity,
      'integrity_facets_scored', v_integrity_n,
      'reasoning_correct', v_gma_correct,
      'reasoning_total', v_gma_total,
      'reasoning_item_set', v_gma_set,
      'reasoning_gate_c_max_correct', v_gate_c_max
    ),
    'evaluated_at', now()
  );
END;
$function$;
