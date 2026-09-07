-- SELLING-JUDGEMENT SECTION, PILOT v1 (2026-09-07)
-- Rebuild of the situational section around SELLING judgement. The earlier
-- section (procedures, single best answer) was cut 2026-08-26 because everyone
-- passed it. This one: 16 scenarios keyed most/least by Peter as subject-matter
-- expert over a literature first pass (hybrid key, Bergman et al. 2006),
-- staged in hiregauge_sjt_draft_items and promoted here.
--
--   * section newtworks_v2_sjt, STINT 3 (served after the personality blocks,
--     before the written screen). Not stint 1: the exit gate counts stint-1
--     items and pilot statistics should come from people who cleared it.
--   * response_format sjt_most_least: two answers per item (most likely /
--     least likely), stored as a 2-letter response_label "<most><least>" in
--     canonical letters; answer_key holds "<key_most><key_least>".
--     Most/least scoring is more reliable than single-best (Ployhart & Ehrhart
--     2003); behavioural-tendency wording "would you" (McDaniel, Hartman,
--     Whetzel & Grubb 2007).
--   * score = matches / (2 x scored items) x 100, 0-100. +1 key_most match,
--     +1 key_least match. Recomputed from the CURRENT keys and CURRENT active
--     items every time the scorer runs, so a re-key or a retirement rescores
--     everyone by re-running apply_newtworks_v2_sjt_to_candidate.
--   * PILOT: no 'sjt' weight rows and no 'sjt' norm row. _newtworks_role_fit_core
--     then reads weight 0 and percentile NULL, so the section changes nobody's
--     composite. Weight and norm are set only after N >= 20 real sittings and
--     item review (retire p > .85 on either answer). The trigger below raises
--     alert 'assessment_sjt_pilot_ready' once at N = 20.
--   * Interview trigger T_SJT_LOW becomes norm-referenced (bottom quartile) so it
--     stays silent until the norm exists; the old raw < 50 was fitted to the
--     deleted procedural test.

-- 1. constraints: section and response format
ALTER TABLE public.hiregauge_instrument_items DROP CONSTRAINT IF EXISTS hiregauge_instrument_items_section_check;
ALTER TABLE public.hiregauge_instrument_items ADD CONSTRAINT hiregauge_instrument_items_section_check
  CHECK (section = ANY (ARRAY['instructions'::text,'vct'::text,'cognitive'::text,'cts'::text,
    'newtworks_v1_personality'::text,'newtworks_v1_impression_mgmt'::text,'newtworks_v1_vct'::text,
    'newtworks_v2_personality'::text,'newtworks_v2_cognitive_gma'::text,'newtworks_v2_impression_mgmt'::text,
    'newtworks_v2_vct'::text,'newtworks_v2_screen'::text,'newtworks_v2_personality_fc_quad'::text,
    'newtworks_v2_sjt'::text]));

ALTER TABLE public.hiregauge_instrument_items DROP CONSTRAINT IF EXISTS hiregauge_instrument_items_response_format_check;
ALTER TABLE public.hiregauge_instrument_items ADD CONSTRAINT hiregauge_instrument_items_response_format_check
  CHECK (response_format IS NULL OR response_format = ANY (ARRAY['free_text'::text,'vocab_familiarity'::text,'forced_choice_quad'::text,'sjt_most_least'::text]));

-- 2. promote the 16 keyed drafts. item_number 801-816 (draft number + 800) so
--    they collide with nothing. hypothesized_trait = display theme only (feeds
--    sjt_topic_detail); the score is the single composite.
INSERT INTO public.hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, is_nonsense, hypothesized_trait, reverse_coded,
   notes, stint, is_active, response_format, score_excluded)
SELECT
  'newtworks_v2_sjt',
  d.item_number + 800,
  d.situation,
  jsonb_build_object('options', d.options, 'title', d.title,
    'theme', CASE d.item_number
      WHEN 1 THEN 'sjt_discovery' WHEN 2 THEN 'sjt_first_no' WHEN 3 THEN 'sjt_price_objection'
      WHEN 4 THEN 'sjt_walking_away' WHEN 5 THEN 'sjt_referrals' WHEN 6 THEN 'sjt_discovery'
      WHEN 7 THEN 'sjt_follow_up' WHEN 8 THEN 'sjt_cross_sell' WHEN 9 THEN 'sjt_price_objection'
      WHEN 10 THEN 'sjt_cross_sell' WHEN 11 THEN 'sjt_first_no' WHEN 12 THEN 'sjt_integrity'
      WHEN 13 THEN 'sjt_integrity' WHEN 14 THEN 'sjt_prioritization' WHEN 15 THEN 'sjt_integrity'
      WHEN 16 THEN 'sjt_price_objection' END),
  d.key_most || d.key_least,
  false,
  CASE d.item_number
      WHEN 1 THEN 'sjt_discovery' WHEN 2 THEN 'sjt_first_no' WHEN 3 THEN 'sjt_price_objection'
      WHEN 4 THEN 'sjt_walking_away' WHEN 5 THEN 'sjt_referrals' WHEN 6 THEN 'sjt_discovery'
      WHEN 7 THEN 'sjt_follow_up' WHEN 8 THEN 'sjt_cross_sell' WHEN 9 THEN 'sjt_price_objection'
      WHEN 10 THEN 'sjt_cross_sell' WHEN 11 THEN 'sjt_first_no' WHEN 12 THEN 'sjt_integrity'
      WHEN 13 THEN 'sjt_integrity' WHEN 14 THEN 'sjt_prioritization' WHEN 15 THEN 'sjt_integrity'
      WHEN 16 THEN 'sjt_price_objection' END,
  false,
  'Selling-judgement pilot v1 (2026-09-07). Source hiregauge_sjt_draft_items #' || d.item_number
    || ' (' || d.title || '). Keyed by Peter (hybrid key over literature first pass). Key rationale: ' || COALESCE(d.key_rationale, ''),
  3, true, 'sjt_most_least', false
FROM public.hiregauge_sjt_draft_items d
WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.status = 'keyed'
  AND d.key_most IS NOT NULL AND d.key_least IS NOT NULL AND d.key_most <> d.key_least
  AND NOT EXISTS (SELECT 1 FROM public.hiregauge_instrument_items x WHERE x.section = 'newtworks_v2_sjt' AND x.item_number = d.item_number + 800);

UPDATE public.hiregauge_sjt_draft_items
SET status = 'piloting',
    notes = COALESCE(notes || E'\n', '') || 'Promoted 2026-09-07 to hiregauge_instrument_items section newtworks_v2_sjt item ' || (item_number + 800) || ' (stint 3, weight 0 pilot).',
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND status = 'keyed';

-- 3. scorer
CREATE OR REPLACE FUNCTION public.apply_newtworks_v2_sjt_to_candidate(p_candidate_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
/*
model_tag: sjt_selling_judgement_v1_2026_09_07

Selling-judgement situational section scorer. Called at finalize (best-effort,
same pattern as apply_newtworks_gma_to_candidate) and by hand after any re-key
or item retirement, because it recomputes from the CURRENT keys of the CURRENT
active, scored items. It never reads hiregauge_candidate_responses.is_correct
or response_value -- those are written at save time as a convenience and go
stale the moment a key changes.

Format: response_label = '<most><least>' in canonical letters; answer_key =
'<key_most><key_least>'. +1 when the most letters match, +1 when the least
letters match (Ployhart & Ehrhart 2003, most/least is more reliable and less
fakeable than single-best; McDaniel, Hartman, Whetzel & Grubb 2007,
behavioural-tendency instructions). Score = matches / (2 x items) x 100.

Writes hiring_candidates.sjt_score (0-100, one decimal) and sjt_topic_detail
{theme: {n, correct, most_correct, least_correct, items}} where n is the
possible points (2 per item) and correct the points earned -- the shape
hiregauge_v2_normalized_inputs already reads. Themes are display groupings
only; nothing weights them.

PILOT: no sjt weight rows and no sjt norm row exist, so _newtworks_role_fit_core
treats the input as weight 0 / percentile NULL. Chance is 25% (each of the two
answers has a 1-in-4 chance), so raw percent is not a passing scale -- read it
only against the local norm once seeded.
*/
DECLARE
  v_agency uuid;
  v_items int := 0;
  v_most int := 0;
  v_least int := 0;
  v_score numeric;
  v_detail jsonb;
BEGIN
  SELECT agency_id INTO v_agency FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF v_agency IS NULL THEN
    RETURN jsonb_build_object('error', 'candidate_not_found', 'candidate_id', p_candidate_id);
  END IF;

  WITH scored AS (
    SELECT i.hypothesized_trait AS theme,
           (substr(r.response_label, 1, 1) = substr(i.answer_key, 1, 1))::int AS most_ok,
           (substr(r.response_label, 2, 1) = substr(i.answer_key, 2, 1))::int AS least_ok
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND r.sitting = 1
      AND i.section = 'newtworks_v2_sjt'
      AND i.is_active = true
      AND i.score_excluded = false
      AND i.answer_key IS NOT NULL AND length(i.answer_key) = 2
      AND r.response_label IS NOT NULL AND length(r.response_label) = 2
  )
  SELECT count(*)::int, COALESCE(sum(most_ok), 0)::int, COALESCE(sum(least_ok), 0)::int
    INTO v_items, v_most, v_least
  FROM scored;

  IF v_items = 0 THEN
    RETURN jsonb_build_object('candidate_id', p_candidate_id, 'wrote', false, 'reason', 'no_sjt_responses');
  END IF;

  WITH scored AS (
    SELECT i.hypothesized_trait AS theme,
           (substr(r.response_label, 1, 1) = substr(i.answer_key, 1, 1))::int AS most_ok,
           (substr(r.response_label, 2, 1) = substr(i.answer_key, 2, 1))::int AS least_ok
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND r.sitting = 1
      AND i.section = 'newtworks_v2_sjt'
      AND i.is_active = true
      AND i.score_excluded = false
      AND i.answer_key IS NOT NULL AND length(i.answer_key) = 2
      AND r.response_label IS NOT NULL AND length(r.response_label) = 2
  ), by_theme AS (
    SELECT COALESCE(theme, 'sjt_other') AS theme,
           count(*)::int AS items,
           sum(most_ok)::int AS most_correct,
           sum(least_ok)::int AS least_correct
    FROM scored GROUP BY 1
  )
  SELECT jsonb_object_agg(theme, jsonb_build_object(
           'n', items * 2, 'correct', most_correct + least_correct,
           'most_correct', most_correct, 'least_correct', least_correct, 'items', items))
    INTO v_detail
  FROM by_theme;

  v_score := ROUND(100.0 * (v_most + v_least) / (2.0 * v_items), 1);

  UPDATE public.hiring_candidates
  SET sjt_score = v_score,
      sjt_topic_detail = v_detail
  WHERE id = p_candidate_id;

  RETURN jsonb_build_object(
    'candidate_id', p_candidate_id, 'wrote', true,
    'items', v_items, 'most_correct', v_most, 'least_correct', v_least,
    'matches', v_most + v_least, 'possible', v_items * 2, 'sjt_score', v_score,
    'model_tag', 'sjt_selling_judgement_v1_2026_09_07');
END;
$function$;

-- 4. pilot item statistics (real candidates only). retire_flag = the handoff
--    rule: N >= 20 and p > .85 on either answer (no spread left to measure;
--    variance contribution p(1-p), Nunnally & Bernstein 1994 ch. 8).
CREATE OR REPLACE FUNCTION public.hiregauge_sjt_pilot_item_stats(p_agency uuid)
RETURNS TABLE(item_number int, title text, theme text, n int, p_most numeric, p_least numeric,
              most_picks jsonb, least_picks jsonb, retire_flag boolean)
LANGUAGE sql
STABLE
AS $function$
  WITH resp AS (
    SELECT i.item_number, i.choices->>'title' AS title, i.hypothesized_trait AS theme, i.answer_key,
           substr(r.response_label, 1, 1) AS most, substr(r.response_label, 2, 1) AS least
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    JOIN public.hiring_candidates c ON c.id = r.candidate_id
    WHERE c.agency_id = p_agency
      AND NOT COALESCE(c.is_test_candidate, false)
      AND i.section = 'newtworks_v2_sjt'
      AND r.sitting = 1
      AND r.response_label IS NOT NULL AND length(r.response_label) = 2
      AND i.answer_key IS NOT NULL AND length(i.answer_key) = 2
  )
  SELECT r1.item_number, r1.title, r1.theme, count(*)::int AS n,
         round(avg((r1.most = substr(r1.answer_key, 1, 1))::int), 3) AS p_most,
         round(avg((r1.least = substr(r1.answer_key, 2, 1))::int), 3) AS p_least,
         (SELECT jsonb_object_agg(k, v) FROM (SELECT r2.most AS k, count(*) AS v FROM resp r2 WHERE r2.item_number = r1.item_number GROUP BY 1) s) AS most_picks,
         (SELECT jsonb_object_agg(k, v) FROM (SELECT r3.least AS k, count(*) AS v FROM resp r3 WHERE r3.item_number = r1.item_number GROUP BY 1) s) AS least_picks,
         (count(*) >= 20 AND (avg((r1.most = substr(r1.answer_key, 1, 1))::int) > 0.85
                              OR avg((r1.least = substr(r1.answer_key, 2, 1))::int) > 0.85)) AS retire_flag
  FROM resp r1
  GROUP BY r1.item_number, r1.title, r1.theme, r1.answer_key
  ORDER BY r1.item_number;
$function$;

-- 5. one-shot pilot alert at N >= 20 real sittings. Never blocks the scoring write.
CREATE OR REPLACE FUNCTION public.hiregauge_sjt_pilot_check_trg()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  v_n int;
  v_min_n CONSTANT int := 20;
  v_flagged text;
  v_summary text;
BEGIN
  BEGIN
    IF EXISTS (SELECT 1 FROM public.alerts WHERE agency_id = NEW.agency_id AND alert_type = 'assessment_sjt_pilot_ready') THEN
      RETURN NEW;
    END IF;

    SELECT count(*)::int INTO v_n
    FROM public.hiring_candidates c
    WHERE c.agency_id = NEW.agency_id AND c.sjt_score IS NOT NULL AND NOT COALESCE(c.is_test_candidate, false);

    IF v_n < v_min_n THEN
      RETURN NEW;
    END IF;

    SELECT string_agg(format('#%s %s (most %.2f / least %.2f)', s.item_number - 800, s.title, s.p_most, s.p_least), '; ' ORDER BY s.item_number)
      INTO v_flagged
    FROM public.hiregauge_sjt_pilot_item_stats(NEW.agency_id) s
    WHERE s.retire_flag;

    SELECT string_agg(format('#%s %.2f/%.2f', s.item_number - 800, s.p_most, s.p_least), ', ' ORDER BY s.item_number)
      INTO v_summary
    FROM public.hiregauge_sjt_pilot_item_stats(NEW.agency_id) s;

    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved)
    VALUES (NEW.agency_id, 'assessment_sjt_pilot_ready', 'info',
            'Selling-judgement pilot has 20 sittings',
            format('%s real candidates have a selling-judgement score. Review the items, retire any flagged (p > .85 on either answer), re-run apply_newtworks_v2_sjt_to_candidate for everyone, then seed the sjt norm and set the sjt weight (2-3). Flagged: %s. Per item most/least: %s',
                   v_n, COALESCE(v_flagged, 'none'), COALESCE(v_summary, 'n/a')),
            'hiring', false, false);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved)
    VALUES (NEW.agency_id, 'assessment_sjt_pilot_check_failed', 'warning',
            'Selling-judgement pilot check failed',
            format('hiregauge_sjt_pilot_check_trg raised: %s', SQLERRM), 'hiring', false, false);
  END;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_sjt_pilot_check ON public.hiring_candidates;
CREATE TRIGGER trg_sjt_pilot_check
  AFTER UPDATE OF sjt_score ON public.hiring_candidates
  FOR EACH ROW
  WHEN (NEW.sjt_score IS NOT NULL AND OLD.sjt_score IS DISTINCT FROM NEW.sjt_score)
  EXECUTE FUNCTION public.hiregauge_sjt_pilot_check_trg();

-- 6. interview trigger T_SJT_LOW: raw < 50 was fitted to the deleted procedural
--    test; on a most/least test chance is 25%. Norm-referenced bottom quartile
--    instead; hiregauge_facet_percentile returns NULL until the sjt norm row
--    exists, so nothing fires during the pilot.
DO $do$
DECLARE
  v_def text;
  v_old CONSTANT text := 'IF v_row.sjt_score IS NOT NULL AND v_row.sjt_score < 50 THEN';
  v_new CONSTANT text := 'IF v_row.sjt_score IS NOT NULL AND public.hiregauge_facet_percentile(v_row.agency_id, ''sjt'', v_row.sjt_score) < 25 THEN';
BEGIN
  v_def := pg_get_functiondef('public.interview_candidate_triggers'::regproc);
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'T_SJT_LOW anchor not found in interview_candidate_triggers';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$do$;
