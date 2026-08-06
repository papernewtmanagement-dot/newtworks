-- Widen response_format check constraint to allow 'vocab_familiarity'
-- alongside the existing 'free_text' and NULL. See migration body below for
-- full rationale.
ALTER TABLE public.hiregauge_instrument_items
  DROP CONSTRAINT hiregauge_instrument_items_response_format_check;

ALTER TABLE public.hiregauge_instrument_items
  ADD CONSTRAINT hiregauge_instrument_items_response_format_check
  CHECK (response_format IS NULL OR response_format IN ('free_text', 'vocab_familiarity'));

-- Convert the 20-item vocabulary block (4 fake + 16 real, 8 active at
-- stint 1, 12 inactive at stint 2) from forced-choice-with-definitions to a
-- Paulhus-style familiarity rating. Peter directive 2026-08-06.
--
-- OLD FORMAT: "What does the word X mean?" + 4 plausible definitions +
-- "None of these", scored right/wrong. This is the format that produced the
-- false positive on candidate Cook-Torres (see op-rule "Made-up-word check
-- is a FLAG, never an eliminator") -- guessing among plausible definitions
-- looks identical to over-claiming, and two of the four fake items were
-- solvable from word roots (prontivate ~ pro-, oblindous ~ blind), which
-- rewards the same reasoning the GMA verbal subtest is built to reward.
--
-- NEW FORMAT: "How well do you know the word X?" rated 1-5, condensed from
-- the OCQ's own published 7-point "never heard of it" to "know it very
-- well" scale (Paulhus, Harms, Bruce & Lysy 2003, JPSP 84(4) 890-904).
-- There is no right answer to guess toward and no definition to reason out
-- from a root -- a genuinely unknown word has exactly one honest response,
-- "never heard of it," so the item stops rewarding verbal inference instead
-- of measuring self-enhancement.
--
-- choices/answer_key set NULL -- these items are no longer scored right or
-- wrong; is_correct will be NULL on every future response to them, which is
-- correct and expected (the v1-assessment save path already handles a NULL
-- answer_key without incident).

UPDATE public.hiregauge_instrument_items
SET item_text = regexp_replace(item_text, '^What does the word "(.+)" mean\?$', 'How well do you know the word "\1"?'),
    choices = NULL,
    answer_key = NULL,
    scale_max = 5,
    response_format = 'vocab_familiarity',
    notes = notes || ' | Converted to Paulhus-style familiarity rating 2026-08-06 (5-pt condensed from OCQ 7-pt scale; MC answer_key retired).',
    updated_at = now()
WHERE item_text ILIKE 'What does the word%';

-- --------------------------------------------------------------------------
-- Rewrite the stint-1 exit gate's vocabulary flag to read the new rating
-- format: mean familiarity across the fake words vs. mean familiarity
-- across the real words, both always reported, never gating exit. No hard
-- cutoff is treated as validated -- there is zero response data on this
-- format yet, so the flag threshold below is explicitly provisional and
-- generous, per Ones, Viswesvaran & Schmidt 1993's warning against hard cut
-- scores without local validation (already the standard this codebase holds
-- itself to on gate B, integrity).
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

  -- GATE A2: median time per rating-scale item under 2 seconds.
  -- Existing Newtworks standard; consistent with Huang, Curran, Keeney,
  -- Poposki & DeShon 2012, Journal of Business and Psychology 27(1) 99-114.
  -- Vocabulary familiarity items are themselves rating-scale items now, so
  -- this timing check naturally covers them too -- no change needed here.
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

  -- Order matters. First failure wins. Vocabulary familiarity is NOT in this
  -- chain -- it is a flag only. Do not re-add it without new direction from
  -- Peter; see op-rule "Made-up-word check is a FLAG, never an eliminator".
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

-- --------------------------------------------------------------------------
-- hiregauge_v2_careless_bogus_items feeds the separate reliability composite
-- (hiring_candidates.reliability, informational only, never a decline
-- reason on its own). It read is_correct on is_nonsense items, which is now
-- always NULL for vocab_familiarity items since there is no answer_key to
-- score against. Switched to the same familiarity-mean logic as the exit
-- gate's flag, with a higher (more conservative) threshold since this one
-- silently degrades a composite label rather than raising a visible flag.
CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_bogus_items(p_candidate_id uuid)
 RETURNS TABLE(fired boolean, detail text)
 LANGUAGE sql
 STABLE
AS $function$
  WITH agg AS (
    SELECT count(*)::int AS n_total,
           AVG(r.response_value::numeric) AS mean_familiarity
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v2_personality'
      AND i.is_nonsense = true
      AND i.response_format = 'vocab_familiarity'
  )
  SELECT
    (n_total > 0 AND mean_familiarity IS NOT NULL AND mean_familiarity >= 3.0) AS fired,
    format('Mean familiarity rating on %s made-up words: %s of 5', n_total, round(mean_familiarity, 2)) AS detail
  FROM agg;
$function$;
