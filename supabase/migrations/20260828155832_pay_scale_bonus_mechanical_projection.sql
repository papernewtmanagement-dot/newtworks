-- Mechanical team-bonus projection (Peter direction 2026-08-28):
-- 1. TIER-RATE CURVE: a producer's commission rate climbs as they unlock
--    tiers (1% base -> 6% cap on P&C), so one sales point sits on LESS
--    premium the more someone produces. The projection now inverts the
--    real rate function per production level — it CALLS
--    compute_sp_from_production (the single copy of the SF-builder rates)
--    with the team's observed line mix, binary-searching the quarterly
--    premium that yields that seat's commission. Premium per point falls
--    from ~$48 at 100/wk to ~$19 at 1,000/wk.
-- 2. AUTO TERMS: auto premium_issued is 6-month; annualized x2. Fire and
--    life are annual.
-- 3. LIVE LAPSE: seasoned-book multiplier per line = 1 / annualized lapse
--    from v_lapse_rate_current (live book snapshots). No assumed
--    retention numbers anywhere.
--
-- Model per sustained X points/week (seat added to today's team):
--   quarterly premium P(X): solve team commission(P) = 13X via the real
--     rate function, using the trailing-6-month line mix and premiums/app
--   new annualized premium N by line (auto x2), seasoned book = N/lapse
--   basis added = P&C book x (8% base + live on-time SMVC% + Scorecard%)
--                 + 50% of first-year life premium (life pays first-year;
--                 no book compounding assumed — conservative, tiny share)
--   pool added = pool_pct x basis_added / 1.08 (burden)
--                - basis-scaled carveouts - seat base (raise ladder)
--                - seat commission (52X) - seat carveouts ($3,900)
--   pool(X) = today's pool run rate + pool added, floored at 0
--   seat bonus = pool(X) x [ 2/3 x X/(X+rest_of_team) + 1/3 x wh/(team_wh+wh) ]
--
-- The curve is the SEASONED-BOOK number: at today's lapse the book reaches
-- roughly 70% of it by year three. Internal consistency: the seat's full
-- comp cost (base + commission + bonus, burdened) stays below the envelope
-- their book generates at every production level.

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

CREATE OR REPLACE FUNCTION public.projected_team_bonus(p_inputs jsonb, p_x numeric, p_wh numeric, p_base_annual numeric)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $function$
-- Mechanical seasoned-book bonus for a seat sustaining p_x points/week.
-- Inverts the real team rate curve (compute_sp_from_production, the
-- single copy of SF-builder rates) to find the premium behind the points,
-- annualizes (auto x2), seasons the book at live lapse, runs the envelope
-- waterfall, and takes the thirds share.
DECLARE
  v_target_comm numeric := 13.0 * p_x;   -- quarterly commission at X/week
  v_lo numeric := 0; v_hi numeric := 5000000; v_p numeric := 0;
  v_c jsonb; v_comm numeric;
  i int;
  v_mix_auto numeric := (p_inputs->>'mix_auto')::numeric;
  v_mix_fire numeric := (p_inputs->>'mix_fire')::numeric;
  v_mix_life numeric := (p_inputs->>'mix_life')::numeric;
  v_mix_health numeric := (p_inputs->>'mix_health')::numeric;
  v_appa numeric := NULLIF((p_inputs->>'auto_prem_per_app')::numeric, 0);
  v_appf numeric := NULLIF((p_inputs->>'fire_prem_per_app')::numeric, 0);
  v_n_auto numeric; v_n_fire numeric; v_n_life numeric;
  v_book_pc numeric; v_basis_add numeric;
  v_pool_add numeric; v_pool numeric; v_share numeric;
  v_rest numeric := (p_inputs->>'rest_sp')::numeric;
  v_team_wh numeric := (p_inputs->>'team_wh')::numeric;
BEGIN
  IF p_x > 0 THEN
    -- Binary search: quarterly premium whose commission equals 13X.
    FOR i IN 1..40 LOOP
      v_p := (v_lo + v_hi) / 2.0;
      v_c := public.compute_sp_from_production(
               CASE WHEN v_appa IS NULL THEN 0 ELSE (v_p * v_mix_auto) / v_appa END,
               CASE WHEN v_appf IS NULL THEN 0 ELSE (v_p * v_mix_fire) / v_appf END,
               v_p * v_mix_life,
               v_p * v_mix_health,
               v_p * v_mix_auto,
               v_p * v_mix_fire);
      v_comm := (v_c->'commission'->>'total_commission')::numeric;
      IF v_comm < v_target_comm THEN v_lo := v_p; ELSE v_hi := v_p; END IF;
    END LOOP;
    v_p := (v_lo + v_hi) / 2.0;
  END IF;

  -- Annualized new premium (auto is 6-month terms -> x2), seasoned book at
  -- live lapse, basis the book generates.
  v_n_auto := 4.0 * v_p * v_mix_auto * 2.0;
  v_n_fire := 4.0 * v_p * v_mix_fire;
  v_n_life := 4.0 * v_p * v_mix_life;
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

CREATE OR REPLACE FUNCTION public.reseed_pay_scale(p_agency_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
-- Rebuilds the sales pay scale: 101 rows, 0-1000 weekly Sales Points by 10.
-- Ladder + research record: migration pay_scale_table_and_curve_from_table.
-- Bonus: mechanical seasoned-book projection (projected_team_bonus) —
-- migration pay_scale_bonus_mechanical_projection.
DECLARE
  v_inputs jsonb;
  v_x      integer;
  v_i      integer;
  v_tier   integer;
  v_hourly numeric;
  v_next   integer;
  v_base   numeric;
  v_n      integer := 0;
  c_thresholds  integer[] := ARRAY[0,100,175,250,300,325,355,390,425,460,500,545,595];
  c_hourly      numeric[] := ARRAY[15,16,17,18,19,20,21,22,23,24,25,26,27];
  c_seat_wh     numeric   := 8;
BEGIN
  v_inputs := public.pay_scale_bonus_inputs(p_agency_id);

  DELETE FROM public.pay_scale WHERE agency_id = p_agency_id AND role_key = 'sales';

  FOR v_x IN SELECT generate_series(0, 1000, 10) LOOP
    v_tier := 0; v_hourly := c_hourly[1]; v_next := NULL;
    FOR v_i IN 1..array_length(c_thresholds, 1) LOOP
      IF v_x >= c_thresholds[v_i] THEN
        v_tier := v_i - 1;
        v_hourly := c_hourly[v_i];
        v_next := CASE WHEN v_i < array_length(c_thresholds, 1) THEN c_thresholds[v_i + 1] ELSE NULL END;
      END IF;
    END LOOP;
    v_base := round(v_hourly * 2080, 0);

    INSERT INTO public.pay_scale (
      agency_id, role_key, sales_points, band, raise_tier,
      base_hourly, base_annual, next_raise_at,
      expected_commission_annual, expected_team_bonus_annual, updated_at
    ) VALUES (
      p_agency_id, 'sales', v_x,
      public.compute_sales_points_rating(p_agency_id, v_x),
      v_tier,
      v_hourly,
      v_base,
      v_next,
      round(v_x * 52.0, 0),
      public.projected_team_bonus(v_inputs, v_x, c_seat_wh, v_base),
      now()
    );
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END;
$function$;

SELECT public.reseed_pay_scale('126794dd-25ff-47d2-a436-724499733365');