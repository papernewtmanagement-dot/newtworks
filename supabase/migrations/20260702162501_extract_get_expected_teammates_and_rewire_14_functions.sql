-- Migration: extract_get_expected_teammates_and_rewire_14_functions
-- Version: 20260702162501
-- Applied via Supabase MCP apply_migration

-- =========================================================================
-- Shared roster filter. Single source of truth for "who counts as an
-- expected teammate for purpose X" — bakes in is_admin_backoffice = false,
-- is_test_user IS NOT TRUE, archived_at filter (historical or current),
-- plus purpose-specific inclusion flags.
--
-- Purposes:
--   'work_checkin'          → include_in_team_checkins + tag_in_team_reminders
--   'health_checkin'        → include_in_health_checkins
--   'compensation'          → category='agency' AND role_level != 'Owner'
--   'time_off_participant'  → compensation + is_active
--   'wtw_am_sales'          → work_checkin + AM/UM role_level + Sales role_category
--   'wtw_am_retention'      → work_checkin + AM/UM role_level + Retention role_category
--   'agency_am_um'          → category='agency' + AM/UM role_level (for required_count)
--
-- as_of_date:
--   NULL (default) → archived_at IS NULL (current active)
--   Set → archived_at IS NULL OR archived_at > as_of_date (historical continuity)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.get_expected_teammates(
  p_agency_id uuid,
  p_purpose text,
  p_as_of_date date DEFAULT NULL
)
RETURNS TABLE (
  team_id uuid,
  first_name text,
  last_name text,
  nickname text,
  display_name text,
  category text,
  role text,
  role_level text,
  role_category text,
  email_sf text,
  email_personal text,
  start_date date
)
LANGUAGE sql
STABLE
AS $function$
  SELECT
    t.id AS team_id,
    t.first_name,
    t.last_name,
    t.nickname,
    COALESCE(NULLIF(t.nickname, ''), t.first_name) AS display_name,
    t.category,
    t.role,
    t.role_level,
    t.role_category,
    t.email_sf,
    t.email_personal,
    t.start_date
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
    );
$function$;
