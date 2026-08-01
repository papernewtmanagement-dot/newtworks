-- Consolidates the CPR-week "did they complete their scorecarding" check into
-- one server-side function. Callers (CPRDetail.jsx auto-verify, and any future
-- consumer like a weekly digest email) call this instead of reimplementing
-- tier math, entry-type mapping, and threshold rules.
--
-- Uses the two canonical building blocks:
--   public.fit_scorecard_tenure_tier(team_id, as_of)        -- tier from hire_date
--   public.fit_scorecard_entry_type_for_tenure(tier)         -- tier -> required entry_type
--
-- Threshold rules (per handbook "Your Path" §Scorecarding Cadence):
--   weeks_1_8     -> GREATEST(quotes_discussed, working_days_elapsed)
--   weeks_9_13    -> quotes_discussed
--   weeks_14_plus -> working_days_elapsed (Mon-Fri, max 5)
--
-- working_days_elapsed scales down for current-week views (Sun-current day),
-- capped at the CPR week's Saturday.

CREATE OR REPLACE FUNCTION public.compute_scorecard_done_for_cpr_week(
  p_agency_id uuid,
  p_week_ending_date date
)
RETURNS TABLE(
  team_member_id uuid,
  tier text,
  required_entry_type text,
  matching_count integer,
  threshold integer,
  done boolean
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_week_start date;
  v_today date;
  v_effective_end date;
  v_working_days_elapsed int;
BEGIN
  v_week_start := p_week_ending_date - 6;  -- Sunday of the CPR week
  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  v_effective_end := LEAST(v_today, p_week_ending_date);

  IF v_effective_end < v_week_start THEN
    v_working_days_elapsed := 0;
  ELSE
    SELECT COUNT(*)::int
    INTO v_working_days_elapsed
    FROM generate_series(v_week_start, v_effective_end, INTERVAL '1 day') AS d
    WHERE EXTRACT(dow FROM d) BETWEEN 1 AND 5;
  END IF;

  RETURN QUERY
  WITH tm AS (
    SELECT d.team_member_id, COALESCE(d.quotes_discussed, 0) AS quotes_discussed
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
    WHERE r.agency_id = p_agency_id
      AND r.week_ending_date = p_week_ending_date
  ),
  tiered AS (
    SELECT
      tm.team_member_id,
      tm.quotes_discussed,
      public.fit_scorecard_tenure_tier(tm.team_member_id, p_week_ending_date) AS tier
    FROM tm
  ),
  reqs AS (
    SELECT
      t.team_member_id,
      t.quotes_discussed,
      t.tier,
      public.fit_scorecard_entry_type_for_tenure(t.tier) AS required_entry_type
    FROM tiered t
  ),
  counts AS (
    SELECT s.team_member_id, s.entry_type, COUNT(*)::int AS c
    FROM public.fit_scorecards s
    WHERE s.agency_id = p_agency_id
      AND s.scorecard_date BETWEEN v_week_start AND p_week_ending_date
    GROUP BY s.team_member_id, s.entry_type
  ),
  final AS (
    SELECT
      r.team_member_id,
      r.tier,
      r.required_entry_type,
      COALESCE(c.c, 0) AS matching_count,
      CASE r.tier
        WHEN 'weeks_14_plus' THEN v_working_days_elapsed
        WHEN 'weeks_9_13'    THEN r.quotes_discussed
        WHEN 'weeks_1_8'     THEN GREATEST(r.quotes_discussed, v_working_days_elapsed)
        ELSE v_working_days_elapsed
      END AS threshold
    FROM reqs r
    LEFT JOIN counts c
      ON c.team_member_id = r.team_member_id
     AND c.entry_type    = r.required_entry_type
  )
  SELECT
    f.team_member_id,
    f.tier,
    f.required_entry_type,
    f.matching_count,
    f.threshold,
    (f.matching_count >= f.threshold) AS done
  FROM final f;
END;
$$;

GRANT EXECUTE ON FUNCTION public.compute_scorecard_done_for_cpr_week(uuid, date)
  TO anon, authenticated;

COMMENT ON FUNCTION public.compute_scorecard_done_for_cpr_week(uuid, date) IS
  'Weekly rollup of scorecard completion per team member for a given CPR week (Sun-Sat, keyed on the Saturday week_ending_date). Uses fit_scorecard_tenure_tier + fit_scorecard_entry_type_for_tenure as canonical helpers. Called by CPRDetail.jsx auto-verify on page load; safe for any future consumer.';
