-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-13 19:13:33 UTC (ledger name: hours_and_expected_teammates_use_detail_cols) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260713191333.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

-- get_weekly_cpr_hours: prefer weekly_cpr_team_detail snapshot cols instead 
-- of team_weekly_snapshot (which is being dropped).
CREATE OR REPLACE FUNCTION public.get_weekly_cpr_hours(p_agency_id uuid, p_week_ending_date date)
RETURNS TABLE(team_member_id uuid, day_idx integer, day_label text, work_date date, hours numeric, location text)
LANGUAGE sql
AS $function$
WITH
  week_days AS (
    SELECT
      day_offset                                              AS day_idx,
      CASE day_offset WHEN 1 THEN 'mon' WHEN 2 THEN 'tue' WHEN 3 THEN 'wed'
                      WHEN 4 THEN 'thu' WHEN 5 THEN 'fri' END AS day_label,
      (p_week_ending_date - (6 - day_offset))::date           AS work_date
    FROM generate_series(1, 5) AS day_offset
  ),
  active_team AS (
    SELECT
      et.team_id,
      COALESCE(d.pay_type,      t.pay_type)      AS pay_type,
      COALESCE(d.work_location, t.work_location) AS work_location
    FROM public.get_expected_teammates(p_agency_id, 'compensation', (p_week_ending_date - 6)) et
    JOIN public.team t ON t.id = et.team_id
    LEFT JOIN public.weekly_cpr_reports r
      ON r.agency_id = p_agency_id AND r.week_ending_date = p_week_ending_date
    LEFT JOIN public.weekly_cpr_team_detail d
      ON d.weekly_cpr_report_id = r.id AND d.team_member_id = et.team_id
  ),
  hourly_hours AS (
    SELECT
      team_member_id,
      DATE(clock_in_at AT TIME ZONE 'America/Chicago') AS work_date,
      ROUND(SUM(EXTRACT(EPOCH FROM (clock_out_at - clock_in_at))) / 3600.0, 2)::numeric AS hours
    FROM public.time_clock_entries
    WHERE agency_id    = p_agency_id
      AND clock_out_at IS NOT NULL
    GROUP BY team_member_id, DATE(clock_in_at AT TIME ZONE 'America/Chicago')
  ),
  hourly_locations AS (
    SELECT team_member_id, work_date, location
    FROM (
      SELECT
        team_member_id,
        DATE(clock_in_at AT TIME ZONE 'America/Chicago') AS work_date,
        work_location AS location,
        ROW_NUMBER() OVER (
          PARTITION BY team_member_id, DATE(clock_in_at AT TIME ZONE 'America/Chicago')
          ORDER BY clock_in_at DESC
        ) AS rn
      FROM public.time_clock_entries
      WHERE agency_id     = p_agency_id
        AND work_location IS NOT NULL
    ) s
    WHERE rn = 1
  ),
  time_off_per_day AS (
    SELECT
      tor.requester_team_id AS team_member_id,
      d::date AS work_date,
      MAX(CASE
        WHEN tor.request_type = 'time_off_full_day'
          OR (tor.request_type = 'sick' AND COALESCE(tor.partial_day, 'none') = 'none')
          THEN 8
        WHEN tor.request_type = 'time_off_half_day'
          OR (tor.request_type = 'sick' AND tor.partial_day IN ('morning', 'afternoon'))
          THEN 4
        ELSE 0
      END) AS hours_off
    FROM public.time_off_requests tor
    CROSS JOIN LATERAL generate_series(tor.start_date, tor.end_date, '1 day'::interval) AS d
    WHERE tor.agency_id = p_agency_id
      AND tor.status    = 'approved'
    GROUP BY tor.requester_team_id, d::date
  )
SELECT
  at.team_id AS team_member_id,
  wd.day_idx,
  wd.day_label,
  wd.work_date,
  CASE
    WHEN at.pay_type = 'HOURLY' THEN COALESCE(hh.hours, 0)
    ELSE GREATEST(0, 8 - COALESCE(toff.hours_off, 0))
  END AS hours,
  CASE
    WHEN at.pay_type = 'HOURLY' THEN COALESCE(hl.location, at.work_location)
    ELSE at.work_location
  END AS location
FROM active_team at
CROSS JOIN week_days wd
LEFT JOIN hourly_hours hh
  ON hh.team_member_id = at.team_id
 AND hh.work_date      = wd.work_date
LEFT JOIN hourly_locations hl
  ON hl.team_member_id = at.team_id
 AND hl.work_date      = wd.work_date
LEFT JOIN time_off_per_day toff
  ON toff.team_member_id = at.team_id
 AND toff.work_date      = wd.work_date
ORDER BY at.team_id, wd.day_idx;
$function$;

-- get_expected_teammates: switch snapshot lookup from team_weekly_snapshot
-- to weekly_cpr_team_detail. Filters evaluate against d.role, d.role_level, 
-- d.role_category, d.category, d.is_active, d.archived_at, etc. Live team 
-- is fallback when as_of_date is not provided OR no detail rows exist for 
-- that week yet.
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
      SELECT 1 
      FROM public.weekly_cpr_team_detail d
      JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
      WHERE r.agency_id = p_agency_id AND r.week_ending_date = v_week_ending
        AND d.role_level IS NOT NULL   -- snapshot populated
    ) INTO v_use_snapshot;
  END IF;

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
          AND COALESCE(t.tag_in_team_reminders, true) = true)
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
