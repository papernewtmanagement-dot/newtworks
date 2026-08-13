-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 20:01:23 UTC (ledger name: dry_compose_weekly_cpr_html_uses_canonical_roster) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708200123.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Tier-3 DRY (comp engine sibling): compose_weekly_cpr_html now uses canonical roster
-- for all 4 team scans. Each was hand-rolling:
--   category='agency' + role_level<>'Owner' + is_admin_backoffice=false
--   + (archived_at IS NULL OR archived_at > v_week_start::timestamptz)
-- Exact compensation-purpose match.
--
-- Refactor: swap FROM public.team t + WHERE ... to
-- FROM public.get_expected_teammates(p_agency_id, 'compensation', v_week_start) et
-- JOIN public.team t ON t.id = et.team_id (JOIN preserved so all t.* refs in
-- SELECT projections keep working). Downstream columns (t.hire_date, t.nickname,
-- t.first_name, t.last_name) unchanged.
--
-- Behavioral note: canonical adds is_test_user IS NOT TRUE baseline. Verified
-- pre-migration: all 4 currently-active teammates flow through canonical filter
-- identically to hand-rolled (compute_pool_carveouts sibling migration produced
-- byte-exact parity on same underlying pattern).
--
-- Parity baseline for compose_weekly_cpr_html captured in
-- public._tier3_comp_parity before this migration; post-migration HTML will be
-- diffed against baseline hash.

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

  -- ─── Scan 1: v_team_size count ─────────────────────────────────────
  v_updated_def := replace(v_current_def,
    'FROM public.team t
  WHERE t.agency_id = p_agency_id AND t.category = ''agency''
    AND COALESCE(t.role_level, '''') <> ''Owner''
    AND t.is_admin_backoffice = false
    AND (t.archived_at IS NULL OR t.archived_at > v_week_start::timestamptz);',
    'FROM public.get_expected_teammates(p_agency_id, ''compensation'', v_week_start) et;'
  );

  IF v_updated_def = v_current_def THEN
    RAISE EXCEPTION 'Scan 1 replacement did not match. Aborting.';
  END IF;

  -- ─── Scan 2: v_hours_rows (LEFT JOIN h_pivot) ─────────────────────
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

  IF v_updated_def = v_current_def THEN
    RAISE EXCEPTION 'Scan 2 replacement did not match. Aborting.';
  END IF;

  -- ─── Scan 3: v_activity_rows (LEFT JOIN wctd + requirements) ──────
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

  IF v_updated_def = v_current_def THEN
    RAISE EXCEPTION 'Scan 3 replacement did not match. Aborting.';
  END IF;

  -- ─── Scan 4: payroll_calc CTE (4-space indent) ─────────────────────
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

  IF v_updated_def = v_current_def THEN
    RAISE EXCEPTION 'Scan 4 replacement did not match. Aborting.';
  END IF;

  -- Sanity: no more hand-rolled admin filters should remain
  v_hits := (length(v_updated_def) - length(replace(v_updated_def, 'is_admin_backoffice', ''))) / length('is_admin_backoffice');
  IF v_hits <> 0 THEN
    RAISE EXCEPTION 'Expected 0 remaining is_admin_backoffice references, found %', v_hits;
  END IF;

  EXECUTE v_updated_def;

  RAISE NOTICE 'compose_weekly_cpr_html: all 4 roster scans routed through get_expected_teammates(compensation, v_week_start)';
END $mig$;
