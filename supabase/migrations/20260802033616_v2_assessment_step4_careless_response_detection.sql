-- v2 assessment Step 4 — careless-response / reliability detection.
-- Consolidated mirror of 8 migrations applied via Supabase MCP in one session:
--   * hiregauge_v2_reliability_detail_column      (hiring_candidates.reliability_detail jsonb)
--   * hiregauge_v2_careless_response_time_fast
--   * hiregauge_v2_careless_disengagement_slow
--   * hiregauge_v2_careless_straightlining
--   * hiregauge_v2_careless_retest_divergence
--   * hiregauge_v2_careless_evenodd_consistency
--   * hiregauge_v2_careless_bogus_items
--   * hiregauge_v2_reliability_composite + apply_newtworks_v2_reliability_to_candidate
-- Six independent methods (a-f), each returning (fired boolean, detail text),
-- combined by the composite into a three-band verdict: 0-1 fires = high,
-- 2 fires = medium, 3+ fires = low. Stored on hiring_candidates.reliability +
-- reliability_detail (JSONB, one entry per method, auditable). Wired into
-- v1-assessment's handleFinalizeV2 (repo commit 5980d9a) so it runs on every
-- v2 candidate finalize.

ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS reliability_detail jsonb;

-- ─────────────────────────────────────────────────────────────────────────────
-- (a) Too-fast responding. Huang, Curran, Keeney, Poposki & DeShon (2012,
-- J. Business & Psychology) index insufficient-effort responding via
-- per-item response time below a floor consistent with actually reading the
-- item (2 seconds/item is their commonly-cited screening threshold). Fired
-- when more than 10% of a candidate's v2 personality items were answered in
-- under 2 seconds.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_response_time_fast(p_candidate_id uuid)
 RETURNS TABLE(fired boolean, detail text)
 LANGUAGE sql
 STABLE
AS $function$
  WITH resp AS (
    SELECT r.item_id,
           EXTRACT(EPOCH FROM (r.answered_at - r.served_at))::numeric AS secs
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v2_personality'
      AND r.served_at IS NOT NULL
      AND r.answered_at IS NOT NULL
  ),
  agg AS (
    SELECT count(*)::int AS n_total,
           count(*) FILTER (WHERE secs < 2)::int AS n_fast
    FROM resp
  )
  SELECT
    (n_total > 0 AND n_fast::numeric / n_total > 0.10) AS fired,
    format('%s of %s items answered in under 2s (%.1f%%)',
           n_fast, n_total,
           CASE WHEN n_total > 0 THEN 100.0 * n_fast / n_total ELSE 0 END) AS detail
  FROM agg;
$function$
;

-- ─────────────────────────────────────────────────────────────────────────────
-- (b) Disengagement / walked-away outliers. Meade & Craig (2012,
-- Psychological Methods) flag extreme response-time outliers as evidence a
-- respondent stepped away mid-item rather than answering carelessly-fast.
-- 180 seconds (3 minutes) on a single self-report Likert item is far beyond
-- any plausible read-and-answer time and is used here as the outlier floor.
-- Fired when any item exceeds that floor, or when 2+ items exceed 90s.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_disengagement_slow(p_candidate_id uuid)
 RETURNS TABLE(fired boolean, detail text)
 LANGUAGE sql
 STABLE
AS $function$
  WITH resp AS (
    SELECT r.item_id,
           EXTRACT(EPOCH FROM (r.answered_at - r.served_at))::numeric AS secs
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v2_personality'
      AND r.served_at IS NOT NULL
      AND r.answered_at IS NOT NULL
  ),
  agg AS (
    SELECT count(*) FILTER (WHERE secs > 180)::int AS n_extreme,
           count(*) FILTER (WHERE secs > 90)::int AS n_moderate,
           max(secs) AS max_secs
    FROM resp
  )
  SELECT
    (n_extreme >= 1 OR n_moderate >= 2) AS fired,
    format('%s item(s) over 180s, %s item(s) over 90s, longest %.0fs',
           n_extreme, n_moderate, COALESCE(max_secs, 0)) AS detail
  FROM agg;
$function$
;

-- ─────────────────────────────────────────────────────────────────────────────
-- (c) Straightlining / long-string index. Johnson (2005) and Huang, Curran,
-- Keeney, Poposki & DeShon (2012) use the longest unbroken run of identical
-- response values ("long string") as a careless-responding signal; Huang et
-- al. use a threshold around 10 consecutive identical responses. Computed on
-- RAW response_value (not reverse-coded) since straightlining is about
-- literal answer repetition, not adjusted trait direction. Ordered by
-- served_at (actual served order for this candidate), not item_number.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_straightlining(p_candidate_id uuid)
 RETURNS TABLE(fired boolean, detail text)
 LANGUAGE sql
 STABLE
AS $function$
  WITH ordered AS (
    SELECT r.response_value,
           r.served_at,
           ROW_NUMBER() OVER (ORDER BY r.served_at) AS pos
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v2_personality'
      AND r.response_value IS NOT NULL
      AND r.served_at IS NOT NULL
  ),
  grp AS (
    SELECT response_value, pos,
           pos - ROW_NUMBER() OVER (PARTITION BY response_value ORDER BY pos) AS grp_key
    FROM ordered
  ),
  runs AS (
    SELECT response_value, count(*)::int AS run_length
    FROM grp
    GROUP BY response_value, grp_key
  ),
  agg AS (
    SELECT COALESCE(max(run_length), 0) AS longest_run
    FROM runs
  )
  SELECT
    (longest_run >= 10) AS fired,
    format('longest identical-response run: %s items', longest_run) AS detail
  FROM agg;
$function$
;

-- ─────────────────────────────────────────────────────────────────────────────
-- (d) Retest divergence. Meade & Craig (2012) use within-sitting retest
-- pairs to check answer consistency — the same candidate answering the same
-- statement twice, spaced apart per the constrained-shuffle retest gap.
-- Divergence is measured on RAW response_value (both items share the exact
-- same text and scale_max, so no reverse-coding adjustment needed). Fired
-- when any pair's divergence exceeds half the item's scale range, or when
-- mean divergence across all pairs exceeds 30% of scale range.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_retest_divergence(p_candidate_id uuid)
 RETURNS TABLE(fired boolean, detail text)
 LANGUAGE sql
 STABLE
AS $function$
  WITH pairs AS (
    SELECT orig_i.item_number AS orig_number,
           retest_i.item_number AS retest_number,
           retest_i.scale_max,
           abs(orig_r.response_value - retest_r.response_value)::numeric AS divergence
    FROM public.hiregauge_instrument_items retest_i
    JOIN public.hiregauge_instrument_items orig_i
      ON orig_i.item_number = retest_i.retest_of_item_number
     AND orig_i.section = retest_i.section
    JOIN public.hiregauge_candidate_responses retest_r
      ON retest_r.item_id = retest_i.id AND retest_r.candidate_id = p_candidate_id
    JOIN public.hiregauge_candidate_responses orig_r
      ON orig_r.item_id = orig_i.id AND orig_r.candidate_id = p_candidate_id
    WHERE retest_i.section = 'newtworks_v2_personality'
      AND retest_i.retest_of_item_number IS NOT NULL
      AND orig_r.response_value IS NOT NULL
      AND retest_r.response_value IS NOT NULL
  ),
  normed AS (
    SELECT divergence, scale_max,
           CASE WHEN scale_max > 1 THEN divergence / (scale_max - 1) ELSE 0 END AS pct_divergence
    FROM pairs
  ),
  agg AS (
    SELECT count(*)::int AS n_pairs,
           max(pct_divergence) AS max_pct,
           avg(pct_divergence) AS mean_pct
    FROM normed
  )
  SELECT
    (n_pairs > 0 AND (max_pct >= 0.50 OR mean_pct >= 0.30)) AS fired,
    format('%s retest pair(s), max divergence %.0f%% of scale, mean %.0f%% of scale',
           COALESCE(n_pairs, 0), COALESCE(max_pct, 0) * 100, COALESCE(mean_pct, 0) * 100) AS detail
  FROM agg;
$function$
;

-- ─────────────────────────────────────────────────────────────────────────────
-- (e) Even-odd consistency. Meade & Craig (2012) individual-reliability
-- index: within one respondent, split each facet's items into odd/even
-- positions, take the mean of each half, then correlate the odd-half means
-- against the even-half means ACROSS facets for that one person. A careless
-- respondent shows no consistent relationship between their own odd- and
-- even-item averages across traits; an attentive one does. Computable at
-- N=1 candidate (correlates across traits, not across candidates) — same
-- within-person design as compute_newtworks_v1_reliability_per_candidate.
-- Requires at least 5 facets with >=4 answered baseline items to be
-- statistically meaningful; returns fired=false with a skip note below that.
-- Excludes retest items (already covered by method d) and non-facet items
-- (IM/vocab, hypothesized_trait IS NULL).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_evenodd_consistency(p_candidate_id uuid)
 RETURNS TABLE(fired boolean, detail text)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_n_traits int;
  v_corr numeric;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _eo_resp ON COMMIT DROP AS
  WITH resp AS (
    SELECT i.hypothesized_trait AS the_trait,
           i.item_number,
           CASE WHEN i.reverse_coded THEN (i.scale_max + 1) - r.response_value
                ELSE r.response_value END AS adj
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v2_personality'
      AND i.hypothesized_trait IS NOT NULL
      AND i.retest_of_item_number IS NULL
      AND r.response_value IS NOT NULL
  ),
  ranked AS (
    SELECT the_trait, adj,
           ROW_NUMBER() OVER (PARTITION BY the_trait ORDER BY item_number) AS pos
    FROM resp
  )
  SELECT the_trait,
         avg(adj) FILTER (WHERE pos % 2 = 1) AS odd_mean,
         avg(adj) FILTER (WHERE pos % 2 = 0) AS even_mean,
         count(*) AS n_items
  FROM ranked
  GROUP BY the_trait
  HAVING count(*) >= 4;

  SELECT count(*) INTO v_n_traits FROM _eo_resp WHERE odd_mean IS NOT NULL AND even_mean IS NOT NULL;

  IF v_n_traits < 5 THEN
    RETURN QUERY SELECT false, format('skipped — only %s facet(s) with >=4 items answered, need 5', v_n_traits);
    RETURN;
  END IF;

  SELECT corr(odd_mean, even_mean) INTO v_corr FROM _eo_resp;

  RETURN QUERY SELECT
    (v_corr IS NOT NULL AND v_corr < 0.30) AS fired,
    format('odd/even facet-mean correlation across %s facets: %s',
           v_n_traits, COALESCE(round(v_corr, 2)::text, 'undefined (zero variance)'));
END;
$function$
;

-- ─────────────────────────────────────────────────────────────────────────────
-- (f) Bogus/over-claiming items. Paulhus (2003) over-claiming technique:
-- invented-word "vocabulary" items with a known-correct answer ("None of
-- these") — a candidate claiming knowledge of a nonexistent word is either
-- careless or overclaiming. Fired when a candidate misses 50%+ of the served
-- bogus items. is_correct is already computed at save time (edge fn compares
-- response_label to answer_key), so this reads that.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_bogus_items(p_candidate_id uuid)
 RETURNS TABLE(fired boolean, detail text)
 LANGUAGE sql
 STABLE
AS $function$
  WITH resp AS (
    SELECT r.is_correct
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v2_personality'
      AND i.is_nonsense = true
  ),
  agg AS (
    SELECT count(*)::int AS n_total,
           count(*) FILTER (WHERE is_correct = false)::int AS n_wrong
    FROM resp
  )
  SELECT
    (n_total > 0 AND n_wrong::numeric / n_total >= 0.50) AS fired,
    format('%s of %s bogus/over-claiming items missed', n_wrong, n_total) AS detail
  FROM agg;
$function$
;

-- ─────────────────────────────────────────────────────────────────────────────
-- Master composite. Runs all six methods (a-f) and combines the flag count
-- into a three-band verdict: 0-1 fires = high, 2 fires = medium, 3+ fires =
-- low. reliability_detail is a JSONB object with each method's fired flag +
-- diagnostic detail string, so a low/medium verdict is auditable rather than
-- a bare label.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.hiregauge_v2_reliability_composite(p_candidate_id uuid)
 RETURNS TABLE(reliability text, fired_count integer, reliability_detail jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  r_fast RECORD;
  r_slow RECORD;
  r_straight RECORD;
  r_retest RECORD;
  r_evenodd RECORD;
  r_bogus RECORD;
  v_fired_count int;
  v_detail jsonb;
BEGIN
  SELECT * INTO r_fast FROM public.hiregauge_v2_careless_response_time_fast(p_candidate_id);
  SELECT * INTO r_slow FROM public.hiregauge_v2_careless_disengagement_slow(p_candidate_id);
  SELECT * INTO r_straight FROM public.hiregauge_v2_careless_straightlining(p_candidate_id);
  SELECT * INTO r_retest FROM public.hiregauge_v2_careless_retest_divergence(p_candidate_id);
  SELECT * INTO r_evenodd FROM public.hiregauge_v2_careless_evenodd_consistency(p_candidate_id);
  SELECT * INTO r_bogus FROM public.hiregauge_v2_careless_bogus_items(p_candidate_id);

  v_fired_count :=
    (r_fast.fired)::int + (r_slow.fired)::int + (r_straight.fired)::int +
    (r_retest.fired)::int + (r_evenodd.fired)::int + (r_bogus.fired)::int;

  v_detail := jsonb_build_object(
    'response_time_fast',     jsonb_build_object('fired', r_fast.fired,     'detail', r_fast.detail),
    'disengagement_slow',     jsonb_build_object('fired', r_slow.fired,     'detail', r_slow.detail),
    'straightlining',         jsonb_build_object('fired', r_straight.fired, 'detail', r_straight.detail),
    'retest_divergence',      jsonb_build_object('fired', r_retest.fired,   'detail', r_retest.detail),
    'evenodd_consistency',    jsonb_build_object('fired', r_evenodd.fired,  'detail', r_evenodd.detail),
    'bogus_items',            jsonb_build_object('fired', r_bogus.fired,    'detail', r_bogus.detail),
    'computed_at',            now()
  );

  RETURN QUERY SELECT
    CASE
      WHEN v_fired_count <= 1 THEN 'high'
      WHEN v_fired_count = 2 THEN 'medium'
      ELSE 'low'
    END,
    v_fired_count,
    v_detail;
END;
$function$
;

-- Write-back wrapper, mirrors apply_newtworks_v1_lss_to_candidate's pattern:
-- computes the composite and stamps it onto the candidate row. Called from
-- v1-assessment's handleFinalizeV2 on completion, same as v1's finalize path.
CREATE OR REPLACE FUNCTION public.apply_newtworks_v2_reliability_to_candidate(p_candidate_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_row RECORD;
BEGIN
  SELECT * INTO v_row FROM public.hiregauge_v2_reliability_composite(p_candidate_id);

  UPDATE public.hiring_candidates
  SET reliability = v_row.reliability,
      reliability_detail = v_row.reliability_detail
  WHERE id = p_candidate_id;
END;
$function$
;
