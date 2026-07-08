-- Tier-3 DRY: compute_weekly_comp_residual_pool roster CTE -> get_expected_teammates.
-- Applied 2026-07-08. Parity verified byte-exact against baseline across all 4
-- team members on every column (base, comm, bonus, total, sp%, wh%).
--
-- Only change: the roster CTE at the top of the function.
-- Applied via DO block that fetches pg_get_functiondef, does surgical replace,
-- and re-EXECUTEs -- same pattern as compose_weekly_cpr_html sibling migration
-- and Tier-4 anchor fix. Preserves the full 11KB body without inline reproduction.

DO $mig$
DECLARE
  v_current_def text;
  v_updated_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_current_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'compute_weekly_comp_residual_pool';

  IF v_current_def IS NULL THEN
    RAISE EXCEPTION 'compute_weekly_comp_residual_pool not found in pg_proc';
  END IF;

  -- Original hand-rolled roster CTE
  v_updated_def := replace(v_current_def,
    'WITH roster AS (
    SELECT t.id, t.first_name, t.last_name, t.role, t.role_category, t.role_level,
           t.pay_type, t.pay_rate, t.work_location, t.start_date,
           t.license_pc, t.license_lh, t.license_ips,
           t.weekly_health_benefit_agency_paid
    FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND t.category = ''agency''
      AND t.is_admin_backoffice = false
      AND COALESCE(t.role_level, '''') <> ''Owner''
      AND t.is_active = true
  )',
    'WITH roster AS (
    -- Canonical roster (Tier-3 DRY 2026-07-08). Was hand-rolled agency non-Owner active non-admin.
    SELECT et.team_id AS id, et.first_name, et.last_name, et.role, et.role_category, et.role_level,
           t.pay_type, t.pay_rate, t.work_location, et.start_date,
           t.license_pc, t.license_lh, t.license_ips,
           t.weekly_health_benefit_agency_paid
    FROM public.get_expected_teammates(p_agency_id, ''time_off_participant'', p_week_end_date) et
    JOIN public.team t ON t.id = et.team_id
  )'
  );

  IF v_updated_def = v_current_def THEN
    -- Idempotent: already refactored. Skip.
    RAISE NOTICE 'roster CTE already using canonical -- no change';
    RETURN;
  END IF;

  EXECUTE v_updated_def;
END $mig$;
