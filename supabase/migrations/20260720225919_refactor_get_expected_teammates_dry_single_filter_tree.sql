-- DRY refactor: collapse the two 9-purpose filter trees (snapshot + live) into ONE.
--
-- Prior structure duplicated every purpose filter across two branches — one against
-- weekly_cpr_team_detail (d.*), one against public.team (t.*). Divergence between the
-- two trees was silent (today's John-missing-from-midday bug was the first symptom).
--
-- New structure resolves roster-source-of-truth in a single CTE, then filters ONCE.
-- Snapshot-vs-live selection is one boolean, purpose filters live in one place.
-- Verified byte-identical to prior function across all 9 purposes × 4 date shapes
-- (current week, last closed week, deep historical, NULL) before swap.

CREATE OR REPLACE FUNCTION public.get_expected_teammates(p_agency_id uuid, p_purpose text, p_as_of_date date DEFAULT NULL::date)
 RETURNS TABLE(team_id uuid, first_name text, last_name text, nickname text, display_name text, category text, role text, role_level text, role_category text, email_sf text, email_personal text, start_date date)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_today_ct      date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_week_ending   date;
  v_use_snapshot  boolean := false;
  v_time_off_date date := COALESCE(p_as_of_date, (now() AT TIME ZONE 'America/Chicago')::date);
BEGIN
  -- Snapshot branch fires only when the target week's Saturday is already in the past
  -- AND the snapshot for that week has at least one populated row. Mid-week + current-week
  -- reads always fall through to live team, because weekly_cpr_team_detail is populated
  -- lazily by the team_checkins sync trigger and would silently drop teammates who
  -- haven't checked in yet.
  IF p_as_of_date IS NOT NULL THEN
    v_week_ending := p_as_of_date + ((6 - EXTRACT(dow FROM p_as_of_date)::int + 7) % 7)::int;
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
    -- Snapshot leg: teammate identity + role/category frozen from the CPR snapshot,
    -- while licensing / include-flags / emails come live from public.team (they represent
    -- CURRENT state, not week-of state).
    SELECT
      d.team_member_id                                   AS team_id,
      d.first_name, d.last_name, d.nickname,
      d.category, d.role, d.role_level, d.role_category,
      d.start_date,
      d.is_active, d.archived_at, d.is_test_user, d.is_admin_backoffice,
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

    -- Live leg: everything from public.team.
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
    AND (r.archived_at IS NULL
         OR (p_as_of_date IS NOT NULL AND r.archived_at > p_as_of_date::timestamptz))
    AND (
      -- work_checkin: nag list. Requires an active license and excludes teammates on
      -- an approved full-day time-off on the target date.
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
            AND COALESCE(tor.partial_day, 'none') = 'none'
        ))
      OR
      -- work_display: roster shown in check-in listings. Same as work_checkin without
      -- the PTO filter (teammates on PTO still appear in the listing, they just aren't nagged).
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

DROP FUNCTION IF EXISTS public.get_expected_teammates_v2(uuid, text, date);
