-- Peter ruling 2026-09-02, follow-on: someone who left partway through the week has unreliable
-- checklist cleanup. They come off the checklist surfaces entirely for that week, and their
-- stored checklist columns contribute nothing.
--
-- Two pieces here:
--
-- 1. team_directory gains end_date. The CPR page reads the roster from this view (the real
--    team table is admin-or-own-row at the row level, so a staff viewer only gets their own
--    row from it). Without end_date on the view, a staff viewer could not tell who left and
--    would see a different checklist than an admin. end_date is a plain employment date, not
--    compensation data - termination_reason and pay stay off the view.
--    Appended at the END of the column list: CREATE OR REPLACE VIEW only allows new columns
--    at the end.
--
-- 2. compute_scorecard_done_for_cpr_week skips anyone who did not finish the week. That
--    function is the auto-verify the CPR page runs on every load to tick or untick the
--    Scorecard box. Returning a row for a leaver would write a false onto their record.
--    Absent from the result means "not computed", which the page already treats as
--    leave-the-stored-value-alone.
--
-- "Finished the week" = still employed through that week's Friday (week_ending_date - 1,
-- since week_ending_date is the Saturday). Same test as migration 20260903000629.

CREATE OR REPLACE VIEW public.team_directory AS
 SELECT id,
    agency_id,
    first_name,
    last_name,
    nickname,
    role,
    role_category,
    role_level,
    category,
    employment_type,
    is_active,
    archived_at,
    hire_date,
    start_date,
    work_location,
    four_day_off_day,
    phone_extension,
    phone_personal,
    email_personal,
    email_sf,
    sf_alias,
    account_alpha,
    license_states,
    license_pc,
    license_lh,
    license_ips,
    primary_function,
    secondary_function,
    user_id,
    is_admin_backoffice,
    is_test_user,
    photo_storage_path,
    end_date
   FROM team;

CREATE OR REPLACE FUNCTION public.compute_scorecard_done_for_cpr_week(p_agency_id uuid, p_week_ending_date date)
 RETURNS TABLE(team_member_id uuid, tier text, required_entry_type text, matching_count integer, threshold integer, done boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
    JOIN public.team t ON t.id = d.team_member_id
    WHERE r.agency_id = p_agency_id
      AND r.week_ending_date = p_week_ending_date
      -- Peter ruling 2026-09-02: nobody who left partway through the week is scored on their
      -- checklist for that week. Returning no row leaves their stored value untouched.
      AND (t.end_date IS NULL OR t.end_date >= (p_week_ending_date - 1))
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
