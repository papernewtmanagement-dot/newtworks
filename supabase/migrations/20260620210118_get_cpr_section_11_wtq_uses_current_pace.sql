-- One-line fix: WtQ Trip "OT Scorecard at end of current quarter" should use the
-- current annual on-time projection (bonus_projected), NOT a future as_of_date
-- that deflates the projection by extending days_elapsed.
-- Prize Cart still uses end-of-previous-quarter date because it's a historical
-- snapshot; if YTD data doesn't exist for that date, the budget reads NULL.

CREATE OR REPLACE FUNCTION public.get_cpr_section_11(p_agency_id uuid, p_week_ending_date date)
 RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
DECLARE
  v_program_year      int := EXTRACT(YEAR FROM p_week_ending_date)::int;
  v_snap              record; v_book record;
  v_smvc              jsonb;
  v_smvc_on_time      numeric; v_smvc_current numeric; v_smvc_applied numeric;
  v_smvc_dollar_diff  numeric; v_pc_premium numeric;
  v_pc_production     numeric; v_auto_gain numeric; v_fire_gain numeric;
  v_fs_credits        numeric; v_ips_activity numeric;
  v_scorecard         jsonb;  v_sc_on_time numeric;
  v_sc_last_year      numeric; v_sc_dollar_diff numeric;
  v_cycle             record;
  v_prev_q_end        date;   v_curr_q_end date;
  v_sc_prev_q         jsonb;  v_sc_prev_q_value numeric;
  v_prize_cart_budget numeric; v_wtq_trip_budget numeric;
  v_wtq_scaling       numeric := 1.0;
BEGIN
  SELECT * INTO v_snap FROM public.agency_snapshot
  WHERE agency_id=p_agency_id AND snapshot_date<=p_week_ending_date AND auto_new_ytd IS NOT NULL
  ORDER BY snapshot_date DESC LIMIT 1;

  IF FOUND THEN
    v_pc_production := COALESCE(v_snap.auto_new_ytd,0) + COALESCE(v_snap.fire_new_ytd,0);
    v_auto_gain     := COALESCE(v_snap.auto_new_ytd,0) - COALESCE(v_snap.auto_lost_ytd,0);
    v_fire_gain     := COALESCE(v_snap.fire_new_ytd,0) - COALESCE(v_snap.fire_lost_ytd,0);
    v_fs_credits    := COALESCE(v_snap.life_paid_for_premium_ytd,0);
    v_ips_activity  := COALESCE(v_snap.ips_new_money_ytd,0);
    v_smvc := public.compute_on_time_smvc_with_better_of(
      p_agency_id, v_program_year, v_pc_production, v_auto_gain, v_fire_gain,
      v_fs_credits, v_ips_activity, p_week_ending_date);
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

  -- ========== BUDGETS ==========
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, p_week_ending_date);
  v_prev_q_end := v_cycle.cycle_start - 1;
  v_curr_q_end := v_cycle.cycle_end;

  -- Prize Cart = 1% × OT Scorecard at end of previous quarter (historical)
  v_sc_prev_q := public.compute_scorecard_bonus(p_agency_id, v_prev_q_end);
  v_sc_prev_q_value := NULLIF(v_sc_prev_q->>'bonus_projected','')::numeric;
  IF v_sc_prev_q_value IS NOT NULL THEN
    v_prize_cart_budget := 0.01 * v_sc_prev_q_value;
  END IF;

  -- WtQ Trip = 1% × current on-time annual Scorecard projection × scaling
  -- (uses current pace — bonus_projected from today's compute_scorecard_bonus call)
  IF v_sc_on_time IS NOT NULL THEN
    v_wtq_trip_budget := 0.01 * v_sc_on_time * v_wtq_scaling;
  END IF;

  RETURN jsonb_build_object(
    'program_year', v_program_year, 'week_ending_date', p_week_ending_date,
    'snapshot_date', v_snap.snapshot_date,
    'smvc', jsonb_build_object(
      'on_time', v_smvc_on_time, 'last_wk', NULL, 'last_q', NULL,
      'last_year', v_smvc_applied, 'applied', v_smvc_applied,
      'dollar_diff', v_smvc_dollar_diff,
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
      'formula', '1% × OT Scorecard at end of previous quarter',
      'prev_q_end', v_prev_q_end, 'prev_q_scorecard', v_sc_prev_q_value,
      'note', CASE WHEN v_prize_cart_budget IS NULL
                   THEN 'no agency_snapshot YTD data available at ' || v_prev_q_end::text
                   ELSE NULL END),
    'wtq_trip_budget', jsonb_build_object(
      'value', v_wtq_trip_budget,
      'formula', '1% × current OT Scorecard annual projection × (winner/leader scaling)',
      'curr_q_end', v_curr_q_end, 'curr_q_scorecard', v_sc_on_time,
      'scaling', v_wtq_scaling,
      'note', CASE WHEN v_wtq_trip_budget IS NULL THEN 'no Scorecard projection available'
                   WHEN v_wtq_scaling = 1.0
                   THEN 'mid-cycle — scaling defaults to 1.0 until winner ≠ leader is recorded at cycle close'
                   ELSE NULL END),
    'computed_at', now());
END;
$function$;
