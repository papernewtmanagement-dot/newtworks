-- compute_scorecard_done_for_cpr_week: also stop expecting a scorecard on a day
-- the agency was closed for a holiday.
--
-- Rewritten from "count weekdays, then subtract" to "count the days this person was
-- actually expected to work". The subtract approach double-counted when a closed
-- holiday and a personal approved day off landed on the same date — e.g. a teammate
-- who filed time off for Thanksgiving would have had the day removed twice and ended
-- up owing one scorecard fewer than they should. Counting expected days directly
-- makes that impossible.
--
-- A day is expected if it is Mon-Fri, inside the elapsed part of the week, NOT an
-- active company_holidays row with observance='closed', and NOT covered by an
-- approved whole-day absence for that person.
--
-- observance='non_standard' (day after Thanksgiving, Christmas Eve) is deliberately
-- NOT excluded — per the handbook the office is open those days and a teammate who
-- wants off "must schedule it as a normal day", which creates its own time-off row
-- and is picked up by the personal-absence leg below.
--
-- Return signature unchanged.

CREATE OR REPLACE FUNCTION public.compute_scorecard_done_for_cpr_week(p_agency_id uuid, p_week_ending_date date)
 RETURNS TABLE(team_member_id uuid, tier text, required_entry_type text, matching_count integer, threshold integer, done boolean)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_week_start date;
  v_today date;
  v_effective_end date;
BEGIN
  v_week_start := p_week_ending_date - 6;  -- Sunday of the CPR week
  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  v_effective_end := LEAST(v_today, p_week_ending_date);

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
  -- Days this person was actually expected to work, within the elapsed week.
  expected AS (
    SELECT r.team_member_id, COUNT(*)::int AS days_expected
    FROM reqs r
    CROSS JOIN generate_series(v_week_start, v_effective_end, INTERVAL '1 day') AS d
    WHERE EXTRACT(dow FROM d) BETWEEN 1 AND 5
      -- agency closed for a holiday: nobody is expected to work
      AND NOT EXISTS (
        SELECT 1 FROM public.company_holidays h
        WHERE h.agency_id = p_agency_id
          AND h.is_active
          AND h.observance = 'closed'
          AND h.holiday_date = d::date
      )
      -- this person had an approved whole-day absence
      AND NOT EXISTS (
        SELECT 1 FROM public.time_off_requests tor
        WHERE tor.agency_id = p_agency_id
          AND tor.requester_team_id = r.team_member_id
          AND tor.status = 'approved'
          AND tor.request_type IN ('time_off_full_day', 'sick')
          AND COALESCE(tor.partial_day, 'none') = 'none'
          AND d::date BETWEEN tor.start_date AND tor.end_date
      )
    GROUP BY r.team_member_id
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
        WHEN 'weeks_14_plus' THEN COALESCE(e.days_expected, 0)
        WHEN 'weeks_9_13'    THEN r.quotes_discussed
        WHEN 'weeks_1_8'     THEN GREATEST(r.quotes_discussed, COALESCE(e.days_expected, 0))
        ELSE COALESCE(e.days_expected, 0)
      END AS threshold
    FROM reqs r
    LEFT JOIN expected e ON e.team_member_id = r.team_member_id
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
$function$;
