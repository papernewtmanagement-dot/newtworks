-- Peter 2026-09-11 (late): autopay $2.50 per policy (two-policy household lands on the old $5), scorecard average
-- treats x as a zero, marketing sources: Other retired (history -> Social media), State-to-State / Event / Campaign
-- relabeled, HH Quotes count distinct households per person per week.

-- 1. Autopay per policy at $2.50.
UPDATE public.retention_point_values SET points = 2.50, updated_at = now() WHERE activity_key = 'autopay_enrollment';
UPDATE public.manuals SET content = replace(content, '| Autopay enrollment | $5 |', '| Autopay enrollment (per policy) | $2.50 |'), updated_at = now()
WHERE title = 'Retention Points' AND manual_type = 'handbook' AND content LIKE '%| Autopay enrollment | $5 |%';

-- 2. Scorecard average: x (0) counts as a zero in the average.
ALTER TABLE public.fit_scorecards DROP COLUMN IF EXISTS average_score;
ALTER TABLE public.fit_scorecards ADD COLUMN average_score numeric GENERATED ALWAYS AS (
  CASE WHEN
    ((demeanor_score IS NOT NULL)::int + (frogs_score IS NOT NULL)::int + (intro_score IS NOT NULL)::int + (eligibility_score IS NOT NULL)::int
     + (setup_gnc_score IS NOT NULL)::int + (uncover_gap_score IS NOT NULL)::int + (bridge_gap_score IS NOT NULL)::int
     + (customize_close_score IS NOT NULL)::int + (set_followup_score IS NOT NULL)::int + (review_referral_score IS NOT NULL)::int) > 0
  THEN ROUND(
    (COALESCE(demeanor_score, 0) + COALESCE(frogs_score, 0) + COALESCE(intro_score, 0) + COALESCE(eligibility_score, 0) + COALESCE(setup_gnc_score, 0)
     + COALESCE(uncover_gap_score, 0) + COALESCE(bridge_gap_score, 0) + COALESCE(customize_close_score, 0) + COALESCE(set_followup_score, 0) + COALESCE(review_referral_score, 0))::numeric
    /
    ((demeanor_score IS NOT NULL)::int + (frogs_score IS NOT NULL)::int + (intro_score IS NOT NULL)::int + (eligibility_score IS NOT NULL)::int
     + (setup_gnc_score IS NOT NULL)::int + (uncover_gap_score IS NOT NULL)::int + (bridge_gap_score IS NOT NULL)::int
     + (customize_close_score IS NOT NULL)::int + (set_followup_score IS NOT NULL)::int + (review_referral_score IS NOT NULL)::int)::numeric, 2)
  ELSE NULL END) STORED;

-- 3. Marketing sources.
UPDATE public.sales_marketing_sources SET is_active = false WHERE source_key = 'other';
UPDATE public.sales_log SET marketing_source = 'social_media' WHERE marketing_source = 'other';
UPDATE public.quote_log SET marketing_source = 'social_media' WHERE marketing_source = 'other';
UPDATE public.sales_marketing_sources SET label = 'State-to-State' WHERE source_key = 'state_to_state';
UPDATE public.sales_marketing_sources SET label = 'Event' WHERE source_key = 'community_event';
UPDATE public.sales_marketing_sources SET label = 'Campaign' WHERE source_key = 'corporate_marketing';

-- 4. HH Quotes = distinct households per person per week (a household quoted twice in a week counts once).
DO $$
DECLARE d text; o1 text; n1 text;
BEGIN
  d := pg_get_functiondef('public.rp_week_scoreboard_for'::regproc);
  o1 := 'SELECT tm, count(*)::int AS n,';
  n1 := 'SELECT tm, count(DISTINCT customer_label)::int AS n,';
  IF position(o1 in d) = 0 THEN RAISE EXCEPTION 'rp_week_scoreboard_for patch anchor not found'; END IF;
  EXECUTE replace(d, o1, n1);
END $$;
