-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-02 03:39:33 UTC (ledger name: fix_hiregauge_v2_careless_format_specifiers) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260802033933.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Bug fix: Postgres format() only supports %s/%I/%L, not printf-style %.1f/%.0f.
-- Caught via smoke-test call against a real candidate — original functions
-- threw "unrecognized format() type specifier" on first real invocation.
-- Same bug-class fix applied to all three functions that used decimal
-- format specifiers (response_time_fast, disengagement_slow,
-- retest_divergence), per bug-fix-sweep convention (same pattern, same
-- session). round(...)::text substituted for the printf specifiers.

CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_response_time_fast(
  p_candidate_id uuid
)
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
    format('%s of %s items answered in under 2s (%s%%)',
           n_fast, n_total,
           CASE WHEN n_total > 0 THEN round(100.0 * n_fast / n_total, 1)::text ELSE '0' END) AS detail
  FROM agg;
$function$;

CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_disengagement_slow(
  p_candidate_id uuid
)
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
    format('%s item(s) over 180s, %s item(s) over 90s, longest %ss',
           n_extreme, n_moderate, round(COALESCE(max_secs, 0), 0)::text) AS detail
  FROM agg;
$function$;

CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_retest_divergence(
  p_candidate_id uuid
)
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
    format('%s retest pair(s), max divergence %s%% of scale, mean %s%% of scale',
           COALESCE(n_pairs, 0),
           round(COALESCE(max_pct, 0) * 100, 0)::text,
           round(COALESCE(mean_pct, 0) * 100, 0)::text) AS detail
  FROM agg;
$function$;
