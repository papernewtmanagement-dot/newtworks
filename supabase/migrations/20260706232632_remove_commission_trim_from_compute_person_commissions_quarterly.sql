-- 2026-07-06: Remove ×0.80 commission trim per Peter's redirect.
-- Was locked 2026-07-02 as "Peter-side adjustment" but that framing was a misunderstanding.
-- Commissions now flow through at full uncapped rate (still subject to base rate + enhancements + 6%/18% caps).
-- Only the c_trim constant changes; all other logic preserved.
-- Output field names pc_rate_trimmed / lh_rate_trimmed kept for downstream compatibility (jsonb key stability).

CREATE OR REPLACE FUNCTION public.compute_person_commissions_quarterly(p_agency_id uuid, p_team_member_id uuid, p_period_year integer, p_quarter_num integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_month_start   int := (p_quarter_num - 1) * 3 + 1;
  v_month_end     int := p_quarter_num * 3;

  v_auto_apps     int  := 0;
  v_fire_apps     int  := 0;
  v_life_prem     numeric := 0;
  v_health_prem   numeric := 0;
  v_auto_prem     numeric := 0;
  v_fire_prem     numeric := 0;

  -- Rate calc constants (synced to SF Team Incentives builder screenshot 2026-07-03)
  c_pc_step_pct   CONSTANT numeric := 0.0006;   -- 0.06%
  c_lh_step_pct   CONSTANT numeric := 0.0018;   -- 0.18%
  c_pc_cap        CONSTANT numeric := 0.06;     -- 6%
  c_lh_cap        CONSTANT numeric := 0.18;     -- 18%
  c_trim          CONSTANT numeric := 1.00;     -- Trim removed 2026-07-06 (was 0.80, was misunderstanding on Claude's part per Peter). Constant retained for reversibility; output jsonb field names unchanged.
  c_pc_life_dollar_step CONSTANT numeric := 200;
  c_lh_life_dollar_step CONSTANT numeric := 200;
  c_auto_app_step CONSTANT int := 6;
  c_fire_app_step CONSTANT int := 3;

  v_life_tiers_pc  int;
  v_auto_tiers     int;
  v_fire_tiers     int;
  v_life_tiers_lh  int;

  v_pc_rate_raw     numeric;
  v_pc_rate_capped  numeric;
  v_pc_rate_trimmed numeric;
  v_lh_rate_raw     numeric;
  v_lh_rate_capped  numeric;
  v_lh_rate_trimmed numeric;

  v_pc_premium_base numeric;
  v_lh_premium_base numeric;
  v_pc_commission   numeric;
  v_lh_commission   numeric;
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

  v_life_tiers_pc := LEAST(99, FLOOR(v_life_prem / c_pc_life_dollar_step)::int);
  v_auto_tiers    := LEAST(99, FLOOR(v_auto_apps::numeric / c_auto_app_step)::int);
  v_fire_tiers    := LEAST(99, FLOOR(v_fire_apps::numeric / c_fire_app_step)::int);
  v_life_tiers_lh := LEAST(99, FLOOR(v_life_prem / c_lh_life_dollar_step)::int);

  v_pc_rate_raw := c_pc_step_pct
                 + (v_life_tiers_pc * c_pc_step_pct)
                 + (v_auto_tiers    * c_pc_step_pct)
                 + (v_fire_tiers    * c_pc_step_pct);
  v_pc_rate_capped  := LEAST(c_pc_cap, v_pc_rate_raw);
  v_pc_rate_trimmed := v_pc_rate_capped * c_trim;

  v_lh_rate_raw := c_lh_step_pct + (v_life_tiers_lh * c_lh_step_pct);
  v_lh_rate_capped  := LEAST(c_lh_cap, v_lh_rate_raw);
  v_lh_rate_trimmed := v_lh_rate_capped * c_trim;

  v_pc_premium_base := v_auto_prem + v_fire_prem;
  v_lh_premium_base := v_life_prem + v_health_prem;
  v_pc_commission   := v_pc_rate_trimmed * v_pc_premium_base;
  v_lh_commission   := v_lh_rate_trimmed * v_lh_premium_base;

  RETURN jsonb_build_object(
    'agency_id',       p_agency_id,
    'team_member_id',  p_team_member_id,
    'period_year',     p_period_year,
    'quarter_num',     p_quarter_num,
    'month_range',     jsonb_build_array(v_month_start, v_month_end),
    'issued', jsonb_build_object(
      'auto_apps',      v_auto_apps,
      'fire_apps',      v_fire_apps,
      'life_premium',   v_life_prem,
      'health_premium', v_health_prem,
      'auto_premium',   v_auto_prem,
      'fire_premium',   v_fire_prem
    ),
    'tiers', jsonb_build_object(
      'life_tiers_pc_at_200', v_life_tiers_pc,
      'auto_tiers_at_6',      v_auto_tiers,
      'fire_tiers_at_3',      v_fire_tiers,
      'life_tiers_lh_at_200', v_life_tiers_lh
    ),
    'rates', jsonb_build_object(
      'pc_rate_raw',      ROUND(v_pc_rate_raw, 6),
      'pc_rate_capped',   ROUND(v_pc_rate_capped, 6),
      'pc_rate_trimmed',  ROUND(v_pc_rate_trimmed, 6),
      'lh_rate_raw',      ROUND(v_lh_rate_raw, 6),
      'lh_rate_capped',   ROUND(v_lh_rate_capped, 6),
      'lh_rate_trimmed',  ROUND(v_lh_rate_trimmed, 6)
    ),
    'commission', jsonb_build_object(
      'pc_premium_base',  v_pc_premium_base,
      'lh_premium_base',  v_lh_premium_base,
      'pc_commission',    ROUND(v_pc_commission, 2),
      'lh_commission',    ROUND(v_lh_commission, 2),
      'total_commission', ROUND(v_pc_commission + v_lh_commission, 2)
    ),
    'sf_config_synced', '2026-07-03',
    'trim_removed',     '2026-07-06',
    'computed_at', now()
  );
END;
$function$;
