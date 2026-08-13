-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 03:44:26 UTC (ledger name: warning_trigger_wire) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708034426.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- ============================================================================
-- Warning trigger wire — 2026-07-08
-- ============================================================================
-- Per-person weekly check: production actual vs fully-loaded ramped cost.
-- Design from op-rule "New team integration + Growth budget" rule id="warning_trigger":
--   bar    = (annual_base × tenure_multiplier) × 1.08
--   actual = trailing 13-wk agency commissions × 4, SMVC-stripped (2026: × 8/10.41)
--   🟢 actual ≥ 100% bar; 🟡 80-99%; 🔴 <80%
--   Role-agnostic. Stays live past Week 52.
-- Storage: new columns on weekly_cpr_team_detail. Wired via write_weekly_comp_v2.
-- ============================================================================

-- 1. Add warning trigger columns to weekly_cpr_team_detail
ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS warning_bar NUMERIC,
  ADD COLUMN IF NOT EXISTS warning_actual_annual NUMERIC,
  ADD COLUMN IF NOT EXISTS warning_pct NUMERIC,
  ADD COLUMN IF NOT EXISTS warning_status TEXT,
  ADD COLUMN IF NOT EXISTS warning_diag JSONB;

COMMENT ON COLUMN public.weekly_cpr_team_detail.warning_bar IS
  'Warning trigger fully-loaded ramped cost = (annual_base × tenure_multiplier) × 1.08';
COMMENT ON COLUMN public.weekly_cpr_team_detail.warning_actual_annual IS
  'Warning trigger annualized actual = trailing complete quarter''s commissions × 4 × SMVC-strip factor (2026: 8/10.41)';
COMMENT ON COLUMN public.weekly_cpr_team_detail.warning_status IS
  'Warning trigger status: green (actual >= 100% of bar), yellow (80-99%), red (<80%), na (bar is 0)';

-- 2. Dedicated fn: compute_warning_trigger(agency_id, week_end_date)
--    Returns per-person warning trigger data for all active agency team.
CREATE OR REPLACE FUNCTION public.compute_warning_trigger(p_agency_id uuid, p_week_end_date date)
 RETURNS TABLE(
   team_member_id uuid,
   full_name text,
   annual_base numeric,
   tenure_multiplier numeric,
   warning_bar numeric,
   trailing_q_num int,
   trailing_q_comm_raw numeric,
   warning_actual_annual numeric,
   warning_pct numeric,
   warning_status text,
   diag jsonb
 )
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_year               int := EXTRACT(YEAR FROM p_week_end_date)::int;
  v_burden_multiplier  CONSTANT numeric := 0.08;
  v_smvc_strip_factor  CONSTANT numeric := 8.0/10.41;   -- 2026 factor; review annually
  v_trailing_q         int;
BEGIN
  -- Find latest realized quarter based on producer_production data for this year
  SELECT MAX(qn) INTO v_trailing_q
  FROM (
    SELECT ((period_month - 1) / 3) + 1 AS qn
    FROM public.producer_production
    WHERE agency_id = p_agency_id
      AND period_year = v_year
    GROUP BY ((period_month - 1) / 3) + 1
  ) q;

  RETURN QUERY
  WITH roster AS (
    SELECT t.id, t.first_name, t.last_name,
      t.pay_type, t.pay_rate, t.start_date
    FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND t.category = 'agency'
      AND t.is_admin_backoffice = false
      AND COALESCE(t.role_level, '') <> 'Owner'
      AND t.is_active = true
  ),
  base_calc AS (
    SELECT r.id,
      r.first_name || ' ' || r.last_name AS full_name,
      CASE
        WHEN r.pay_type = 'SALARY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 52
        WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 40 * 52
        ELSE 0
      END AS c_annual_base,
      LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - r.start_date)::numeric / 7.0) / 52.0)) AS c_tenure_mult
    FROM roster r
  ),
  trailing_comms AS (
    SELECT
      b.id AS tm_id,
      CASE
        WHEN v_trailing_q IS NULL OR v_trailing_q = 0 THEN 0
        ELSE COALESCE(
          (public.compute_person_commissions_quarterly(p_agency_id, b.id, v_year, v_trailing_q)->'commission'->>'total_commission')::numeric,
          0
        )
      END AS q_comm_raw
    FROM base_calc b
  ),
  final AS (
    SELECT
      b.id,
      b.full_name,
      b.c_annual_base,
      b.c_tenure_mult,
      b.c_annual_base * b.c_tenure_mult * (1 + v_burden_multiplier) AS warning_bar,
      COALESCE(tc.q_comm_raw, 0) AS q_comm_raw,
      COALESCE(tc.q_comm_raw, 0) * 4.0 * v_smvc_strip_factor AS warning_actual_annual
    FROM base_calc b
    LEFT JOIN trailing_comms tc ON tc.tm_id = b.id
  )
  SELECT
    f.id,
    f.full_name,
    ROUND(f.c_annual_base, 2),
    ROUND(f.c_tenure_mult, 4),
    ROUND(f.warning_bar, 2),
    v_trailing_q,
    ROUND(f.q_comm_raw, 2),
    ROUND(f.warning_actual_annual, 2),
    CASE WHEN f.warning_bar > 0
         THEN ROUND((f.warning_actual_annual / f.warning_bar) * 100, 2)
         ELSE NULL END,
    CASE
      WHEN f.warning_bar <= 0 THEN 'na'
      WHEN f.warning_actual_annual >= f.warning_bar THEN 'green'
      WHEN f.warning_actual_annual >= f.warning_bar * 0.8 THEN 'yellow'
      ELSE 'red'
    END,
    jsonb_build_object(
      'week_end_date',        p_week_end_date,
      'burden_multiplier',    v_burden_multiplier,
      'smvc_strip_factor',    v_smvc_strip_factor,
      'smvc_strip_note',      '2026 factor 8/10.41; review annually',
      'trailing_q_num',       v_trailing_q,
      'trailing_q_comm_raw',  ROUND(f.q_comm_raw, 2),
      'q_annualized_pre_strip', ROUND(f.q_comm_raw * 4.0, 2),
      'annual_base',          ROUND(f.c_annual_base, 2),
      'tenure_multiplier',    ROUND(f.c_tenure_mult, 4),
      'ramped_base',          ROUND(f.c_annual_base * f.c_tenure_mult, 2),
      'warning_bar_formula',  '(annual_base × tenure_multiplier) × 1.08',
      'warning_actual_formula', 'trailing_q_comm × 4 × (8/10.41)',
      'thresholds',           jsonb_build_object('green_min_pct', 100, 'yellow_min_pct', 80)
    )
  FROM final f
  ORDER BY f.full_name;
END;
$function$;

COMMENT ON FUNCTION public.compute_warning_trigger IS
  'Per-person weekly production-vs-cost check. Role-agnostic. Bar = (annual_base × tenure_mult) × 1.08. Actual = trailing complete quarter commissions × 4 × SMVC-strip factor. Status: green >= 100% of bar, yellow 80-99%, red < 80%. See op-rule "New team integration + Growth budget" rule id="warning_trigger".';

-- 3. Update write_weekly_comp_v2 to also write warning trigger fields
CREATE OR REPLACE FUNCTION public.write_weekly_comp_v2(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_rows_updated int := 0;
  v_wt_rows int := 0;
  v_report_id    uuid;
BEGIN
  SELECT id INTO v_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date
  LIMIT 1;

  IF v_report_id IS NULL THEN
    RETURN jsonb_build_object(
      'agency_id', p_agency_id, 'week_end_date', p_week_end_date,
      'rows_updated', 0,
      'note', 'no weekly_cpr_reports row exists for this week',
      'written_at', now()
    );
  END IF;

  -- Existing residual-pool write
  WITH src AS (
    SELECT * FROM public.compute_weekly_comp_residual_pool(p_agency_id, p_week_end_date)
  ),
  upd AS (
    UPDATE public.weekly_cpr_team_detail wctd
    SET
      base_salary_paid   = s.weekly_base_salary,
      commission_paid    = s.weekly_commission_projected,
      bonus_gross        = ROUND(s.annual_bonus_gross / 52.0, 2),
      health_subtracted  = ROUND(s.annual_health_subtracted / 52.0, 2),
      bonus_net          = s.weekly_bonus_net,
      residual_pool_diag = s.diagnostics
                           || jsonb_build_object(
                                'annual_base_salary',          s.annual_base_salary,
                                'annual_commission_projected', s.annual_commission_projected,
                                'annual_bonus_gross',          s.annual_bonus_gross,
                                'annual_health_subtracted',    s.annual_health_subtracted,
                                'annual_bonus_net',            s.annual_bonus_net,
                                'annual_total_comp',           s.annual_total_comp,
                                'ytd_sales_points',            s.ytd_sales_points,
                                'sales_points_share_pct',      s.sales_points_share_pct,
                                'weighted_hours_at_40',        s.weighted_hours_at_40,
                                'retention_hours_share_pct',   s.retention_hours_share_pct,
                                'person_share_pct',            s.person_share_pct),
      updated_at = now()
    FROM src s
    WHERE wctd.weekly_cpr_report_id = v_report_id
      AND wctd.team_member_id = s.team_member_id
    RETURNING wctd.id
  )
  SELECT COUNT(*) INTO v_rows_updated FROM upd;

  -- NEW: warning trigger write
  WITH wt AS (
    SELECT * FROM public.compute_warning_trigger(p_agency_id, p_week_end_date)
  ),
  wt_upd AS (
    UPDATE public.weekly_cpr_team_detail wctd
    SET
      warning_bar           = w.warning_bar,
      warning_actual_annual = w.warning_actual_annual,
      warning_pct           = w.warning_pct,
      warning_status        = w.warning_status,
      warning_diag          = w.diag,
      updated_at            = now()
    FROM wt w
    WHERE wctd.weekly_cpr_report_id = v_report_id
      AND wctd.team_member_id = w.team_member_id
    RETURNING wctd.id
  )
  SELECT COUNT(*) INTO v_wt_rows FROM wt_upd;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id, 'week_end_date', p_week_end_date,
    'weekly_cpr_report_id', v_report_id,
    'rows_updated', v_rows_updated,
    'warning_trigger_rows_updated', v_wt_rows,
    'written_at', now()
  );
END;
$function$;
