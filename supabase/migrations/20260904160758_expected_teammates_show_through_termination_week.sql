-- Peter directive 2026-09-04: a teammate terminated mid-week still shows on the
-- roster for the rest of THAT week. Previously the cutoff compared archived_at to
-- the exact as-of date, so someone archived on Tuesday vanished from Wednesday's
-- team status block even though the week they worked was still open.
-- New rule: show if archived_at falls on or after the Sunday that starts the week
-- containing p_as_of_date. They drop off starting the following week.
CREATE OR REPLACE FUNCTION public.get_expected_teammates(p_agency_id uuid, p_purpose text, p_as_of_date date DEFAULT NULL::date, p_checkin_type text DEFAULT NULL::text)
 RETURNS TABLE(team_id uuid, first_name text, last_name text, nickname text, display_name text, category text, role text, role_level text, role_category text, email_sf text, email_personal text, start_date date)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_today_ct      date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_week_ending   date;
  v_week_start    date;
  v_use_snapshot  boolean := false;
  v_time_off_date date := COALESCE(p_as_of_date, (now() AT TIME ZONE 'America/Chicago')::date);
BEGIN
  IF p_as_of_date IS NOT NULL THEN
    v_week_ending := p_as_of_date + ((6 - EXTRACT(dow FROM p_as_of_date)::int + 7) % 7)::int;
    v_week_start  := v_week_ending - 6;
    IF v_week_ending < v_today_ct THEN
      SELECT EXISTS (
        SELECT 1
        FROM public.weekly_cpr_team_detail d
        JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
        WHERE r.agency_id = p_agency_id
          AND r.week_ending_date = v_week_ending
          AND d.role_level IS NOT NULL
      ) INTO v_use_snapshot;
    END IF;
  END IF;

  RETURN QUERY
  WITH roster AS (
    SELECT
      d.team_member_id                                   AS team_id,
      d.first_name, d.last_name, d.nickname,
      d.category, d.role, d.role_level, d.role_category,
      d.start_date,
      d.is_active, d.archived_at,
      (COALESCE(d.is_test_user, false) OR COALESCE(t.is_test_user, false))                 AS is_test_user,
      (COALESCE(d.is_admin_backoffice, false) OR COALESCE(t.is_admin_backoffice, false))   AS is_admin_backoffice,
      t.email_sf, t.email_personal,
      t.include_in_team_checkins, t.tag_in_team_reminders, t.include_in_health_checkins,
      t.license_pc, t.license_lh, t.license_ips
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r  ON r.id = d.weekly_cpr_report_id
    JOIN public.team t                ON t.id = d.team_member_id
    WHERE v_use_snapshot
      AND r.agency_id       = p_agency_id
      AND r.week_ending_date = v_week_ending

    UNION ALL

    SELECT
      t.id AS team_id,
      t.first_name, t.last_name, t.nickname,
      t.category, t.role, t.role_level, t.role_category,
      t.start_date,
      t.is_active, t.archived_at, t.is_test_user, t.is_admin_backoffice,
      t.email_sf, t.email_personal,
      t.include_in_team_checkins, t.tag_in_team_reminders, t.include_in_health_checkins,
      t.license_pc, t.license_lh, t.license_ips
    FROM public.team t
    WHERE NOT v_use_snapshot
      AND t.agency_id = p_agency_id
  )
  SELECT
    r.team_id,
    r.first_name, r.last_name, r.nickname,
    COALESCE(NULLIF(r.nickname,''), r.first_name)::text AS display_name,
    r.category, r.role, r.role_level, r.role_category,
    r.email_sf, r.email_personal,
    r.start_date
  FROM roster r
  WHERE r.is_test_user IS NOT TRUE
    AND COALESCE(r.is_admin_backoffice, false) = false
    -- Termination-week visibility: a teammate archived during the displayed week
    -- stays on the roster for that whole week (Peter 2026-09-04).
    AND (r.archived_at IS NULL
         OR (p_as_of_date IS NOT NULL
             AND (r.archived_at AT TIME ZONE 'America/Chicago')::date >= v_week_start))
    AND (
      -- work_checkin: nag list. Requires an active license and excludes teammates whose
      -- approved time off covers the specific reminder window (full day always; half-day
      -- mapped by p_checkin_type -- morning-off covers morning+midday, afternoon-off covers eod).
      (p_purpose = 'work_checkin'
        AND (r.include_in_team_checkins = true OR
             (r.include_in_team_checkins IS NULL AND r.category = 'agency' AND r.role != 'Owner'))
        AND COALESCE(r.tag_in_team_reminders, true) = true
        AND (COALESCE(r.license_pc, false)
             OR COALESCE(r.license_lh, false)
             OR COALESCE(r.license_ips, false))
        AND NOT EXISTS (
          SELECT 1 FROM public.time_off_requests tor
          WHERE tor.requester_team_id = r.team_id
            AND tor.agency_id         = p_agency_id
            AND tor.status            = 'approved'
            AND v_time_off_date BETWEEN tor.start_date AND tor.end_date
            AND (
              COALESCE(tor.partial_day, 'none') = 'none'
              OR (p_checkin_type IN ('morning', 'midday') AND tor.partial_day = 'morning')
              OR (p_checkin_type = 'eod' AND tor.partial_day = 'afternoon')
            )
        ))
      OR
      (p_purpose = 'work_display'
        AND (r.include_in_team_checkins = true OR
             (r.include_in_team_checkins IS NULL AND r.category = 'agency' AND r.role != 'Owner'))
        AND (COALESCE(r.license_pc, false)
             OR COALESCE(r.license_lh, false)
             OR COALESCE(r.license_ips, false)))
      OR
      (p_purpose = 'health_checkin'
        AND (r.include_in_health_checkins = true OR
             (r.include_in_health_checkins IS NULL AND r.category = 'agency')))
      OR
      (p_purpose = 'compensation'
        AND r.category = 'agency'
        AND COALESCE(r.role_level, '') != 'Owner')
      OR
      (p_purpose = 'time_off_participant'
        AND r.category = 'agency'
        AND COALESCE(r.role_level, '') != 'Owner'
        AND r.is_active = true)
      OR
      (p_purpose = 'wtw_am_sales'
        AND r.role_level IN ('Account Manager', 'Unit Manager')
        AND r.role_category = 'Sales'
        AND (r.include_in_team_checkins = true OR
             (r.include_in_team_checkins IS NULL AND r.category = 'agency' AND r.role != 'Owner')))
      OR
      (p_purpose = 'wtw_am_retention'
        AND r.role_level IN ('Account Manager', 'Unit Manager')
        AND r.role_category = 'Retention'
        AND (r.include_in_team_checkins = true OR
             (r.include_in_team_checkins IS NULL AND r.category = 'agency' AND r.role != 'Owner')))
      OR
      (p_purpose = 'agency_am_um'
        AND r.category = 'agency'
        AND r.role_level IN ('Account Manager', 'Unit Manager'))
      OR
      (p_purpose = 'agency_active_all'
        AND r.category = 'agency'
        AND r.is_active = true)
    );
END;
$function$;
