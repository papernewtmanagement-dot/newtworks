-- Tier-3 DRY: compose_weekly_cpr_html all 4 team scans -> get_expected_teammates.
-- Applied 2026-07-08. Parity verified byte-exact HTML output (MD5 unchanged,
-- length unchanged at 42,360 bytes).
--
-- 4 scans (v_team_size count, v_hours_rows, v_activity_rows, payroll_calc CTE)
-- all used identical hand-rolled compensation filter. Swapped each to:
--   FROM public.get_expected_teammates(p_agency_id, 'compensation', v_week_start) et
--   JOIN public.team t ON t.id = et.team_id
-- Downstream t.* references (hire_date, nickname, first_name, last_name)
-- preserved via the JOIN.
--
-- Applied via DO block that fetches pg_get_functiondef, applies 4 targeted
-- replace() operations, and re-EXECUTEs. Same pattern as Tier-4 anchor fix.

DO $mig$
DECLARE
  v_current_def text;
  v_updated_def text;
  v_hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_current_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'compose_weekly_cpr_html';

  IF v_current_def IS NULL THEN
    RAISE EXCEPTION 'compose_weekly_cpr_html not found in pg_proc';
  END IF;

  -- Scan 1: v_team_size count
  v_updated_def := replace(v_current_def,
    'FROM public.team t
  WHERE t.agency_id = p_agency_id AND t.category = ''agency''
    AND COALESCE(t.role_level, '''') <> ''Owner''
    AND t.is_admin_backoffice = false
    AND (t.archived_at IS NULL OR t.archived_at > v_week_start::timestamptz);',
    'FROM public.get_expected_teammates(p_agency_id, ''compensation'', v_week_start) et;'
  );
  IF v_updated_def = v_current_def THEN RAISE EXCEPTION 'Scan 1 replacement failed'; END IF;

  -- Scan 2: v_hours_rows
  v_current_def := v_updated_def;
  v_updated_def := replace(v_current_def,
    'FROM public.team t
  LEFT JOIN h_pivot hp ON hp.team_member_id = t.id
  WHERE t.agency_id = p_agency_id AND t.category = ''agency''
    AND COALESCE(t.role_level,'''') <> ''Owner''
    AND t.is_admin_backoffice = false
    AND (t.archived_at IS NULL OR t.archived_at > v_week_start::timestamptz);',
    'FROM public.get_expected_teammates(p_agency_id, ''compensation'', v_week_start) et
  JOIN public.team t ON t.id = et.team_id
  LEFT JOIN h_pivot hp ON hp.team_member_id = t.id;'
  );
  IF v_updated_def = v_current_def THEN RAISE EXCEPTION 'Scan 2 replacement failed'; END IF;

  -- Scan 3: v_activity_rows
  v_current_def := v_updated_def;
  v_updated_def := replace(v_current_def,
    'FROM public.team t
  LEFT JOIN public.weekly_cpr_team_detail d
    ON d.team_member_id = t.id AND d.weekly_cpr_report_id = v_report.id
  LEFT JOIN public.get_weekly_cpr_requirements(p_agency_id, p_week_ending_date) r
    ON r.team_member_id = t.id
  WHERE t.agency_id = p_agency_id AND t.category = ''agency''
    AND COALESCE(t.role_level,'''') <> ''Owner''
    AND t.is_admin_backoffice = false
    AND (t.archived_at IS NULL OR t.archived_at > v_week_start::timestamptz);',
    'FROM public.get_expected_teammates(p_agency_id, ''compensation'', v_week_start) et
  JOIN public.team t ON t.id = et.team_id
  LEFT JOIN public.weekly_cpr_team_detail d
    ON d.team_member_id = t.id AND d.weekly_cpr_report_id = v_report.id
  LEFT JOIN public.get_weekly_cpr_requirements(p_agency_id, p_week_ending_date) r
    ON r.team_member_id = t.id;'
  );
  IF v_updated_def = v_current_def THEN RAISE EXCEPTION 'Scan 3 replacement failed'; END IF;

  -- Scan 4: payroll_calc CTE
  v_current_def := v_updated_def;
  v_updated_def := replace(v_current_def,
    'FROM public.team t
    LEFT JOIN public.weekly_cpr_team_detail d ON d.team_member_id = t.id AND d.weekly_cpr_report_id = v_report.id
    WHERE t.agency_id = p_agency_id AND t.category = ''agency''
      AND COALESCE(t.role_level,'''') <> ''Owner''
      AND t.is_admin_backoffice = false
      AND (t.archived_at IS NULL OR t.archived_at > v_week_start::timestamptz)',
    'FROM public.get_expected_teammates(p_agency_id, ''compensation'', v_week_start) et
    JOIN public.team t ON t.id = et.team_id
    LEFT JOIN public.weekly_cpr_team_detail d ON d.team_member_id = t.id AND d.weekly_cpr_report_id = v_report.id'
  );
  IF v_updated_def = v_current_def THEN RAISE EXCEPTION 'Scan 4 replacement failed'; END IF;

  -- Sanity: no more hand-rolled admin filters should remain in the function body
  v_hits := (length(v_updated_def) - length(replace(v_updated_def, 'is_admin_backoffice', ''))) / length('is_admin_backoffice');
  IF v_hits <> 0 THEN
    RAISE EXCEPTION 'Expected 0 remaining is_admin_backoffice references, found %', v_hits;
  END IF;

  EXECUTE v_updated_def;
END $mig$;
