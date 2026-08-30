-- get_cpr_section_11: remove the two dead output keys and everything that fed them.
--
-- wtq_trip_budget and prize_cart_budget were computed as 1% x on-time SCORECARD ONLY
-- (no SMVC, no pace, no floor). That disagrees with the live carveout in
-- compute_pool_carveouts and quarter_close_prize_cart_and_leaderboards, both of which
-- use 1% x on-time (SMVC + Scorecard) x pace.
--
-- Nothing reads them. Consumers rechecked at the moment of this drop, 2026-08-29:
--   - frontend: CPRDetail.jsx / Dashboard.jsx / Financials.jsx call this RPC but read
--     only smvc.on_time and scorecard_bonus.on_time.
--   - the Win the Quarter tracker (WtQAndPrizeCartSection in CPRDetail.jsx) reads
--     diag.carveouts_detail.wtq_trip instead — the correct carveout numbers.
--   - render_cpr_section_11_html, the only thing that ever displayed these keys, stopped
--     being called 2026-07-09 (cpr_v2_composer_digest) and was dropped 2026-08-05
--     (drop_dead_weight_audit_2026_08_05).
--   - no other DB function or view references either key; no edge function, script,
--     test or doc in the repo references either key.
--
-- Removing the keys also retires v_wtq_scaling (a hardcoded 1.0 with no source),
-- v_prize_cart_budget, v_wtq_trip_budget, v_cycle and v_curr_q_end, which existed only
-- to feed them. The winner/leader scaling idea those keys carried is NOT lost — it is
-- recorded in open_questions for the Win the Quarter build.

CREATE OR REPLACE FUNCTION public.get_cpr_section_11(p_agency_id uuid, p_week_ending_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_program_year      int := EXTRACT(YEAR FROM p_week_ending_date)::int;
  v_smvc_result       jsonb;
  v_snap              record;
  v_smvc_on_time      numeric; v_smvc_applied numeric;
  v_smvc_dollar_diff  numeric; v_pc_premium   numeric;
  v_fs_credits        numeric;
  v_effective_as_of   date;
  v_scorecard         jsonb;  v_sc_on_time     numeric;
  v_sc_last_year      numeric; v_sc_dollar_diff numeric;
BEGIN
  v_smvc_result := public.compute_agency_on_time_smvc(p_agency_id, p_week_ending_date);

  v_smvc_on_time     := NULLIF(v_smvc_result->>'on_time_smvc_pct','')::numeric;
  v_smvc_applied     := NULLIF(v_smvc_result->>'applied_smvc_rate','')::numeric;
  v_smvc_dollar_diff := NULLIF(v_smvc_result->>'smvc_dollar_diff','')::numeric;
  v_pc_premium       := NULLIF(v_smvc_result->>'pc_book_premium','')::numeric;
  v_fs_credits       := NULLIF(v_smvc_result->>'fs_credits_ytd','')::numeric;
  v_effective_as_of  := NULLIF(v_smvc_result->>'effective_as_of','')::date;

  -- Snapshot_date for output (production values live on this snapshot but we don't emit them here)
  SELECT * INTO v_snap FROM public.agency_snapshot
  WHERE agency_id = p_agency_id AND snapshot_date <= p_week_ending_date AND cadence='weekly'
  ORDER BY snapshot_date DESC LIMIT 1;

  v_scorecard    := public.compute_scorecard_bonus(p_agency_id, p_week_ending_date);
  v_sc_on_time   := NULLIF(v_scorecard->>'bonus_projected','')::numeric;
  v_sc_last_year := NULLIF(v_scorecard->>'last_year_bonus','')::numeric;
  IF v_sc_on_time IS NOT NULL AND v_sc_last_year IS NOT NULL THEN
    v_sc_dollar_diff := v_sc_on_time - v_sc_last_year;
  END IF;

  RETURN jsonb_build_object(
    'program_year', v_program_year, 'week_ending_date', p_week_ending_date,
    'snapshot_date', v_snap.snapshot_date,
    'effective_as_of_date', v_effective_as_of,
    'smvc', jsonb_build_object(
      'on_time', v_smvc_on_time, 'last_wk', NULL, 'last_q', NULL,
      'last_year', v_smvc_applied, 'applied', v_smvc_applied,
      'dollar_diff', v_smvc_dollar_diff,
      'fs_commissions_ytd', v_fs_credits,
      'bands_complete', COALESCE((v_smvc_result->>'bands_complete')::boolean, false),
      'pc_premium_basis', v_pc_premium,
      'computed_breakdown', v_smvc_result->'computed_breakdown'),
    'scorecard_bonus', jsonb_build_object(
      'on_time', v_sc_on_time, 'last_wk', NULL, 'last_q', NULL,
      'last_year', v_sc_last_year, 'dollar_diff', v_sc_dollar_diff,
      'bonus_ytd', (v_scorecard->>'bonus_ytd')::numeric,
      'bonus_rate', (v_scorecard->>'bonus_rate')::numeric,
      'total_points', (v_scorecard->>'total_points')::numeric,
      'computed_breakdown', v_scorecard),
    'computed_at', now());
END;
$function$;
