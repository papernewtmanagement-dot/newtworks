-- Migration: add 'work_display' purpose to get_expected_teammates
--
-- Peter directive 2026-07-20: "if somebody is off, we don't nag them. We still
-- show them, though, in the listing."
--
-- New purpose 'work_display' is same shape as 'work_checkin' but WITHOUT the
-- PTO exclusion and WITHOUT the tag_in_team_reminders gate — those govern
-- NAGGING (who gets reminded), not who appears in a status listing.
-- Fully-unlicensed filter retained pending separate decision on Cassandra.

CREATE OR REPLACE FUNCTION public.get_expected_teammates(p_agency_id uuid, p_purpose text, p_as_of_date date DEFAULT NULL::date)
 RETURNS TABLE(team_id uuid, first_name text, last_name text, nickname text, display_name text, category text, role text, role_level text, role_category text, email_sf text, email_personal text, start_date date)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_week_ending date;
  v_use_snapshot boolean := false;
  v_time_off_date date;
BEGIN
  IF p_as_of_date IS NOT NULL THEN
    v_week_ending := p_as_of_date + ((6 - EXTRACT(dow FROM p_as_of_date)::int + 7) % 7)::int;
    SELECT EXISTS (
      SELECT 1
      FROM public.weekly_cpr_team_detail d
      JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
      WHERE r.agency_id = p_agency_id AND r.week_ending_date = v_week_ending
        AND d.role_level IS NOT NULL
    ) INTO v_use_snapshot;
  END IF;

  v_time_off_date := COALESCE(p_as_of_date, (now() AT TIME ZONE 'America/Chicago')::date);

  IF v_use_snapshot THEN
    RETURN QUERY
    SELECT
      d.team_member_id AS team_id,
      d.first_name, d.last_name, d.nickname,
      COALESCE(NULLIF(d.nickname, ''), d.first_name) AS display_name,
      d.category, d.role, d.role_level, d.role_category,
      t.email_sf, t.email_personal, d.start_date
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
    JOIN public.team t ON t.id = d.team_member_id
    WHERE r.agency_id       = p_agency_id
      AND r.week_ending_date = v_week_ending
      AND COALESCE(d.is_test_user, false) = false
      AND COALESCE(d.is_admin_backoffice, false) = false
      AND (d.archived_at IS NULL OR d.archived_at > p_as_of_date::timestamptz)
      AND (
        (p_purpose = 'work_checkin'
          AND (t.include_in_team_checkins = true OR
               (t.include_in_team_checkins IS NULL AND d.category = 'agency' AND d.role != 'Owner'))
          AND COALESCE(t.tag_in_team_reminders, true) = true
          AND NOT (COALESCE(t.license_pc, false) = false
                   AND COALESCE(t.license_lh, false) = false
                   AND COALESCE(t.license_ips, false) = false)
          AND NOT EXISTS (
            SELECT 1 FROM public.time_off_requests tor
            WHERE tor.requester_team_id = t.id
              AND tor.agency_id = p_agency_id
              AND tor.status = 'approved'
              AND v_time_off_date BETWEEN tor.start_date AND tor.end_date
              AND COALESCE(tor.partial_day, 'none') = 'none'
          ))
        OR
        (p_purpose = 'work_display'
          AND (t.include_in_team_checkins = true OR
               (t.include_in_team_checkins IS NULL AND d.category = 'agency' AND d.role != 'Owner'))
          AND NOT (COALESCE(t.license_pc, false) = false
                   AND COALESCE(t.license_lh, false) = false
                   AND COALESCE(t.license_ips, false) = false))
        OR
        (p_purpose = 'health_checkin'
          AND (t.include_in_health_checkins = true OR
               (t.include_in_health_checkins IS NULL AND d.category = 'agency')))
        OR
        (p_purpose = 'compensation'
          AND d.category = 'agency'
          AND COALESCE(d.role_level, '') != 'Owner')
        OR
        (p_purpose = 'time_off_participant'
          AND d.category = 'agency'
          AND COALESCE(d.role_level, '') != 'Owner'
          AND d.is_active = true)
        OR
        (p_purpose = 'wtw_am_sales'
          AND d.role_level IN ('Account Manager', 'Unit Manager')
          AND d.role_category = 'Sales'
          AND (t.include_in_team_checkins = true OR
               (t.include_in_team_checkins IS NULL AND d.category = 'agency' AND d.role != 'Owner')))
        OR
        (p_purpose = 'wtw_am_retention'
          AND d.role_level IN ('Account Manager', 'Unit Manager')
          AND d.role_category = 'Retention'
          AND (t.include_in_team_checkins = true OR
               (t.include_in_team_checkins IS NULL AND d.category = 'agency' AND d.role != 'Owner')))
        OR
        (p_purpose = 'agency_am_um'
          AND d.category = 'agency'
          AND d.role_level IN ('Account Manager', 'Unit Manager'))
        OR
        (p_purpose = 'agency_active_all'
          AND d.category = 'agency'
          AND d.is_active = true)
      );
  ELSE
    RETURN QUERY
    SELECT
      t.id AS team_id, t.first_name, t.last_name, t.nickname,
      COALESCE(NULLIF(t.nickname, ''), t.first_name) AS display_name,
      t.category, t.role, t.role_level, t.role_category,
      t.email_sf, t.email_personal, t.start_date
    FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND t.is_test_user IS NOT TRUE
      AND t.is_admin_backoffice = false
      AND (
        p_as_of_date IS NULL AND t.archived_at IS NULL
        OR p_as_of_date IS NOT NULL AND (t.archived_at IS NULL OR t.archived_at > p_as_of_date::timestamptz)
      )
      AND (
        (p_purpose = 'work_checkin'
          AND (t.include_in_team_checkins = true OR
               (t.include_in_team_checkins IS NULL AND t.category = 'agency' AND t.role != 'Owner'))
          AND COALESCE(t.tag_in_team_reminders, true) = true
          AND NOT (COALESCE(t.license_pc, false) = false
                   AND COALESCE(t.license_lh, false) = false
                   AND COALESCE(t.license_ips, false) = false)
          AND NOT EXISTS (
            SELECT 1 FROM public.time_off_requests tor
            WHERE tor.requester_team_id = t.id
              AND tor.agency_id = p_agency_id
              AND tor.status = 'approved'
              AND v_time_off_date BETWEEN tor.start_date AND tor.end_date
              AND COALESCE(tor.partial_day, 'none') = 'none'
          ))
        OR
        (p_purpose = 'work_display'
          AND (t.include_in_team_checkins = true OR
               (t.include_in_team_checkins IS NULL AND t.category = 'agency' AND t.role != 'Owner'))
          AND NOT (COALESCE(t.license_pc, false) = false
                   AND COALESCE(t.license_lh, false) = false
                   AND COALESCE(t.license_ips, false) = false))
        OR
        (p_purpose = 'health_checkin'
          AND (t.include_in_health_checkins = true OR
               (t.include_in_health_checkins IS NULL AND t.category = 'agency')))
        OR
        (p_purpose = 'compensation'
          AND t.category = 'agency'
          AND COALESCE(t.role_level, '') != 'Owner')
        OR
        (p_purpose = 'time_off_participant'
          AND t.category = 'agency'
          AND COALESCE(t.role_level, '') != 'Owner'
          AND t.is_active = true)
        OR
        (p_purpose = 'wtw_am_sales'
          AND t.role_level IN ('Account Manager', 'Unit Manager')
          AND t.role_category = 'Sales'
          AND (t.include_in_team_checkins = true OR
               (t.include_in_team_checkins IS NULL AND t.category = 'agency' AND t.role != 'Owner')))
        OR
        (p_purpose = 'wtw_am_retention'
          AND t.role_level IN ('Account Manager', 'Unit Manager')
          AND t.role_category = 'Retention'
          AND (t.include_in_team_checkins = true OR
               (t.include_in_team_checkins IS NULL AND t.category = 'agency' AND t.role != 'Owner')))
        OR
        (p_purpose = 'agency_am_um'
          AND t.category = 'agency'
          AND t.role_level IN ('Account Manager', 'Unit Manager'))
        OR
        (p_purpose = 'agency_active_all'
          AND t.category = 'agency'
          AND t.is_active = true)
      );
  END IF;
END;
$function$;
