-- Response-speed is downgraded from a hard eliminator to a non-blocking
-- flag, same tier as the vocabulary-overclaiming check. Peter directive
-- 2026-08-16, after Alvi's second test sitting tripped gate_a_honest_answering
-- purely on median rating-item time (1.51s across 28 items) with every other
-- signal clean (reasoning 14/16, integrity composite 53/100, longest
-- identical run only 4, fake-word familiarity honestly rated at 1/5).
--
-- Rationale: unlike the three remaining hard eliminators -- straight-lining
-- (a run of 10+ identical answers INCLUDING a reverse-worded item, which is
-- structurally self-contradictory for anyone actually reading each item),
-- the honesty-content score itself (direct measure, not an inference), and
-- reasoning at or below chance (unambiguous) -- speed alone is an inference
-- about WHY someone answered fast, not proof of anything. A 1-5 agree/
-- disagree item is genuinely quick to answer once you know how you feel;
-- a fast, decisive, honest reader can trip a 2-second median by accident.
-- Speed is not brought back as a conditional/compound eliminator (paired
-- with other signals) -- Peter's direction was to make it a pure flag,
-- full stop, matching the existing non-blocking treatment already used for
-- vocabulary-overclaiming (see op-rule "Made-up-word check is a FLAG,
-- never an eliminator").
--
-- The other three hard eliminators (straight-lining, integrity composite,
-- reasoning-at-chance) are UNCHANGED -- all direct, hard-to-fake evidence,
-- not proxies. gate_a_honest_answering is now fired by straight-lining
-- only; this is the first and only candidate this gate has ever fired on,
-- and it fired on the now-removed speed branch, so there is no historical
-- data whose meaning this migration disturbs.
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
      'reasoning_total', v_gma_total
    ),
    'evaluated_at', now()
  );
END;
$function$;
