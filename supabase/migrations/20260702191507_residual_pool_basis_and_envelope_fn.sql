-- Residual-pool comp Phase 1: compute pool basis + weekly envelope
-- Locked design per operational_rule "Team comp — residual-pool design (7/11/2026 rollout) + ramp schedule"
--
-- Basis = P&C base (stripped) + L&H base (unstripped) + on-time SMVC $ + on-time Scorecard $
-- Envelope = pool_pct (from team_comp_pool_schedule) x (basis / 52)
--
-- Pulls live from comp_recap + agency + on-time SMVC/Scorecard canonical functions.
-- Never trusts stored basis numbers (per compensation_data_freshness principle).

CREATE OR REPLACE FUNCTION public.compute_pool_basis_and_envelope(
  p_agency_id       uuid,
  p_week_end_date   date
) RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $function$
DECLARE
  v_year              int  := EXTRACT(YEAR FROM p_week_end_date)::int;
  v_smvc_rate_pc      numeric;      -- agency's currently-applied SMVC rate (e.g. 0.0241)
  v_strip_factor      numeric;      -- 8 / (8 + applied_smvc_pct_in_pp), e.g. 8/10.41

  v_pc_gross_ytd      numeric;      -- comp_recap: auto_new + auto_renewal + fire_new + fire_renewal
  v_lh_ytd            numeric;      -- comp_recap: life_new + life_renewal + health_new + health_renewal
  v_days_elapsed      int;
  v_annualization     numeric;      -- 365 / days_elapsed

  v_pc_gross_annual   numeric;
  v_pc_stripped_annual numeric;
  v_lh_annual         numeric;

  v_ytd_snap          record;
  v_smvc              jsonb;
  v_on_time_smvc_pct  numeric;
  v_pc_prod_actual    numeric;
  v_on_time_smvc_dol  numeric;

  v_scorecard         jsonb;
  v_on_time_scc_dol   numeric;

  v_total_basis       numeric;
  v_pool_pct_row      record;
  v_pool_pct          numeric;
  v_weekly_envelope   numeric;
  v_annual_envelope   numeric;
BEGIN
  ------------------------------------------------------------------
  -- 1. Applied SMVC rate + strip factor
  ------------------------------------------------------------------
  SELECT smvc_rate_pc INTO v_smvc_rate_pc
  FROM public.agency WHERE id = p_agency_id;

  -- Strip formula: pc_base = pc_gross * 8 / (8 + applied_smvc_pct_in_pp)
  -- applied SMVC stored as decimal (0.0241) -> in percentage points that's 2.41
  v_strip_factor := 8.0 / (8.0 + (v_smvc_rate_pc * 100.0));

  ------------------------------------------------------------------
  -- 2. YTD comp_recap base commissions (through the ~last-completed month)
  ------------------------------------------------------------------
  SELECT
    COALESCE(SUM(CASE WHEN comp_category IN ('auto_new','auto_renewal','fire_new','fire_renewal')
                      THEN amount END), 0),
    COALESCE(SUM(CASE WHEN comp_category IN ('life_new','life_renewal','health_new','health_renewal')
                      THEN amount END), 0)
  INTO v_pc_gross_ytd, v_lh_ytd
  FROM public.comp_recap
  WHERE agency_id = p_agency_id AND period_year = v_year;

  ------------------------------------------------------------------
  -- 3. Annualization (365 / days elapsed in year through week_end_date)
  ------------------------------------------------------------------
  v_days_elapsed := GREATEST(1, (p_week_end_date - (v_year || '-01-01')::date)::int + 1);
  v_annualization := 365.0 / v_days_elapsed::numeric;

  v_pc_gross_annual    := v_pc_gross_ytd * v_annualization;
  v_pc_stripped_annual := v_pc_gross_annual * v_strip_factor;
  v_lh_annual          := v_lh_ytd * v_annualization;

  ------------------------------------------------------------------
  -- 4. On-time SMVC $ (dollars, not rate)
  ------------------------------------------------------------------
  SELECT * INTO v_ytd_snap
  FROM public.agency_snapshot
  WHERE agency_id = p_agency_id
    AND snapshot_date <= p_week_end_date
    AND auto_new_ytd IS NOT NULL
  ORDER BY snapshot_date DESC LIMIT 1;

  IF FOUND THEN
    v_smvc := public.compute_on_time_smvc_with_better_of(
      p_agency_id, v_year,
      COALESCE(v_ytd_snap.auto_new_ytd, 0) + COALESCE(v_ytd_snap.fire_new_ytd, 0),
      COALESCE(v_ytd_snap.auto_new_ytd, 0) - COALESCE(v_ytd_snap.auto_lost_ytd, 0),
      COALESCE(v_ytd_snap.fire_new_ytd, 0) - COALESCE(v_ytd_snap.fire_lost_ytd, 0),
      COALESCE(v_ytd_snap.life_paid_for_premium_ytd, 0),
      COALESCE(v_ytd_snap.ips_new_money_ytd, 0),
      p_week_end_date
    );
    v_on_time_smvc_pct := NULLIF(v_smvc->>'applied_smvc_decimal','')::numeric;
    -- SMVC $ = rate * P&C production actual (annualized where the SMVC calc uses it)
    v_pc_prod_actual   := NULLIF(v_smvc->>'pc_production_annualized','')::numeric;
    v_on_time_smvc_dol := COALESCE(v_on_time_smvc_pct, 0) * COALESCE(v_pc_prod_actual, 0);
  ELSE
    v_smvc := NULL;
    v_on_time_smvc_pct := NULL;
    v_pc_prod_actual := NULL;
    v_on_time_smvc_dol := 0;
  END IF;

  ------------------------------------------------------------------
  -- 5. On-time Scorecard $
  ------------------------------------------------------------------
  v_scorecard := public.compute_scorecard_bonus(p_agency_id, p_week_end_date);
  v_on_time_scc_dol := COALESCE(NULLIF(v_scorecard->>'bonus_projected','')::numeric, 0);

  ------------------------------------------------------------------
  -- 6. Total basis + pool_pct + envelope
  ------------------------------------------------------------------
  v_total_basis := v_pc_stripped_annual + v_lh_annual + v_on_time_smvc_dol + v_on_time_scc_dol;

  SELECT pool_pct, phase, basis_regime, plan_note
  INTO v_pool_pct_row
  FROM public.team_comp_pool_schedule
  WHERE agency_id = p_agency_id AND week_end_date = p_week_end_date
  LIMIT 1;

  v_pool_pct        := v_pool_pct_row.pool_pct;
  v_annual_envelope := (v_pool_pct / 100.0) * v_total_basis;
  v_weekly_envelope := v_annual_envelope / 52.0;

  RETURN jsonb_build_object(
    'agency_id',       p_agency_id,
    'week_end_date',   p_week_end_date,
    'basis', jsonb_build_object(
      'pc_gross_ytd',           ROUND(v_pc_gross_ytd, 2),
      'pc_gross_annualized',    ROUND(v_pc_gross_annual, 2),
      'strip_factor',           ROUND(v_strip_factor, 5),
      'pc_stripped_annualized', ROUND(v_pc_stripped_annual, 2),
      'lh_ytd',                 ROUND(v_lh_ytd, 2),
      'lh_annualized',          ROUND(v_lh_annual, 2),
      'on_time_smvc_pct',       v_on_time_smvc_pct,
      'on_time_smvc_dollars',   ROUND(v_on_time_smvc_dol, 2),
      'on_time_scorecard_dollars', ROUND(v_on_time_scc_dol, 2),
      'total_basis_annual',     ROUND(v_total_basis, 2),
      'smvc_rate_pc_applied',   v_smvc_rate_pc,
      'days_elapsed_in_year',   v_days_elapsed,
      'annualization_factor',   ROUND(v_annualization, 5)
    ),
    'schedule', jsonb_build_object(
      'pool_pct',      v_pool_pct,
      'phase',         v_pool_pct_row.phase,
      'basis_regime',  v_pool_pct_row.basis_regime,
      'plan_note',     v_pool_pct_row.plan_note
    ),
    'envelope', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_envelope, 2),
      'weekly_dollars', ROUND(v_weekly_envelope, 2)
    ),
    'computed_at', now()
  );
END;
$function$;

COMMENT ON FUNCTION public.compute_pool_basis_and_envelope(uuid,date) IS
  'Residual-pool comp Phase 1: pool basis (SMVC-stripped P&C + L&H + on-time SMVC$ + on-time Scorecard$) + weekly envelope from team_comp_pool_schedule. Pulls comp_recap + agency + on-time helpers live per compensation_data_freshness principle.';