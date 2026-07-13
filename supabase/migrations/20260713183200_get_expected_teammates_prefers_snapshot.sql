-- get_expected_teammates: when p_as_of_date is provided AND team_weekly_snapshot
-- rows exist for the corresponding week_ending_date, evaluate filter predicates
-- against snapshot columns. Otherwise fall back to live-team behavior (unchanged).

CREATE OR REPLACE FUNCTION public.get_expected_teammates(
  p_agency_id uuid,
  p_purpose text,
  p_as_of_date date DEFAULT NULL::date
)
RETURNS TABLE(
  team_id uuid, first_name text, last_name text, nickname text,
  display_name text, category text, role text, role_level text,
  role_category text, email_sf text, email_personal text, start_date date
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_week_ending date;
  v_use_snapshot boolean := false;
BEGIN
  IF p_as_of_date IS NOT NULL THEN
    v_week_ending := p_as_of_date + ((6 - EXTRACT(dow FROM p_as_of_date)::int + 7) % 7)::int;
    SELECT EXISTS (
      SELECT 1 FROM public.team_weekly_snapshot
      WHERE agency_id = p_agency_id AND week_ending_date = v_week_ending
    ) INTO v_use_snapshot;
  END IF;

  IF v_use_snapshot THEN
    RETURN QUERY
    SELECT
      s.team_member_id AS team_id,
      s.first_name, s.last_name, s.nickname,
      COALESCE(NULLIF(s.nickname, ''), s.first_name) AS display_name,
      s.category, s.role, s.role_level, s.role_category,
      t.email_sf, t.email_personal, s.start_date
    FROM public.team_weekly_snapshot s
    JOIN public.team t ON t.id = s.team_member_id
    WHERE s.agency_id = p_agency_id
      AND s.week_ending_date = v_week_ending
      AND COALESCE(s.is_test_user, false) = false
      AND COALESCE(s.is_admin_backoffice, false) = false
      AND (s.archived_at IS NULL OR s.archived_at > p_as_of_date::timestamptz)
      AND (
        (p_purpose = 'work_checkin'
          AND (t.include_in_team_checkins = true OR
               (t.include_in_team_checkins IS NULL AND s.category = 'agency' AND s.role != 'Owner'))
          AND COALESCE(t.tag_in_team_reminders, true) = true)
        OR
        (p_purpose = 'health_checkin'
          AND (t.include_in_health_checkins = true OR
               (t.include_in_health_checkins IS NULL AND s.category = 'agency')))
        OR
        (p_purpose = 'compensation'
          AND s.category = 'agency'
          AND COALESCE(s.role_level, '') != 'Owner')
        OR
        (p_purpose = 'time_off_participant'
          AND s.category = 'agency'
          AND COALESCE(s.role_level, '') != 'Owner'
          AND s.is_active = true)
        OR
        (p_purpose = 'wtw_am_sales'
          AND s.role_level IN ('Account Manager', 'Unit Manager')
          AND s.role_category = 'Sales'
          AND (t.include_in_team_checkins = true OR
               (t.include_in_team_checkins IS NULL AND s.category = 'agency' AND s.role != 'Owner')))
        OR
        (p_purpose = 'wtw_am_retention'
          AND s.role_level IN ('Account Manager', 'Unit Manager')
          AND s.role_category = 'Retention'
          AND (t.include_in_team_checkins = true OR
               (t.include_in_team_checkins IS NULL AND s.category = 'agency' AND s.role != 'Owner')))
        OR
        (p_purpose = 'agency_am_um'
          AND s.category = 'agency'
          AND s.role_level IN ('Account Manager', 'Unit Manager'))
        OR
        (p_purpose = 'agency_active_all'
          AND s.category = 'agency'
          AND s.is_active = true)
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
          AND COALESCE(t.tag_in_team_reminders, true) = true)
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
