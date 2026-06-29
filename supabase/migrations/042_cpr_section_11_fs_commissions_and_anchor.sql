-- Migration 042: get_cpr_section_11 — FS Commissions input + annualization anchor.
--
-- Two fixes in one function rewrite:
--   1) FS Commissions input wired to public.compute_fs_commissions_ytd
--      (Life new + Life renewal commission $ from comp_recap). Previously fed
--      life_paid_for_premium_ytd which is PREMIUM — wrong unit for the SMVC
--      FS bucket spec (which is COMMISSIONS).
--   2) p_as_of_date passed to compute_on_time_smvc_with_better_of now anchored
--      to LEAST(week_ending_date, snapshot_date) so annualization doesn't stretch
--      stale YTD across extra calendar days and understate pace.
--
-- compute_scorecard_bonus self-anchors internally (migration 041) — caller still
-- passes p_week_ending_date.
--
-- New fields in returned JSONB: effective_as_of_date, smvc.fs_commissions_ytd.

CREATE OR REPLACE FUNCTION public.get_cpr_section_11(p_agency_id uuid, p_week_ending_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_program_year      int := EXTRACT(YEAR FROM p_week_ending_date)::int;
  v_snap              record; v_book record; v_report record;
  v_smvc              jsonb;
  v_smvc_on_time      numeric; v_smvc_current numeric; v_smvc_applied numeric;
  v_smvc_dollar_diff  numeric; v_pc_premium numeric;
  v_pc_production     numeric; v_auto_gain numeric; v_fire_gain numeric;
  v_fs_credits        numeric;   -- now FS Commissions (Life new+renewal $)
  v_ips_activity      numeric;
  v_effective_as_of   date;
  v_scorecard         jsonb;  v_sc_on_time numeric;
  v_sc_last_year      numeric; v_sc_dollar_diff numeric;
  v_cycle             record;
  v_curr_q_end        date;
  v_prize_cart_budget numeric; v_wtq_trip_budget numeric;
  v_wtq_scaling       numeric := 1.0;
  v_has_overrides     boolean := false;
BEGIN
  SELECT * INTO v_snap FROM public.agency_snapshot
  WHERE agency_id=p_agency_id AND snapshot_date<=p_week_ending_date AND auto_new_ytd IS NOT NULL
  ORDER BY snapshot_date DESC LIMIT 1;

  SELECT
    auto_new_ytd_manual, auto_lost_ytd_manual,
    fire_new_ytd_manual, fire_lost_ytd_manual,
    life_paid_for_count_ytd_manual, life_paid_for_premium_ytd_manual
  INTO v_report
  FROM public.weekly_cpr_reports
  WHERE agency_id=p_agency_id AND week_ending_date=p_week_ending_date;

  v_has_overrides := (v_report.auto_new_ytd_manual IS NOT NULL
                   OR v_report.auto_lost_ytd_manual IS NOT NULL
                   OR v_report.fire_new_ytd_manual IS NOT NULL
                   OR v_report.fire_lost_ytd_manual IS NOT NULL
                   OR v_report.life_paid_for_count_ytd_manual IS NOT NULL
                   OR v_report.life_paid_for_premium_ytd_manual IS NOT NULL);

  IF v_snap.snapshot_date IS NOT NULL OR v_has_overrides THEN
    v_pc_production := COALESCE(v_report.auto_new_ytd_manual, v_snap.auto_new_ytd, 0)
                     + COALESCE(v_report.fire_new_ytd_manual, v_snap.fire_new_ytd, 0);
    v_auto_gain     := COALESCE(v_report.auto_new_ytd_manual,  v_snap.auto_new_ytd,  0)
                     - COALESCE(v_report.auto_lost_ytd_manual, v_snap.auto_lost_ytd, 0);
    v_fire_gain     := COALESCE(v_report.fire_new_ytd_manual,  v_snap.fire_new_ytd,  0)
                     - COALESCE(v_report.fire_lost_ytd_manual, v_snap.fire_lost_ytd, 0);

    -- FS Commissions (Life new + Life renewal) from comp_recap.
    -- Health excluded per operational rule. Pacific Life VUL flows through
    -- life_new/life_renewal categories.
    v_fs_credits    := public.compute_fs_commissions_ytd(p_agency_id, p_week_ending_date);
    v_ips_activity  := COALESCE(v_snap.ips_new_money_ytd, 0);

    -- Anchor annualization to LEAST(target week, snapshot date). Overrides reflect
    -- the target week's data; snapshot reflects its own date. comp_recap commissions
    -- run on a monthly cadence and are accumulated through the as-of month — already
    -- aligned with the week-ending date for annualization purposes.
    IF v_has_overrides THEN
      v_effective_as_of := p_week_ending_date;
    ELSE
      v_effective_as_of := LEAST(p_week_ending_date, v_snap.snapshot_date);
    END IF;

    v_smvc := public.compute_on_time_smvc_with_better_of(
      p_agency_id, v_program_year, v_pc_production, v_auto_gain, v_fire_gain,
      v_fs_credits, v_ips_activity, v_effective_as_of);
    v_smvc_on_time := NULLIF(v_smvc->>'applied_smvc_decimal','')::numeric;
    v_smvc_current := NULLIF(v_smvc->>'capped_smvc_decimal','')::numeric;
  END IF;

  SELECT smvc_rate_pc INTO v_smvc_applied FROM public.agency WHERE id=p_agency_id;

  SELECT auto_premium, fire_premium INTO v_book FROM public.agency_snapshot
  WHERE agency_id=p_agency_id AND snapshot_date<=p_week_ending_date AND auto_premium IS NOT NULL
  ORDER BY snapshot_date DESC LIMIT 1;
  IF FOUND THEN v_pc_premium := COALESCE(v_book.auto_premium,0) + COALESCE(v_book.fire_premium,0); END IF;

  IF v_smvc_on_time IS NOT NULL AND v_smvc_applied IS NOT NULL AND v_pc_premium IS NOT NULL THEN
    v_smvc_dollar_diff := (v_smvc_on_time - v_smvc_applied) * v_pc_premium;
  END IF;

  v_scorecard := public.compute_scorecard_bonus(p_agency_id, p_week_ending_date);
  v_sc_on_time   := NULLIF(v_scorecard->>'bonus_projected','')::numeric;
  v_sc_last_year := NULLIF(v_scorecard->>'last_year_bonus','')::numeric;
  IF v_sc_on_time IS NOT NULL AND v_sc_last_year IS NOT NULL THEN
    v_sc_dollar_diff := v_sc_on_time - v_sc_last_year;
  END IF;

  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, p_week_ending_date);
  v_curr_q_end := v_cycle.cycle_end;

  IF v_sc_on_time IS NOT NULL THEN
    v_prize_cart_budget := 0.01 * v_sc_on_time;
    v_wtq_trip_budget   := 0.01 * v_sc_on_time * v_wtq_scaling;
  END IF;

  RETURN jsonb_build_object(
    'program_year', v_program_year, 'week_ending_date', p_week_ending_date,
    'snapshot_date', v_snap.snapshot_date,
    'effective_as_of_date', v_effective_as_of,
    'has_manual_overrides', v_has_overrides,
    'smvc', jsonb_build_object(
      'on_time', v_smvc_on_time, 'last_wk', NULL, 'last_q', NULL,
      'last_year', v_smvc_applied, 'applied', v_smvc_applied,
      'dollar_diff', v_smvc_dollar_diff,
      'fs_commissions_ytd', v_fs_credits,
      'bands_complete', COALESCE((v_smvc->>'bands_complete')::boolean, false),
      'pc_premium_basis', v_pc_premium, 'computed_breakdown', v_smvc),
    'scorecard_bonus', jsonb_build_object(
      'on_time', v_sc_on_time, 'last_wk', NULL, 'last_q', NULL,
      'last_year', v_sc_last_year, 'dollar_diff', v_sc_dollar_diff,
      'bonus_ytd', (v_scorecard->>'bonus_ytd')::numeric,
      'bonus_rate', (v_scorecard->>'bonus_rate')::numeric,
      'total_points', (v_scorecard->>'total_points')::numeric,
      'computed_breakdown', v_scorecard),
    'prize_cart_budget', jsonb_build_object(
      'value', v_prize_cart_budget,
      'formula', '1% × current OT Scorecard projection',
      'curr_q_end', v_curr_q_end,
      'curr_q_scorecard', v_sc_on_time,
      'note', CASE WHEN v_prize_cart_budget IS NULL
                   THEN 'no Scorecard projection available' ELSE NULL END),
    'wtq_trip_budget', jsonb_build_object(
      'value', v_wtq_trip_budget,
      'formula', '1% × current OT Scorecard projection × (winner/leader scaling)',
      'curr_q_end', v_curr_q_end,
      'curr_q_scorecard', v_sc_on_time,
      'scaling', v_wtq_scaling,
      'note', CASE WHEN v_wtq_trip_budget IS NULL THEN 'no Scorecard projection available'
                   WHEN v_wtq_scaling = 1.0
                   THEN 'mid-cycle — scaling defaults to 1.0 until winner ≠ leader is recorded at cycle close'
                   ELSE NULL END),
    'computed_at', now());
END;
$function$;
