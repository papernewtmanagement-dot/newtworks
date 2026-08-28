-- Two things.
--
-- 1. ADMIN GUARD. The Earning Potential tab lives inside the Team module,
--    which the app gates to owner/manager. But compute_role_earnings_projection
--    is SECURITY DEFINER with EXECUTE granted to PUBLIC, so any signed-in
--    staff member (or the anon key) could call the RPC directly and read the
--    whole pay ladder. Closed two ways: EXECUTE revoked from PUBLIC and anon,
--    and an admin check placed in pay_scale_bonus_inputs — the first call
--    every pay surface makes — so the projection, the reseed and the bonus
--    function all refuse a non-admin browser caller.
--
-- 2. YEAR ONE PATH TO $100K. Peter 2026-08-28: the tier-by-year table is
--    replaced for Sales by a single first-year progression — on pace for
--    $40,000 by the end of quarter one, $60,000 by quarter two, $80,000 by
--    quarter three, and finishing the year at a weekly pace that pays
--    $100,000 over the next twelve months if held steady. Each rung is read
--    live off the published pay scale. The timeline is a pace, not a promise
--    — drive is what moves a person up the rungs, and the note says so.
--
-- NOTE: the guard shipped here first checked is_agency_admin() outright,
-- which also blocked service-side callers; migration
-- pay_projection_guard_allow_service_role immediately follows and replaces
-- that check with pay_projection_caller_ok(). Both files are kept so the
-- ledger and the repo agree.

CREATE OR REPLACE FUNCTION public.pay_scale_bonus_inputs(p_agency_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
-- Gathers every live input the mechanical bonus projection needs, once.
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
BEGIN
  -- Pay-scale projections are admin-only (owner/manager). This function is
  -- the first call every pay surface makes, so the check here also closes
  -- compute_role_earnings_projection, which is SECURITY DEFINER and would
  -- otherwise let any signed-in staff read the whole pay ladder by calling
  -- the RPC directly, bypassing the app's admin-gated nav.
  IF NOT public.is_agency_admin() THEN
    RAISE EXCEPTION 'Not authorized: pay projections are admin only';
  END IF;

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

  RETURN jsonb_build_object(
    'as_of_week', v_week,
    'pool_today_annual', round(v_pool_wk_avg * 52, 2),
    'rest_sp', round(COALESCE((v_diag->'team_totals'->>'qtd_sp_total')::numeric,0) / COALESCE(v_weeks,1), 2),
    'team_wh', COALESCE((v_diag->'team_totals'->>'wh_total')::numeric, 0),
    'pool_pct', COALESCE((v_diag->'envelope'->>'current_pool_pct')::numeric, 0) / 100.0,
    'basis_annual', COALESCE((v_diag->'envelope'->>'annual_basis')::numeric, 0),
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
    'burden', 1.08,
    'pc_base_rate', 0.08,            -- agency P&C base commission (strip-factor anchor)
    'life_first_year_rate', 0.50     -- agency first-year life commission assumption
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.pay_projection_caller_ok()
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
-- True when the caller may read pay projections: any service-side or direct
-- database connection, or a signed-in owner/manager in the browser.
DECLARE v_role text;
BEGIN
  BEGIN
    v_role := auth.role();
  EXCEPTION WHEN OTHERS THEN
    v_role := NULL;
  END;
  IF v_role IS NULL OR v_role NOT IN ('anon', 'authenticated') THEN
    RETURN true;   -- service role, cron, or a direct connection
  END IF;
  RETURN public.is_agency_admin();
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.pay_projection_caller_ok() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.pay_projection_caller_ok() TO authenticated;

REVOKE EXECUTE ON FUNCTION public.pay_scale_bonus_inputs(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.compute_role_earnings_projection(uuid, date) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.projected_team_bonus(jsonb, numeric, numeric, numeric) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.reseed_pay_scale(uuid) FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public.year_one_path_to_100k(p_agency_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
-- First-year progression for a Sales seat, read live off public.pay_scale.
-- Rungs (Peter 2026-08-28): end of quarter one on pace for $40,000, quarter
-- two $60,000, quarter three $80,000, end of year at a weekly pace worth
-- $100,000 over the following twelve months if held steady. Each rung is
-- the lowest published 10-point row whose base + commission + team bonus
-- reaches the target, so the path moves whenever the scale is reseeded.
DECLARE
  v_rungs   jsonb := '[]'::jsonb;
  v_targets numeric[] := ARRAY[40000, 60000, 80000, 100000];
  v_labels  text[] := ARRAY['End of quarter one','End of quarter two',
                            'End of quarter three','End of year one'];
  v_when    text[] := ARRAY['on pace for','on pace for','on pace for',
                            'holding a pace worth'];
  i         int;
  r         record;
BEGIN
  IF NOT public.pay_projection_caller_ok() THEN
    RAISE EXCEPTION 'Not authorized: pay projections are admin only';
  END IF;

  FOR i IN 1..array_length(v_targets, 1) LOOP
    SELECT p.sales_points, p.band, p.raise_tier, p.base_hourly, p.base_annual,
           p.expected_commission_annual AS comm,
           p.expected_team_bonus_annual AS bonus,
           p.base_annual + COALESCE(p.expected_commission_annual,0)
                         + COALESCE(p.expected_team_bonus_annual,0) AS total
      INTO r
      FROM public.pay_scale p
     WHERE p.agency_id = p_agency_id AND p.role_key = 'sales'
       AND p.base_annual + COALESCE(p.expected_commission_annual,0)
                         + COALESCE(p.expected_team_bonus_annual,0) >= v_targets[i]
     ORDER BY p.sales_points
     LIMIT 1;

    IF FOUND THEN
      v_rungs := v_rungs || jsonb_build_object(
        'step', i,
        'step_label', v_labels[i],
        'pace_label', v_when[i],
        'target_annual', v_targets[i],
        'weekly_sales_points', r.sales_points,
        'band', r.band,
        'base_hourly', r.base_hourly,
        'base_annual', round(r.base_annual, 0),
        'commission', round(COALESCE(r.comm,0), 0),
        'bonus', round(COALESCE(r.bonus,0), 0),
        'total', round(r.total, 0),
        'rate_label', '$' || to_char(r.base_hourly, 'FM990.00') || '/hr'
                      || CASE WHEN COALESCE(r.raise_tier,0) > 0
                              THEN ' — raise tier ' || r.raise_tier
                              ELSE ' — starting rate' END
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id,
    'computed_at', now(),
    'role_key', 'sales',
    'rungs', v_rungs,
    'headline', 'One way a first year can go — from starting rate to a '
             || 'hundred thousand dollar pace inside twelve months.',
    'note', 'Every rung is a weekly sales-point pace, taken straight off the '
         || 'published pay scale: hold that pace for a year and the pay is '
         || 'what the row says. What decides whether a person climbs the '
         || 'rungs on this timeline is drive — how many people they talk to, '
         || 'how fast they get back to them, how hard they work the follow '
         || 'up. Someone with real drive can move quicker than this. Plenty '
         || 'of people take two years or three to reach the top rung, and '
         || 'someone who stops pushing stops climbing. The agency supplies '
         || 'the leads, the training and the pay scale. The pace is the '
         || 'person.'
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.year_one_path_to_100k(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.year_one_path_to_100k(uuid) TO authenticated;
