-- compute_scorecard_done_for_cpr_week: the number of scorecards a teammate owes for the
-- week must not count days they were approved off. Before this change the Monday-to-Friday
-- day count was computed once for the whole agency, so a teammate with an approved full day
-- off was still expected to turn in five scorecards and showed as incomplete at four.
--
-- Only genuine whole-day absences are subtracted: an approved request of type
-- 'time_off_full_day' or 'sick' whose partial_day is 'none'. Deliberately NOT subtracted:
--   - half days ('time_off_half_day', or sick with partial_day morning/afternoon) — the
--     teammate worked part of that day and is still expected to log it
--   - remote days ('remote_day', 'remote_half_day') — working, just not in the office
--   - 'four_day_off_change' — a request to move a standing off day, not an absence itself
--   - 'standing_time_off_preference' — a template row, not a dated absence; the actual
--     off days it produces are materialized as separate 'time_off_full_day' rows
--
-- Company holidays are not stored in the database (they live on the shared Google
-- calendar), so a holiday still counts as a working day here. If that becomes a problem
-- the holidays need a table first.
--
-- Return signature is unchanged: threshold is now per person rather than agency-wide.

CREATE OR REPLACE FUNCTION public.compute_scorecard_done_for_cpr_week(p_agency_id uuid, p_week_ending_date date)
 RETURNS TABLE(team_member_id uuid, tier text, required_entry_type text, matching_count integer, threshold integer, done boolean)
 LANGUAGE plpgsql
 STABLE
AS $function$
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
  -- Approved whole-day absences per person, counted only on Mon-Fri inside the
  -- part of the week that has actually elapsed.
  days_off AS (
    SELECT
      tor.requester_team_id AS team_member_id,
      COUNT(DISTINCT d::date)::int AS off_days
    FROM public.time_off_requests tor
    CROSS JOIN LATERAL generate_series(
      GREATEST(tor.start_date, v_week_start),
      LEAST(tor.end_date, v_effective_end),
      INTERVAL '1 day'
    ) AS d
    WHERE tor.agency_id = p_agency_id
      AND tor.status = 'approved'
      AND tor.request_type IN ('time_off_full_day', 'sick')
      AND COALESCE(tor.partial_day, 'none') = 'none'
      AND tor.start_date <= v_effective_end
      AND tor.end_date   >= v_week_start
      AND EXTRACT(dow FROM d) BETWEEN 1 AND 5
    GROUP BY tor.requester_team_id
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
      public.fit_scorecard_entry_type_for_tenure(t.tier) AS required_entry_type,
      GREATEST(v_working_days_elapsed - COALESCE(o.off_days, 0), 0) AS working_days_worked
    FROM tiered t
    LEFT JOIN days_off o ON o.team_member_id = t.team_member_id
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
        WHEN 'weeks_14_plus' THEN r.working_days_worked
        WHEN 'weeks_9_13'    THEN r.quotes_discussed
        WHEN 'weeks_1_8'     THEN GREATEST(r.quotes_discussed, r.working_days_worked)
        ELSE r.working_days_worked
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
$function$;
