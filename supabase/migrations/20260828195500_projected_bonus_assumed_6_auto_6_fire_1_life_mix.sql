-- Peter 2026-08-28: the production behind a sales-point number is an
-- ASSUMED SHAPE, not the agency's trailing premium mix. For every six autos
-- a person writes six fire and one life. That is what they wrote to hit the
-- points they hit, so that is what should build the book, and the book is
-- what grows the agency and therefore the pool.
--
-- Previously the model split a premium total by the agency's trailing
-- six-month premium mix (about six autos to two and three-quarter fire and
-- half a life) and worked out app counts by dividing by premium per policy.
-- Now the search runs on SETS of policies -- six auto, six fire, one life --
-- so app counts are the thing being solved for and premium follows from
-- them. Health is not in the assumed shape; it is a tenth of one percent of
-- production and Peter did not include it.
--
-- Everything downstream is unchanged: annualize (auto x2 for six-month
-- terms), season the book at live lapse, run the envelope waterfall, take
-- the thirds share.

CREATE OR REPLACE FUNCTION public.pay_scale_bonus_inputs(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Gathers every live input the mechanical bonus projection needs, once.
-- Everything is today's: today's pool percentage, today's pool, today's
-- premium per policy, today's lapse. The production level on the chart is
-- the only thing that varies. The MIX is not today's -- it is Peter's
-- assumed shape of six auto, six fire, one life.
DECLARE
  v_week   date;
  v_diag   jsonb;
  v_weeks  numeric;
  v_pool_wk_avg numeric;
  v_auto_prem numeric; v_fire_prem numeric; v_life_prem numeric; v_health_prem numeric;
  v_auto_apps numeric; v_fire_apps numeric; v_life_apps numeric;
  v_lapse_auto numeric; v_lapse_fire numeric; v_lapse_life numeric;
  v_carve_scaling numeric;
BEGIN
  -- Pay-scale projections are owner only in the browser. This function is
  -- the first call every pay surface makes, so the check here also closes
  -- compute_role_earnings_projection, which is SECURITY DEFINER and would
  -- otherwise let any signed-in staff read the whole pay ladder by calling
  -- the RPC directly, bypassing the app's owner-gated nav.
  IF NOT public.pay_projection_caller_ok() THEN
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

  -- Trailing 6 calendar months: premium per policy by line. The MIX from
  -- this window is no longer used; only the average size of a policy is.
  SELECT COALESCE(SUM(CASE WHEN line_of_business='Auto'   THEN premium_issued END),0),
         COALESCE(SUM(CASE WHEN line_of_business='Fire'   THEN premium_issued END),0),
         COALESCE(SUM(CASE WHEN line_of_business='Life'   THEN premium_issued END),0),
         COALESCE(SUM(CASE WHEN line_of_business='Health' THEN premium_issued END),0),
         COALESCE(SUM(CASE WHEN line_of_business='Auto'   THEN policies_issued END),0),
         COALESCE(SUM(CASE WHEN line_of_business='Fire'   THEN policies_issued END),0),
         COALESCE(SUM(CASE WHEN line_of_business='Life'   THEN policies_issued END),0)
    INTO v_auto_prem, v_fire_prem, v_life_prem, v_health_prem,
         v_auto_apps, v_fire_apps, v_life_apps
    FROM public.producer_production
   WHERE agency_id = p_agency_id
     AND make_date(period_year, period_month, 1) >= date_trunc('month', now()) - interval '6 months';

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
    -- Peter's assumed production shape, per set.
    'set_auto_apps', 6,
    'set_fire_apps', 6,
    'set_life_apps', 1,
    'auto_prem_per_app', v_auto_prem / NULLIF(v_auto_apps,0),
    'fire_prem_per_app', v_fire_prem / NULLIF(v_fire_apps,0),
    'life_prem_per_app', v_life_prem / NULLIF(v_life_apps,0),
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

CREATE OR REPLACE FUNCTION public.projected_team_bonus(p_inputs jsonb, p_x numeric, p_wh numeric, p_base_annual numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
-- Mechanical seasoned-book bonus for a seat sustaining p_x points/week.
-- Solves for how many SETS of policies the seat writes -- Peter's assumed
-- shape of six auto, six fire, one life -- such that the real SF builder
-- rate curve (compute_sp_from_production, the single copy of those rates)
-- pays them p_x points a week. Premium follows from the policy counts.
-- Then: annualize (auto x2, six-month terms), season the book at live
-- lapse, run the envelope waterfall, take the thirds share.
DECLARE
  v_target_comm numeric := 13.0 * p_x;   -- quarterly commission at X/week
  v_lo numeric := 0; v_hi numeric := 100000; v_u numeric := 0;
  v_c jsonb; v_comm numeric;
  i int;
  v_ra numeric := COALESCE((p_inputs->>'set_auto_apps')::numeric, 6);
  v_rf numeric := COALESCE((p_inputs->>'set_fire_apps')::numeric, 6);
  v_rl numeric := COALESCE((p_inputs->>'set_life_apps')::numeric, 1);
  v_appa numeric := COALESCE(NULLIF((p_inputs->>'auto_prem_per_app')::numeric, 0), 0);
  v_appf numeric := COALESCE(NULLIF((p_inputs->>'fire_prem_per_app')::numeric, 0), 0);
  v_appl numeric := COALESCE(NULLIF((p_inputs->>'life_prem_per_app')::numeric, 0), 0);
  v_qa numeric; v_qf numeric; v_ql numeric;
  v_n_auto numeric; v_n_fire numeric; v_n_life numeric;
  v_book_pc numeric; v_basis_add numeric;
  v_pool_add numeric; v_pool numeric; v_share numeric;
  v_rest numeric := (p_inputs->>'rest_sp')::numeric;
  v_team_wh numeric := (p_inputs->>'team_wh')::numeric;
BEGIN
  IF p_x > 0 THEN
    -- Binary search: how many sets a quarter pay 13X of commission.
    FOR i IN 1..40 LOOP
      v_u := (v_lo + v_hi) / 2.0;
      v_c := public.compute_sp_from_production(
               v_ra * v_u,              -- auto apps
               v_rf * v_u,              -- fire apps
               v_rl * v_u * v_appl,     -- life premium
               0,                       -- health premium: not in the shape
               v_ra * v_u * v_appa,     -- auto premium
               v_rf * v_u * v_appf);    -- fire premium
      v_comm := (v_c->'commission'->>'total_commission')::numeric;
      IF v_comm < v_target_comm THEN v_lo := v_u; ELSE v_hi := v_u; END IF;
    END LOOP;
    v_u := (v_lo + v_hi) / 2.0;
  END IF;

  -- Quarterly premium by line at that many sets.
  v_qa := v_ra * v_u * v_appa;
  v_qf := v_rf * v_u * v_appf;
  v_ql := v_rl * v_u * v_appl;

  -- Annualized new premium (auto is 6-month terms -> x2), seasoned book at
  -- live lapse, basis the book generates.
  v_n_auto := 4.0 * v_qa * 2.0;
  v_n_fire := 4.0 * v_qf;
  v_n_life := 4.0 * v_ql;
  v_book_pc := v_n_auto / NULLIF((p_inputs->>'lapse_auto')::numeric, 0)
             + v_n_fire / NULLIF((p_inputs->>'lapse_fire')::numeric, 0);
  v_basis_add := v_book_pc * ((p_inputs->>'pc_base_rate')::numeric
                              + (p_inputs->>'smvc_pct')::numeric
                              + (p_inputs->>'scorecard_pct')::numeric)
               + v_n_life * (p_inputs->>'life_first_year_rate')::numeric;

  v_pool_add := ((p_inputs->>'pool_pct')::numeric * v_basis_add) / (p_inputs->>'burden')::numeric
              - v_basis_add * (p_inputs->>'carve_scaling_pct')::numeric
              - COALESCE(p_base_annual, 0)
              - 52.0 * p_x
              - (p_inputs->>'seat_carveouts_annual')::numeric;

  v_pool := GREATEST(0, (p_inputs->>'pool_today_annual')::numeric + v_pool_add);

  v_share := (2.0/3.0) * CASE WHEN p_x > 0 AND (p_x + v_rest) > 0 THEN p_x / (p_x + v_rest) ELSE 0 END
           + (1.0/3.0) * CASE WHEN (v_team_wh + p_wh) > 0 THEN p_wh / (v_team_wh + p_wh) ELSE 0 END;

  RETURN round(v_pool * v_share, 0);
END;
$function$;
