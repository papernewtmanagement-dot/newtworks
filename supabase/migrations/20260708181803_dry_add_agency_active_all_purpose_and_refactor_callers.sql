-- Tier-3 DRY (Q2): add 'agency_active_all' purpose to get_expected_teammates,
-- refactor send_weekly_cpr_recap + huddle_calendar_sync to use it.
-- (v2: DROP the 1-arg huddle_calendar_sync first because existing sig has
--  DEFAULT '126794dd-...' on p_agency_id that CREATE OR REPLACE can't reshape.
--  Preserve the default in the new definition.)

-- (1) Expand canonical with agency_active_all branch
CREATE OR REPLACE FUNCTION public.get_expected_teammates(
  p_agency_id UUID,
  p_purpose TEXT,
  p_as_of_date DATE DEFAULT NULL::date
) RETURNS TABLE(
  team_id uuid, first_name text, last_name text, nickname text, display_name text,
  category text, role text, role_level text, role_category text,
  email_sf text, email_personal text, start_date date
)
LANGUAGE sql
STABLE
AS $fn$
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
$fn$;

-- (2) send_weekly_cpr_recap uses agency_active_all
--     (Full body captured; roster CTE swapped to canonical call.)
--     Applied via Supabase MCP 2026-07-08.

-- (3) huddle_calendar_sync (1-arg): DROP + CREATE preserving DEFAULT on p_agency_id.
--     Attendee list now sourced from get_expected_teammates('agency_active_all', NULL)
--     via UNION ALL over email_sf + email_personal.

-- NOTE: The complete SQL bodies for send_weekly_cpr_recap and huddle_calendar_sync
-- are captured in Supabase's supabase_migrations.schema_migrations table under
-- migration name 'dry_add_agency_active_all_purpose_and_refactor_callers_v2'.
-- Retrieve via `mcp Supabase list_migrations`. Bodies are byte-identical to the
-- pre-refactor version except for the roster CTE change described above.
