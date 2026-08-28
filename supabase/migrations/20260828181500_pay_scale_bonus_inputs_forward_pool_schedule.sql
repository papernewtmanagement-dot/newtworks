-- Peter 2026-08-28: the Earning Potential page is a FORWARD-LOOKING pay
-- graph, so the bonus pool percentage it uses must be forward-looking too.
-- It was reading this week's percentage out of the weekly settlement
-- diagnostics and holding it flat forever. That percentage is not produced
-- by production at all: it is a dated schedule in
-- public.team_comp_pool_schedule, 45.227% at the 2026-07-11 Phase 1 start,
-- ramping down to 40.00% at the 2027-12-25 Phase 1 end, lifting to 44.085%
-- at the 2028-01-01 Phase 3 start (the AA28 bridge), then ramping down to
-- Peter's 35.00% anchor at 2029-12-29.
--
-- The inputs function now reads the schedule forward over the window the
-- money is actually earned and averages it. Horizon is a parameter: the
-- seasoned-book curve asks for 156 weeks, the first-year table asks for 52.
-- Weeks past the end of the published schedule hold flat at the last
-- scheduled percentage rather than dropping out of the average.
--
-- The baseline pool is corrected exactly, not proportionally. The envelope
-- is pool_pct x basis / burden and every subtraction under it (team base
-- pay, commissions, carveouts) is a fixed dollar amount that does not move
-- when the percentage moves. So the residual pool changes by exactly the
-- change in the envelope: delta_pct x basis / burden. Scaling the residual
-- proportionally would have understated the drop badly, because the
-- residual is a small difference between two large numbers.
--
-- The single-argument form is kept as a wrapper at the 156-week horizon so
-- every existing caller keeps working unchanged.

CREATE OR REPLACE FUNCTION public.pay_scale_bonus_inputs(p_agency_id uuid, p_horizon_weeks integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Gathers every live input the mechanical bonus projection needs, once.
-- p_horizon_weeks is how far forward the bonus pool percentage is averaged.
DECLARE
  v_week   date;
  v_diag   jsonb;
  v_weeks  numeric;
  v_pool_wk_avg numeric;
  v_auto_prem numeric; v_fire_prem numeric; v_life_prem numeric; v_health_prem numeric;
  v_auto_apps numeric; v_fire_apps numeric;
  v_tot_prem numeric;
  v_lapse_auto numeric; v_lapse_fire numeric; v_lapse_life numeric;
  v_carve_scaling numeric;
  v_basis_annual numeric;
  v_pct_now numeric;
  v_pct_fwd numeric;
  v_sched_sum numeric;
  v_sched_n integer;
  v_sched_last numeric;
  v_win_end date;
  v_pool_today numeric;
  v_horizon integer;
  c_burden numeric := 1.08;
BEGIN
  -- Pay-scale projections are owner only in the browser. This function is
  -- the first call every pay surface makes, so the check here also closes
  -- compute_role_earnings_projection, which is SECURITY DEFINER and would
  -- otherwise let any signed-in staff read the whole pay ladder by calling
  -- the RPC directly, bypassing the app's owner-gated nav.
  IF NOT public.pay_projection_caller_ok() THEN
    RAISE EXCEPTION 'Not authorized: pay projections are admin only';
  END IF;

  v_horizon := GREATEST(COALESCE(p_horizon_weeks, 156), 1);

  SELECT MAX(r.week_ending_date) INTO v_week
    FROM public.weekly_cpr_reports r
   WHERE r.agency_id = p_agency_id
     AND EXISTS (SELECT 1 FROM public.weekly_cpr_team_detail d
                  WHERE d.weekly_cpr_report_id = r.id AND d.bonus IS NOT NULL);

  SELECT x.diagnostics INTO v_diag
    FROM public.compute_weekly_comp_residual_pool(p_agency_id, v_week) x
   LIMIT 1;

  v_weeks := NULLIF(COALESCE((v_diag->'quarter'->>'weeks_elapsed_qtd')::numeric, 0), 0);
  v_pool_wk_avg := (COALESCE((v_diag->'qtd_subtractions'->>'qtd_bonus_paid_prior')::numeric, 0)
                    + COALESCE((v_diag->'weekly_settlement'->>'weekly_bonus_pool')::numeric, 0))
                   / COALESCE(v_weeks, 1);

  -- Trailing 6 calendar months of production for the line mix.
  SELECT COALESCE(SUM(CASE WHEN line_of_business='Auto'   THEN premium_issued END),0),
         COALESCE(SUM(CASE WHEN line_of_business='Fire'   THEN premium_issued END),0),
         COALESCE(SUM(CASE WHEN line_of_business='Life'   THEN premium_issued END),0),
         COALESCE(SUM(CASE WHEN line_of_business='Health' THEN premium_issued END),0),
         COALESCE(SUM(CASE WHEN line_of_business='Auto'   THEN policies_issued END),0),
         COALESCE(SUM(CASE WHEN line_of_business='Fire'   THEN policies_issued END),0)
    INTO v_auto_prem, v_fire_prem, v_life_prem, v_health_prem, v_auto_apps, v_fire_apps
    FROM public.producer_production
   WHERE agency_id = p_agency_id
     AND make_date(period_year, period_month, 1) >= date_trunc('month', now()) - interval '6 months';

  v_tot_prem := NULLIF(v_auto_prem + v_fire_prem + v_life_prem + v_health_prem, 0);

  SELECT MAX(CASE WHEN line='auto' THEN annualized_rate END),
         MAX(CASE WHEN line='fire' THEN annualized_rate END),
         MAX(CASE WHEN line='life' THEN annualized_rate END)
    INTO v_lapse_auto, v_lapse_fire, v_lapse_life
    FROM public.v_lapse_rate_current WHERE agency_id = p_agency_id;

  v_carve_scaling := (COALESCE((v_diag->'carveouts_detail'->'wtq_trip'->>'annual_dollars')::numeric,0)
                    + COALESCE((v_diag->'carveouts_detail'->'mvp_prize_cart'->>'annual_dollars')::numeric,0)
                    + COALESCE((v_diag->'carveouts_detail'->'manager_bonus'->>'annual_dollars')::numeric,0))
                   / NULLIF(COALESCE((v_diag->'envelope'->>'annual_basis')::numeric,0), 0);

  v_basis_annual := COALESCE((v_diag->'envelope'->>'annual_basis')::numeric, 0);

  -- Forward-looking pool percentage off the dated schedule.
  v_pct_now := COALESCE((v_diag->'envelope'->>'current_pool_pct')::numeric, 0);
  v_win_end := v_week + (v_horizon * 7);

  SELECT COALESCE(SUM(s.pool_pct), 0), COUNT(*)
    INTO v_sched_sum, v_sched_n
    FROM public.team_comp_pool_schedule s
   WHERE s.agency_id = p_agency_id
     AND s.week_end_date > v_week
     AND s.week_end_date <= v_win_end;

  SELECT s.pool_pct INTO v_sched_last
    FROM public.team_comp_pool_schedule s
   WHERE s.agency_id = p_agency_id
     AND s.week_end_date <= v_win_end
   ORDER BY s.week_end_date DESC
   LIMIT 1;

  IF v_sched_n > 0 THEN
    v_pct_fwd := (v_sched_sum
                  + COALESCE(v_sched_last, 0) * GREATEST(v_horizon - v_sched_n, 0))
                 / v_horizon;
  ELSE
    v_pct_fwd := v_pct_now;   -- no schedule published: hold today's figure
  END IF;

  v_pool_today := (v_pool_wk_avg * 52.0)
                  - ((v_pct_now - v_pct_fwd) / 100.0) * v_basis_annual / c_burden;

  RETURN jsonb_build_object(
    'as_of_week', v_week,
    'pool_today_annual', round(v_pool_today, 2),
    'pool_today_annual_at_current_pct', round(v_pool_wk_avg * 52.0, 2),
    'rest_sp', round(COALESCE((v_diag->'team_totals'->>'qtd_sp_total')::numeric,0) / COALESCE(v_weeks,1), 2),
    'team_wh', COALESCE((v_diag->'team_totals'->>'wh_total')::numeric, 0),
    'pool_pct', v_pct_fwd / 100.0,
    'pool_pct_now', v_pct_now / 100.0,
    'pool_pct_forward', v_pct_fwd / 100.0,
    'pool_horizon_weeks', v_horizon,
    'pool_window_end', v_win_end,
    'pool_weeks_scheduled', v_sched_n,
    'basis_annual', v_basis_annual,
    'mix_auto', COALESCE(v_auto_prem,0) / COALESCE(v_tot_prem,1),
    'mix_fire', COALESCE(v_fire_prem,0) / COALESCE(v_tot_prem,1),
    'mix_life', COALESCE(v_life_prem,0) / COALESCE(v_tot_prem,1),
    'mix_health', COALESCE(v_health_prem,0) / COALESCE(v_tot_prem,1),
    'auto_prem_per_app', v_auto_prem / NULLIF(v_auto_apps,0),
    'fire_prem_per_app', v_fire_prem / NULLIF(v_fire_apps,0),
    'lapse_auto', COALESCE(v_lapse_auto, 0.30),
    'lapse_fire', COALESCE(v_lapse_fire, 0.25),
    'lapse_life', COALESCE(v_lapse_life, 0.15),
    'smvc_pct', COALESCE((v_diag->'pool_basis'->>'on_time_smvc_pct')::numeric, 0),
    'scorecard_pct', COALESCE((v_diag->'pool_basis'->>'on_time_scorecard_dollars')::numeric,0)
                     / NULLIF(COALESCE((v_diag->'pool_basis'->>'pc_book_premium')::numeric,0),0),
    'carve_scaling_pct', COALESCE(v_carve_scaling, 0),
    'seat_carveouts_annual', 3900,   -- 5 goals buckets $10x52 + $25/wk health development
    'burden', c_burden,
    'pc_base_rate', 0.08,            -- agency P&C base commission (strip-factor anchor)
    'life_first_year_rate', 0.50     -- agency first-year life commission assumption
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.pay_scale_bonus_inputs(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- Default horizon: three years, the window the seasoned-book curve covers.
  SELECT public.pay_scale_bonus_inputs(p_agency_id, 156);
$function$;
