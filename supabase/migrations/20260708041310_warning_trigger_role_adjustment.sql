-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 04:13:10 UTC (ledger name: warning_trigger_role_adjustment) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708041310.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- ============================================================================
-- Warning trigger role adjustment — 2026-07-08
-- ============================================================================
-- Retention roles (role_category = 'Retention') get bar × 0.25 to reflect that
-- their primary contribution is service/retention, not direct production. The
-- 25% floor keeps SOME production expectation on the books.
-- All other roles remain at bar × 1.00 (production is their job).
-- ============================================================================

DROP FUNCTION IF EXISTS public.compute_warning_trigger(uuid, date);

CREATE OR REPLACE FUNCTION public.compute_warning_trigger(p_agency_id uuid, p_week_end_date date)
 RETURNS TABLE(
   team_member_id uuid,
   full_name text,
   role text,
   role_category text,
   role_production_weight numeric,
   annual_base numeric,
   tenure_multiplier numeric,
   warning_bar_full numeric,
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
DECLARE
  v_year                int := EXTRACT(YEAR FROM p_week_end_date)::int;
  v_burden_multiplier   CONSTANT numeric := 0.08;
  v_pc_base_rate        CONSTANT numeric := 0.08;
  v_retention_role_wt   CONSTANT numeric := 0.25;
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
    SELECT t.id, t.first_name, t.last_name, t.role, t.role_category,
      t.pay_type, t.pay_rate, t.start_date,
      CASE WHEN t.role_category = 'Retention' THEN v_retention_role_wt ELSE 1.00 END AS c_role_prod_wt
    FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND t.category = 'agency'
      AND t.is_admin_backoffice = false
      AND COALESCE(t.role_level, '') <> 'Owner'
      AND t.is_active = true
  ),
  base_calc AS (
    SELECT r.id, r.first_name || ' ' || r.last_name AS full_name,
      r.role, r.role_category, r.c_role_prod_wt,
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
      COALESCE(SUM(CASE WHEN pp.line_of_business IN ('Auto','Fire') THEN pp.premium_issued END), 0) AS pc_prem,
      COALESCE(SUM(CASE WHEN pp.line_of_business IN ('Life','Health') THEN pp.premium_issued END), 0) AS lh_prem
    FROM public.producer_production pp
    WHERE pp.agency_id = p_agency_id
      AND pp.period_year = v_year
      AND v_month_start IS NOT NULL
      AND pp.period_month BETWEEN v_month_start AND v_month_end
    GROUP BY pp.team_member_id
  ),
  final AS (
    SELECT
      b.id, b.full_name, b.role, b.role_category, b.c_role_prod_wt,
      b.c_annual_base, b.c_tenure_mult,
      b.c_annual_base * b.c_tenure_mult * (1 + v_burden_multiplier) AS warning_bar_full,
      b.c_annual_base * b.c_tenure_mult * (1 + v_burden_multiplier) * b.c_role_prod_wt AS warning_bar_adjusted,
      COALESCE(tp.pc_prem, 0) AS pc_prem,
      COALESCE(tp.lh_prem, 0) AS lh_prem,
      COALESCE(tp.pc_prem, 0) * v_pc_base_rate + COALESCE(tp.lh_prem, 0) * v_lh_blended_rate AS q_agency_comm_stripped
    FROM base_calc b
    LEFT JOIN trailing_prem tp ON tp.team_member_id = b.id
  )
  SELECT
    f.id, f.full_name, f.role, f.role_category,
    ROUND(f.c_role_prod_wt, 4),
    ROUND(f.c_annual_base, 2),
    ROUND(f.c_tenure_mult, 4),
    ROUND(f.warning_bar_full, 2),
    ROUND(f.warning_bar_adjusted, 2),
    v_trailing_q,
    ROUND(f.pc_prem, 2),
    ROUND(f.lh_prem, 2),
    ROUND(f.q_agency_comm_stripped, 2),
    ROUND(f.q_agency_comm_stripped * 4.0, 2),
    CASE WHEN f.warning_bar_adjusted > 0
         THEN ROUND((f.q_agency_comm_stripped * 4.0 / f.warning_bar_adjusted) * 100, 2)
         ELSE NULL END,
    CASE
      WHEN f.warning_bar_adjusted <= 0 THEN 'na'
      WHEN f.q_agency_comm_stripped * 4.0 >= f.warning_bar_adjusted THEN 'green'
      WHEN f.q_agency_comm_stripped * 4.0 >= f.warning_bar_adjusted * 0.8 THEN 'yellow'
      ELSE 'red'
    END,
    jsonb_build_object(
      'week_end_date', p_week_end_date,
      'burden_multiplier', v_burden_multiplier,
      'pc_base_rate', v_pc_base_rate,
      'lh_blended_rate', v_lh_blended_rate,
      'smvc_rate_pc', v_smvc_rate_pc,
      'role', f.role,
      'role_category', f.role_category,
      'role_production_weight', ROUND(f.c_role_prod_wt, 4),
      'role_adjustment_note', 'Retention roles: bar × 0.25 (75% credit for service/retention contribution). All others: bar × 1.00.',
      'trailing_q_num', v_trailing_q,
      'trailing_q_months', jsonb_build_array(v_month_start, v_month_end),
      'trailing_q_pc_prem', ROUND(f.pc_prem, 2),
      'trailing_q_lh_prem', ROUND(f.lh_prem, 2),
      'annual_base', ROUND(f.c_annual_base, 2),
      'tenure_multiplier', ROUND(f.c_tenure_mult, 4),
      'ramped_base', ROUND(f.c_annual_base * f.c_tenure_mult, 2),
      'warning_bar_full', ROUND(f.warning_bar_full, 2),
      'warning_bar_adjusted', ROUND(f.warning_bar_adjusted, 2),
      'warning_bar_formula', '(annual_base × tenure_mult) × 1.08 × role_production_weight',
      'warning_actual_formula', '(pc_prem × 0.08 + lh_prem × blended_rate) × 4',
      'thresholds', jsonb_build_object('green_min_pct', 100, 'yellow_min_pct', 80)
    )
  FROM final f
  ORDER BY f.full_name;
END;
$function$;

-- Create view for current-week warning trigger data (used by UI)
CREATE OR REPLACE VIEW public.v_warning_trigger_current AS
SELECT * FROM public.compute_warning_trigger(
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  (CURRENT_DATE + ((6 - EXTRACT(DOW FROM CURRENT_DATE)::int + 7) % 7)::int)::date
);

COMMENT ON VIEW public.v_warning_trigger_current IS
  'Wraps compute_warning_trigger for the current upcoming Saturday week-end. Used by HRPeople UI.';

COMMENT ON FUNCTION public.compute_warning_trigger IS
  'Per-person weekly production-vs-cost check. Bar = (annual_base × tenure_mult) × 1.08 × role_production_weight. Retention roles get 0.25 weight; others 1.00. Actual = trailing complete quarter agency commissions attributable × 4. See op-rule "New team integration + Growth budget" rule id="warning_trigger".';
