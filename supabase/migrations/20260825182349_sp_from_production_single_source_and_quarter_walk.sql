-- Sales Points from production: ONE calculator, two callers.
--
-- 1. compute_sp_from_production(...)  -- PURE. The SF Team Incentives builder rate structure
--    (synced 2026-07-07) lives HERE and nowhere else. Takes quarter-cumulative production, returns
--    tiers / rates / commission. 1 Sales Point = $1 team commission.
-- 2. compute_person_commissions_quarterly(...)  -- unchanged contract and output; now aggregates
--    producer_production for the quarter and calls (1). Constants deleted from its body.
-- 3. sp_walk_quarter(...)  -- NEW. Peter 2026-08-25 (method first locked 2026-07-12, leaderboard
--    rebuild): take a quarter's production, assume it was produced evenly across the quarter's
--    Saturdays, and recompute cumulative Sales Points at every week. Tiers apply retroactively to
--    the whole quarter's premium, so the curve is NOT linear even though production is.
--    Quarter boundaries come from current_cycle_info (SF fiscal quarter); production months are
--    the calendar quarter that the cycle's midpoint falls in (Q2 2026 cycle Apr 5..Jul 4 -> months 4-6).

CREATE OR REPLACE FUNCTION public.compute_sp_from_production(
  p_auto_apps   numeric,
  p_fire_apps   numeric,
  p_life_prem   numeric,
  p_health_prem numeric,
  p_auto_prem   numeric,
  p_fire_prem   numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  -- Rate structure synced to SF Team Incentives builder 2026-07-07. SINGLE COPY.
  c_pc_base_pct   CONSTANT numeric := 0.01;     -- 1% base
  c_pc_step_pct   CONSTANT numeric := 0.0005;   -- 0.05% per tier
  c_lh_base_pct   CONSTANT numeric := 0.03;     -- 3% base
  c_lh_step_pct   CONSTANT numeric := 0.0015;   -- 0.15% per tier
  c_pc_cap        CONSTANT numeric := 0.06;     -- 6% cap
  c_lh_cap        CONSTANT numeric := 0.18;     -- 18% cap
  c_trim          CONSTANT numeric := 1.00;
  c_pc_life_dollar_step CONSTANT numeric := 200;
  c_lh_life_dollar_step CONSTANT numeric := 200;
  c_auto_app_step CONSTANT int := 6;
  c_fire_app_step CONSTANT int := 3;
  c_auto_rep_cap  CONSTANT int := 25;   -- Auto tier repeatable up to 25x
  c_fire_rep_cap  CONSTANT int := 30;   -- Fire tier repeatable up to 30x
  c_life_rep_cap  CONSTANT int := 99;   -- Life tier repeatable up to 99x (both sides)

  v_auto_apps numeric := COALESCE(p_auto_apps, 0);
  v_fire_apps numeric := COALESCE(p_fire_apps, 0);
  v_life_prem numeric := COALESCE(p_life_prem, 0);
  v_health_prem numeric := COALESCE(p_health_prem, 0);
  v_auto_prem numeric := COALESCE(p_auto_prem, 0);
  v_fire_prem numeric := COALESCE(p_fire_prem, 0);

  v_life_tiers_pc int; v_auto_tiers int; v_fire_tiers int; v_life_tiers_lh int;
  v_pc_rate_raw numeric; v_pc_rate_capped numeric; v_pc_rate_trimmed numeric;
  v_lh_rate_raw numeric; v_lh_rate_capped numeric; v_lh_rate_trimmed numeric;
  v_pc_premium_base numeric; v_lh_premium_base numeric;
  v_pc_commission numeric; v_lh_commission numeric;
BEGIN
  v_life_tiers_pc := LEAST(c_life_rep_cap, FLOOR(v_life_prem / c_pc_life_dollar_step)::int);
  v_auto_tiers    := LEAST(c_auto_rep_cap, FLOOR(v_auto_apps / c_auto_app_step)::int);
  v_fire_tiers    := LEAST(c_fire_rep_cap, FLOOR(v_fire_apps / c_fire_app_step)::int);
  v_life_tiers_lh := LEAST(c_life_rep_cap, FLOOR(v_life_prem / c_lh_life_dollar_step)::int);

  v_pc_rate_raw     := c_pc_base_pct + (v_life_tiers_pc + v_auto_tiers + v_fire_tiers) * c_pc_step_pct;
  v_pc_rate_capped  := LEAST(c_pc_cap, v_pc_rate_raw);
  v_pc_rate_trimmed := v_pc_rate_capped * c_trim;

  v_lh_rate_raw     := c_lh_base_pct + (v_life_tiers_lh * c_lh_step_pct);
  v_lh_rate_capped  := LEAST(c_lh_cap, v_lh_rate_raw);
  v_lh_rate_trimmed := v_lh_rate_capped * c_trim;

  v_pc_premium_base := v_auto_prem + v_fire_prem;
  v_lh_premium_base := v_life_prem + v_health_prem;
  v_pc_commission   := v_pc_rate_trimmed * v_pc_premium_base;
  v_lh_commission   := v_lh_rate_trimmed * v_lh_premium_base;

  RETURN jsonb_build_object(
    'tiers', jsonb_build_object(
      'life_tiers_pc_at_200', v_life_tiers_pc,
      'auto_tiers_at_6',      v_auto_tiers,
      'fire_tiers_at_3',      v_fire_tiers,
      'life_tiers_lh_at_200', v_life_tiers_lh,
      'auto_rep_cap',         c_auto_rep_cap,
      'fire_rep_cap',         c_fire_rep_cap,
      'life_rep_cap',         c_life_rep_cap),
    'rates', jsonb_build_object(
      'pc_base_pct',      c_pc_base_pct,
      'pc_step_pct',      c_pc_step_pct,
      'pc_rate_raw',      ROUND(v_pc_rate_raw, 6),
      'pc_rate_capped',   ROUND(v_pc_rate_capped, 6),
      'pc_rate_trimmed',  ROUND(v_pc_rate_trimmed, 6),
      'lh_base_pct',      c_lh_base_pct,
      'lh_step_pct',      c_lh_step_pct,
      'lh_rate_raw',      ROUND(v_lh_rate_raw, 6),
      'lh_rate_capped',   ROUND(v_lh_rate_capped, 6),
      'lh_rate_trimmed',  ROUND(v_lh_rate_trimmed, 6)),
    'commission', jsonb_build_object(
      'pc_premium_base',  v_pc_premium_base,
      'lh_premium_base',  v_lh_premium_base,
      'pc_commission',    ROUND(v_pc_commission, 2),
      'lh_commission',    ROUND(v_lh_commission, 2),
      'total_commission', ROUND(v_pc_commission + v_lh_commission, 2)),
    'sf_config_synced', '2026-07-07',
    'plan_version',     'sf_builder_2026_07_07');
END;
$function$;

COMMENT ON FUNCTION public.compute_sp_from_production(numeric, numeric, numeric, numeric, numeric, numeric) IS
  'PURE Sales Points calculator. Single home of the SF Team Incentives builder rate structure (synced 2026-07-07). Inputs are quarter-cumulative production (fractional apps allowed for even-spread walks). 1 Sales Point = $1 team commission. Callers: compute_person_commissions_quarterly, sp_walk_quarter. Change rates HERE only.';

-- 2. Quarterly wrapper: same signature, same JSON shape, now delegates.
CREATE OR REPLACE FUNCTION public.compute_person_commissions_quarterly(p_agency_id uuid, p_team_member_id uuid, p_period_year integer, p_quarter_num integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_month_start int := (p_quarter_num - 1) * 3 + 1;
  v_month_end   int := p_quarter_num * 3;
  v_auto_apps   int := 0;
  v_fire_apps   int := 0;
  v_life_prem   numeric := 0;
  v_health_prem numeric := 0;
  v_auto_prem   numeric := 0;
  v_fire_prem   numeric := 0;
  v_calc        jsonb;
BEGIN
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
    AND period_year = p_period_year
    AND period_month BETWEEN v_month_start AND v_month_end;

  v_calc := public.compute_sp_from_production(v_auto_apps, v_fire_apps, v_life_prem, v_health_prem, v_auto_prem, v_fire_prem);

  RETURN jsonb_build_object(
    'agency_id',      p_agency_id,
    'team_member_id', p_team_member_id,
    'period_year',    p_period_year,
    'quarter_num',    p_quarter_num,
    'month_range',    jsonb_build_array(v_month_start, v_month_end),
    'issued', jsonb_build_object(
      'auto_apps',      v_auto_apps,
      'fire_apps',      v_fire_apps,
      'life_premium',   v_life_prem,
      'health_premium', v_health_prem,
      'auto_premium',   v_auto_prem,
      'fire_premium',   v_fire_prem))
    || v_calc
    || jsonb_build_object('computed_at', now());
END;
$function$;

-- 3. Even-spread tier walk across the SF quarter.
CREATE OR REPLACE FUNCTION public.sp_walk_quarter(p_agency_id uuid, p_team_member_id uuid, p_any_date_in_quarter date)
 RETURNS TABLE(
   week_no int, week_ending date,
   sales_points_cum numeric, sales_points_delta numeric,
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
  k int; v_calc jsonb; v_prev numeric := 0; v_cum numeric; v_f numeric;
BEGIN
  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, p_any_date_in_quarter);
  v_weeks := (v_cycle.cycle_end - v_cycle.cycle_start + 1) / 7;

  -- production months = calendar quarter containing the cycle midpoint
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

  FOR k IN 1..v_weeks LOOP
    v_f := k::numeric / v_weeks;
    v_calc := public.compute_sp_from_production(
                v_auto_apps * v_f, v_fire_apps * v_f, v_life_prem * v_f,
                v_health_prem * v_f, v_auto_prem * v_f, v_fire_prem * v_f);
    v_cum := (v_calc->'commission'->>'total_commission')::numeric;

    week_no            := k;
    week_ending        := v_cycle.cycle_start + (k * 7) - 1;
    sales_points_cum   := v_cum;
    sales_points_delta := ROUND(v_cum - v_prev, 2);
    cum_auto_apps      := ROUND(v_auto_apps * v_f, 2);
    cum_fire_apps      := ROUND(v_fire_apps * v_f, 2);
    cum_life_prem      := ROUND(v_life_prem * v_f, 2);
    cum_pc_prem        := ROUND((v_auto_prem + v_fire_prem) * v_f, 2);
    pc_rate            := (v_calc->'rates'->>'pc_rate_capped')::numeric;
    lh_rate            := (v_calc->'rates'->>'lh_rate_capped')::numeric;
    RETURN NEXT;
    v_prev := v_cum;
  END LOOP;
END;
$function$;

COMMENT ON FUNCTION public.sp_walk_quarter(uuid, uuid, date) IS
  'Even-spread Sales Points walk for one person over one SF quarter (boundaries from current_cycle_info). Spreads the quarter''s producer_production evenly across the quarter''s Saturdays and returns cumulative Sales Points at each week via compute_sp_from_production. Week N equals the quarter total. Use it to backfill weekly_cpr_team_detail.sales_points for quarters where only quarter totals exist.';

GRANT EXECUTE ON FUNCTION public.compute_sp_from_production(numeric, numeric, numeric, numeric, numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sp_walk_quarter(uuid, uuid, date) TO authenticated;
