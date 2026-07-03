CREATE OR REPLACE FUNCTION public.compute_pool_basis_and_envelope(
  p_agency_id       uuid,
  p_week_end_date   date
) RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $function$
DECLARE
  v_year              int  := EXTRACT(YEAR FROM p_week_end_date)::int;
  v_smvc_rate_pc      numeric;
  v_strip_factor      numeric;

  v_pc_gross_ytd      numeric;
  v_lh_ytd            numeric;
  v_days_elapsed      int;
  v_annualization     numeric;

  v_pc_gross_annual   numeric;
  v_pc_stripped_annual numeric;
  v_lh_annual         numeric;

  v_ytd_snap          record;
  v_book_snap_date    date;
  v_book_auto_prem    numeric;
  v_book_fire_prem    numeric;
  v_smvc              jsonb;
  v_on_time_smvc_pct  numeric;
  v_pc_book_premium   numeric;
  v_on_time_smvc_dol  numeric;

  v_scorecard         jsonb;
  v_on_time_scc_dol   numeric;

  v_total_basis       numeric;
  v_pool_pct_row      record;
  v_pool_pct          numeric;
  v_weekly_envelope   numeric;
  v_annual_envelope   numeric;
BEGIN
  SELECT smvc_rate_pc INTO v_smvc_rate_pc FROM public.agency WHERE id = p_agency_id;
  v_strip_factor := 8.0 / (8.0 + (v_smvc_rate_pc * 100.0));

  SELECT
    COALESCE(SUM(CASE WHEN comp_category IN ('auto_new','auto_renewal','fire_new','fire_renewal') THEN amount END), 0),
    COALESCE(SUM(CASE WHEN comp_category IN ('life_new','life_renewal','health_new','health_renewal') THEN amount END), 0)
  INTO v_pc_gross_ytd, v_lh_ytd
  FROM public.comp_recap
  WHERE agency_id = p_agency_id AND period_year = v_year;

  v_days_elapsed  := GREATEST(1, (p_week_end_date - (v_year || '-01-01')::date)::int + 1);
  v_annualization := 365.0 / v_days_elapsed::numeric;
  v_pc_gross_annual    := v_pc_gross_ytd * v_annualization;
  v_pc_stripped_annual := v_pc_gross_annual * v_strip_factor;
  v_lh_annual          := v_lh_ytd * v_annualization;

  SELECT * INTO v_ytd_snap
  FROM public.agency_snapshot
  WHERE agency_id = p_agency_id AND snapshot_date <= p_week_end_date AND auto_new_ytd IS NOT NULL
  ORDER BY snapshot_date DESC LIMIT 1;

  SELECT snapshot_date, auto_premium, fire_premium
  INTO v_book_snap_date, v_book_auto_prem, v_book_fire_prem
  FROM public.agency_snapshot
  WHERE agency_id = p_agency_id AND snapshot_date <= p_week_end_date AND auto_premium IS NOT NULL
  ORDER BY snapshot_date DESC LIMIT 1;

  v_pc_book_premium := COALESCE(v_book_auto_prem, 0) + COALESCE(v_book_fire_prem, 0);

  IF v_ytd_snap.snapshot_date IS NOT NULL THEN
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
    v_on_time_smvc_dol := COALESCE(v_on_time_smvc_pct, 0) * v_pc_book_premium;
  ELSE
    v_smvc := NULL;
    v_on_time_smvc_pct := NULL;
    v_on_time_smvc_dol := 0;
  END IF;

  v_scorecard := public.compute_scorecard_bonus(p_agency_id, p_week_end_date);
  v_on_time_scc_dol := COALESCE(NULLIF(v_scorecard->>'bonus_projected','')::numeric, 0);

  v_total_basis := v_pc_stripped_annual + v_lh_annual + v_on_time_smvc_dol + v_on_time_scc_dol;

  SELECT pool_pct, phase, basis_regime, plan_note INTO v_pool_pct_row
  FROM public.team_comp_pool_schedule
  WHERE agency_id = p_agency_id AND week_end_date = p_week_end_date LIMIT 1;

  v_pool_pct        := v_pool_pct_row.pool_pct;
  v_annual_envelope := (v_pool_pct / 100.0) * v_total_basis;
  v_weekly_envelope := v_annual_envelope / 52.0;

  RETURN jsonb_build_object(
    'agency_id',     p_agency_id,
    'week_end_date', p_week_end_date,
    'basis', jsonb_build_object(
      'pc_gross_ytd',              ROUND(v_pc_gross_ytd, 2),
      'pc_gross_annualized',       ROUND(v_pc_gross_annual, 2),
      'strip_factor',              ROUND(v_strip_factor, 5),
      'pc_stripped_annualized',    ROUND(v_pc_stripped_annual, 2),
      'lh_ytd',                    ROUND(v_lh_ytd, 2),
      'lh_annualized',             ROUND(v_lh_annual, 2),
      'pc_book_premium',           v_pc_book_premium,
      'on_time_smvc_pct',          v_on_time_smvc_pct,
      'on_time_smvc_dollars',      ROUND(v_on_time_smvc_dol, 2),
      'on_time_scorecard_dollars', ROUND(v_on_time_scc_dol, 2),
      'total_basis_annual',        ROUND(v_total_basis, 2),
      'smvc_rate_pc_applied',      v_smvc_rate_pc,
      'days_elapsed_in_year',      v_days_elapsed,
      'annualization_factor',      ROUND(v_annualization, 5),
      'ytd_snapshot_date',         v_ytd_snap.snapshot_date,
      'book_snapshot_date',        v_book_snap_date
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