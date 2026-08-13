-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-04 21:45:39 UTC (ledger name: fix_v2_reliability_moderate_word_2026_08_04) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260804214539.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- hiregauge_v2_reliability_composite returned the word 'medium' when exactly two
-- careless-response checks fired. hiring_candidates.reliability only accepts
-- 'low' | 'moderate' | 'high', so that write threw a check-constraint violation
-- for exactly those candidates, and the caller swallows the error silently.
-- 'moderate' is the correct word, not a widened constraint: every existing
-- consumer already expects it. _assessment_reliability_confidence maps
-- 'moderate' -> 0.85; an accepted-but-unknown 'medium' would fall through to
-- the 0.9 fallback and silently apply the wrong multiplier.
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
    'fired_count',            v_fired_count,
    'computed_at',            now()
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
