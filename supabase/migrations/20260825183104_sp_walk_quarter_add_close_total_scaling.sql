-- sp_walk_quarter: optional p_close_total.
-- Peter supplies quarter-end Sales Points totals from his own records that differ from what the
-- production rows on file compute (e.g. Q2 2026 Tommy 5,466.52 vs 5,179.24 on file). When
-- p_close_total is given, the walk keeps its tier-driven SHAPE from the production on file and is
-- scaled so week N lands exactly on the supplied total. Unscaled value and factor are returned
-- alongside so nothing is hidden. NULL = no scaling (week N = production-derived total).
-- Old 3-arg overload dropped so the default-arg call stays unambiguous.

DROP FUNCTION IF EXISTS public.sp_walk_quarter(uuid, uuid, date);

CREATE OR REPLACE FUNCTION public.sp_walk_quarter(
  p_agency_id uuid,
  p_team_member_id uuid,
  p_any_date_in_quarter date,
  p_close_total numeric DEFAULT NULL)
 RETURNS TABLE(
   week_no int, week_ending date,
   sales_points_cum numeric, sales_points_delta numeric,
   sales_points_cum_unscaled numeric, scale_factor numeric,
   cum_auto_apps numeric, cum_fire_apps numeric, cum_life_prem numeric, cum_pc_prem numeric,
   pc_rate numeric, lh_rate numeric)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cycle  record;
  v_weeks  int;
  v_mid    date;
  v_year   int;
  v_m1     int;
  v_m3     int;
  v_auto_apps numeric := 0; v_fire_apps numeric := 0; v_life_prem numeric := 0;
  v_health_prem numeric := 0; v_auto_prem numeric := 0; v_fire_prem numeric := 0;
  v_raw    numeric[];
  v_total  numeric;
  v_scale  numeric := 1;
  k int; v_calc jsonb; v_prev numeric := 0; v_cum numeric; v_f numeric;
BEGIN
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, p_any_date_in_quarter);
  v_weeks := (v_cycle.cycle_end - v_cycle.cycle_start + 1) / 7;

  v_mid  := v_cycle.cycle_start + 45;
  v_year := EXTRACT(year FROM v_mid)::int;
  v_m1   := ((EXTRACT(month FROM v_mid)::int - 1) / 3) * 3 + 1;
  v_m3   := v_m1 + 2;

  SELECT
    COALESCE(SUM(CASE WHEN line_of_business='Auto'   THEN policies_issued END), 0),
    COALESCE(SUM(CASE WHEN line_of_business='Fire'   THEN policies_issued END), 0),
    COALESCE(SUM(CASE WHEN line_of_business='Life'   THEN premium_issued END), 0),
    COALESCE(SUM(CASE WHEN line_of_business='Health' THEN premium_issued END), 0),
    COALESCE(SUM(CASE WHEN line_of_business='Auto'   THEN premium_issued END), 0),
    COALESCE(SUM(CASE WHEN line_of_business='Fire'   THEN premium_issued END), 0)
  INTO v_auto_apps, v_fire_apps, v_life_prem, v_health_prem, v_auto_prem, v_fire_prem
  FROM public.producer_production
  WHERE agency_id = p_agency_id
    AND team_member_id = p_team_member_id
    AND period_year = v_year
    AND period_month BETWEEN v_m1 AND v_m3;

  -- pass 1: raw walk
  v_raw := ARRAY[]::numeric[];
  FOR k IN 1..v_weeks LOOP
    v_f := k::numeric / v_weeks;
    v_calc := public.compute_sp_from_production(
                v_auto_apps * v_f, v_fire_apps * v_f, v_life_prem * v_f,
                v_health_prem * v_f, v_auto_prem * v_f, v_fire_prem * v_f);
    v_raw := v_raw || (v_calc->'commission'->>'total_commission')::numeric;
  END LOOP;
  v_total := v_raw[v_weeks];

  IF p_close_total IS NOT NULL AND v_total > 0 THEN
    v_scale := p_close_total / v_total;
  END IF;

  -- pass 2: emit
  FOR k IN 1..v_weeks LOOP
    v_f := k::numeric / v_weeks;
    v_calc := public.compute_sp_from_production(
                v_auto_apps * v_f, v_fire_apps * v_f, v_life_prem * v_f,
                v_health_prem * v_f, v_auto_prem * v_f, v_fire_prem * v_f);

    IF p_close_total IS NOT NULL AND v_total > 0 THEN
      v_cum := CASE WHEN k = v_weeks THEN p_close_total ELSE ROUND(v_raw[k] * v_scale, 2) END;
    ELSIF p_close_total IS NOT NULL THEN
      -- no production on file: fall back to a flat spread of the supplied total
      v_cum := CASE WHEN k = v_weeks THEN p_close_total ELSE ROUND(p_close_total * v_f, 2) END;
    ELSE
      v_cum := v_raw[k];
    END IF;

    week_no                   := k;
    week_ending               := v_cycle.cycle_start + (k * 7) - 1;
    sales_points_cum          := v_cum;
    sales_points_delta        := ROUND(v_cum - v_prev, 2);
    sales_points_cum_unscaled := v_raw[k];
    scale_factor              := ROUND(v_scale, 6);
    cum_auto_apps             := ROUND(v_auto_apps * v_f, 2);
    cum_fire_apps             := ROUND(v_fire_apps * v_f, 2);
    cum_life_prem             := ROUND(v_life_prem * v_f, 2);
    cum_pc_prem               := ROUND((v_auto_prem + v_fire_prem) * v_f, 2);
    pc_rate                   := (v_calc->'rates'->>'pc_rate_capped')::numeric;
    lh_rate                   := (v_calc->'rates'->>'lh_rate_capped')::numeric;
    RETURN NEXT;
    v_prev := v_cum;
  END LOOP;
END;
$function$;

COMMENT ON FUNCTION public.sp_walk_quarter(uuid, uuid, date, numeric) IS
  'Even-spread Sales Points walk for one person over one SF quarter (boundaries from current_cycle_info). Spreads the quarter''s producer_production evenly across its Saturdays and returns cumulative Sales Points each week via compute_sp_from_production. Optional p_close_total: keep the tier-driven shape but scale so the final week equals the supplied quarter-end total (Peter''s records); unscaled value and factor returned alongside. Use to backfill weekly_cpr_team_detail.sales_points where only quarter totals exist.';

GRANT EXECUTE ON FUNCTION public.sp_walk_quarter(uuid, uuid, date, numeric) TO authenticated;
