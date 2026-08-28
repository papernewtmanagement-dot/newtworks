-- Peter 2026-08-28 (correction to my own change earlier today): the forward
-- average was a half-measure and it was wrong. The pool percentage ramps
-- down BECAUSE the book is expected to grow; the two are meant to offset.
-- Averaging tomorrow's percentage against today's book took the loss without
-- the offset, so it understated every figure on the page.
--
-- Peter's ruling: either use the final percentage with the book grown to
-- match, or use all of today's numbers. Today's numbers, because the chart
-- is not a forecast over time -- it is what pay looks like at each
-- production level, at the agency as it stands. Growing the whole agency
-- book out to 2029 would need growth assumptions nobody has set and would
-- turn the page into exactly the hypothetical-over-time curve Peter says it
-- is not.
--
-- So: today's pool percentage, today's pool baseline, one horizon.
-- pay_scale.expected_team_bonus_annual_y1 is left in place but nothing
-- writes or reads it now -- it existed only for the two-window design.

CREATE OR REPLACE FUNCTION public.pay_scale_bonus_inputs(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Gathers every live input the mechanical bonus projection needs, once.
-- Everything is today's: today's pool percentage, today's pool, today's
-- line mix, today's lapse. The production level on the chart is the only
-- thing that varies.
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

CREATE OR REPLACE FUNCTION public.reseed_pay_scale(p_agency_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Rebuilds the sales pay scale: 101 rows, 0-1000 weekly Sales Points by 10.
-- Ladder + research record: migration pay_scale_table_and_curve_from_table.
-- Bonus: mechanical seasoned-book projection (projected_team_bonus) --
-- migration pay_scale_bonus_mechanical_projection -- on today's numbers.
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

COMMENT ON COLUMN public.pay_scale.expected_team_bonus_annual_y1 IS
  'DEPRECATED 2026-08-28, same day it was added. Held a 52-week-horizon bonus for a two-window design Peter rejected. Nothing writes it and nothing reads it. Safe to drop.';

DROP FUNCTION IF EXISTS public.pay_scale_bonus_inputs(uuid, integer);
