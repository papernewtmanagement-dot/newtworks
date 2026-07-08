-- ============================================================================
-- Warning trigger wire — 2026-07-08
-- ============================================================================
-- Per-person weekly production-vs-cost check for all active agency team members.
-- Design from op-rule "New team integration + Growth budget" rule id="warning_trigger":
--   bar    = (annual_base × tenure_multiplier) × 1.08
--   actual = trailing complete quarter agency commissions attributable to person, × 4
--            (pc_prem × 0.08 + lh_prem × agency.blended_rate_other)
--   🟢 actual >= 100% of bar; 🟡 80-99%; 🔴 < 80%; na = no bar (bad base)
--   Role-agnostic. Stays live past Week 52.
--
-- P&C attribution uses base 8% rate (ex-SMVC), matching pool_basis SMVC-strip
-- convention: strip_factor = 8 / (8 + smvc_rate_pc × 100). Equivalent to using
-- 8% directly on premium.
--
-- Storage: new columns on weekly_cpr_team_detail. Wired via write_weekly_comp_v2.
-- ============================================================================

ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS warning_bar NUMERIC,
  ADD COLUMN IF NOT EXISTS warning_actual_annual NUMERIC,
  ADD COLUMN IF NOT EXISTS warning_pct NUMERIC,
  ADD COLUMN IF NOT EXISTS warning_status TEXT,
  ADD COLUMN IF NOT EXISTS warning_diag JSONB;

COMMENT ON COLUMN public.weekly_cpr_team_detail.warning_bar IS
  'Warning trigger fully-loaded ramped cost = (annual_base × tenure_multiplier) × 1.08';
COMMENT ON COLUMN public.weekly_cpr_team_detail.warning_actual_annual IS
  'Warning trigger annualized actual = trailing complete quarter agency commissions × 4 (pc_prem × 0.08 + lh_prem × blended_rate)';
COMMENT ON COLUMN public.weekly_cpr_team_detail.warning_status IS
  'Warning trigger status: green (actual >= 100% of bar), yellow (80-99%), red (<80%), na (bar <= 0)';

DROP FUNCTION IF EXISTS public.compute_warning_trigger(uuid, date);

CREATE OR REPLACE FUNCTION public.compute_warning_trigger(p_agency_id uuid, p_week_end_date date)
 RETURNS TABLE(
   team_member_id uuid,
   full_name text,
   annual_base numeric,
   tenure_multiplier numeric,
   warning_bar numeric,
   trailing_q_num int,
   trailing_q_pc_premium numeric,
   trailing_q_lh_premium numeric,
   trailing_q_agency_comm_stripped numeric,
   warning_actual_annual numeric,
   warning_pct numeric,
   warning_status text,
   diag jsonb
 )
 LANGUAGE plpgsql
 STABLE
AS $function$
-- (Body applied via Supabase MCP; see pg_proc for canonical version.)
DECLARE
  v_year                int := EXTRACT(YEAR FROM p_week_end_date)::int;
  v_burden_multiplier   CONSTANT numeric := 0.08;
  v_pc_base_rate        CONSTANT numeric := 0.08;
  v_lh_blended_rate     numeric;
  v_smvc_rate_pc        numeric;
  v_trailing_q          int;
  v_month_start         int;
  v_month_end           int;
BEGIN
  SELECT smvc_rate_pc, blended_rate_other
  INTO v_smvc_rate_pc, v_lh_blended_rate
  FROM public.agency
  WHERE id = p_agency_id;

  IF v_lh_blended_rate IS NULL THEN v_lh_blended_rate := 0.09; END IF;

  SELECT MAX(qn) INTO v_trailing_q
  FROM (
    SELECT ((period_month - 1) / 3) + 1 AS qn
    FROM public.producer_production
    WHERE agency_id = p_agency_id AND period_year = v_year
    GROUP BY ((period_month - 1) / 3) + 1
  ) q;

  v_month_start := CASE WHEN v_trailing_q IS NULL THEN NULL ELSE (v_trailing_q - 1) * 3 + 1 END;
  v_month_end   := CASE WHEN v_trailing_q IS NULL THEN NULL ELSE v_trailing_q * 3 END;

  RETURN QUERY
  WITH roster AS (
    SELECT t.id, t.first_name, t.last_name, t.pay_type, t.pay_rate, t.start_date
    FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND t.category = 'agency'
      AND t.is_admin_backoffice = false
      AND COALESCE(t.role_level, '') <> 'Owner'
      AND t.is_active = true
  ),
  base_calc AS (
    SELECT r.id, r.first_name || ' ' || r.last_name AS full_name,
      CASE
        WHEN r.pay_type = 'SALARY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 52
        WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 40 * 52
        ELSE 0
      END AS c_annual_base,
      LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - r.start_date)::numeric / 7.0) / 52.0)) AS c_tenure_mult
    FROM roster r
  ),
  trailing_prem AS (
    SELECT
      pp.team_member_id,
      COALESCE(SUM(CASE WHEN pp.line_of_business IN (''Auto'',''Fire'') THEN pp.premium_issued END), 0) AS pc_prem,
      COALESCE(SUM(CASE WHEN pp.line_of_business IN (''Life'',''Health'') THEN pp.premium_issued END), 0) AS lh_prem
    FROM public.producer_production pp
    WHERE pp.agency_id = p_agency_id
      AND pp.period_year = v_year
      AND v_month_start IS NOT NULL
      AND pp.period_month BETWEEN v_month_start AND v_month_end
    GROUP BY pp.team_member_id
  ),
  final AS (
    SELECT
      b.id, b.full_name, b.c_annual_base, b.c_tenure_mult,
      b.c_annual_base * b.c_tenure_mult * (1 + v_burden_multiplier) AS warning_bar,
      COALESCE(tp.pc_prem, 0) AS pc_prem,
      COALESCE(tp.lh_prem, 0) AS lh_prem,
      COALESCE(tp.pc_prem, 0) * v_pc_base_rate + COALESCE(tp.lh_prem, 0) * v_lh_blended_rate AS q_agency_comm_stripped
    FROM base_calc b
    LEFT JOIN trailing_prem tp ON tp.team_member_id = b.id
  )
  SELECT
    f.id, f.full_name,
    ROUND(f.c_annual_base, 2),
    ROUND(f.c_tenure_mult, 4),
    ROUND(f.warning_bar, 2),
    v_trailing_q,
    ROUND(f.pc_prem, 2),
    ROUND(f.lh_prem, 2),
    ROUND(f.q_agency_comm_stripped, 2),
    ROUND(f.q_agency_comm_stripped * 4.0, 2),
    CASE WHEN f.warning_bar > 0
         THEN ROUND((f.q_agency_comm_stripped * 4.0 / f.warning_bar) * 100, 2)
         ELSE NULL END,
    CASE
      WHEN f.warning_bar <= 0 THEN ''na''
      WHEN f.q_agency_comm_stripped * 4.0 >= f.warning_bar THEN ''green''
      WHEN f.q_agency_comm_stripped * 4.0 >= f.warning_bar * 0.8 THEN ''yellow''
      ELSE ''red''
    END,
    jsonb_build_object(
      ''week_end_date'', p_week_end_date,
      ''burden_multiplier'', v_burden_multiplier,
      ''pc_base_rate'', v_pc_base_rate,
      ''lh_blended_rate'', v_lh_blended_rate,
      ''smvc_rate_pc'', v_smvc_rate_pc,
      ''trailing_q_num'', v_trailing_q,
      ''trailing_q_months'', jsonb_build_array(v_month_start, v_month_end),
      ''trailing_q_pc_prem'', ROUND(f.pc_prem, 2),
      ''trailing_q_lh_prem'', ROUND(f.lh_prem, 2),
      ''trailing_q_pc_comm'', ROUND(f.pc_prem * v_pc_base_rate, 2),
      ''trailing_q_lh_comm'', ROUND(f.lh_prem * v_lh_blended_rate, 2),
      ''annual_base'', ROUND(f.c_annual_base, 2),
      ''tenure_multiplier'', ROUND(f.c_tenure_mult, 4),
      ''ramped_base'', ROUND(f.c_annual_base * f.c_tenure_mult, 2),
      ''warning_bar_formula'', ''(annual_base × tenure_mult) × 1.08'',
      ''warning_actual_formula'', ''(pc_prem × 0.08 + lh_prem × blended_rate) × 4'',
      ''thresholds'', jsonb_build_object(''green_min_pct'', 100, ''yellow_min_pct'', 80)
    )
  FROM final f
  ORDER BY f.full_name;
END;
$function$;

COMMENT ON FUNCTION public.compute_warning_trigger IS
  ''Per-person weekly production-vs-cost check. Bar = (annual_base × tenure_mult) × 1.08. Actual = trailing complete quarter agency commissions attributable to the person (pc_prem × 0.08 + lh_prem × blended_rate), annualized × 4. See op-rule "New team integration + Growth budget" rule id="warning_trigger".'';

-- NOTE: write_weekly_comp_v2 was updated to also call compute_warning_trigger
-- and write warning_bar/warning_actual_annual/warning_pct/warning_status/warning_diag
-- to weekly_cpr_team_detail. Full body in pg_proc.
