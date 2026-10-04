CREATE OR REPLACE FUNCTION public.compute_sp_from_production(p_auto_apps numeric, p_fire_apps numeric, p_life_prem numeric, p_health_prem numeric, p_auto_prem numeric, p_fire_prem numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  -- Team commission rate structure. SINGLE COPY: every reader goes through this function.
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
  v_pc_rate_no_life numeric; v_life_own numeric; v_life_bump numeric;
  v_lt2_pc int; v_lt2_lh int; v_pc_rate2 numeric; v_lh_rate2 numeric; v_next_step_pay numeric;
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

  -- What life pays, all in (Peter 2026-10-04, Scoreboard line): its own L&H rate on life
  -- premium, plus what its tiers added to the P&C rate on all P&C premium. And what the
  -- next life step ($200) would add to total commission, worked the same way.
  v_pc_rate_no_life := LEAST(c_pc_cap, c_pc_base_pct + (v_auto_tiers + v_fire_tiers) * c_pc_step_pct) * c_trim;
  v_life_bump := (v_pc_rate_trimmed - v_pc_rate_no_life) * v_pc_premium_base;
  v_life_own  := v_lh_rate_trimmed * v_life_prem;
  v_lt2_pc := LEAST(c_life_rep_cap, FLOOR((v_life_prem + c_pc_life_dollar_step) / c_pc_life_dollar_step)::int);
  v_lt2_lh := LEAST(c_life_rep_cap, FLOOR((v_life_prem + c_pc_life_dollar_step) / c_lh_life_dollar_step)::int);
  v_pc_rate2 := LEAST(c_pc_cap, c_pc_base_pct + (v_lt2_pc + v_auto_tiers + v_fire_tiers) * c_pc_step_pct) * c_trim;
  v_lh_rate2 := LEAST(c_lh_cap, c_lh_base_pct + v_lt2_lh * c_lh_step_pct) * c_trim;
  v_next_step_pay := (v_pc_rate2 * v_pc_premium_base + v_lh_rate2 * (v_lh_premium_base + c_pc_life_dollar_step))
                     - (v_pc_commission + v_lh_commission);

  RETURN jsonb_build_object(
    'tiers', jsonb_build_object(
      'life_tiers_pc_at_200', v_life_tiers_pc,
      'auto_tiers_at_6',      v_auto_tiers,
      'fire_tiers_at_3',      v_fire_tiers,
      'life_tiers_lh_at_200', v_life_tiers_lh,
      'auto_app_step',        c_auto_app_step,
      'fire_app_step',        c_fire_app_step,
      'life_dollar_step',     c_pc_life_dollar_step,
      'auto_rep_cap',         c_auto_rep_cap,
      'fire_rep_cap',         c_fire_rep_cap,
      'life_rep_cap',         c_life_rep_cap),
    'rates', jsonb_build_object(
      'pc_base_pct',      c_pc_base_pct,
      'pc_cap',           c_pc_cap,
      'lh_cap',           c_lh_cap,
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
    'life', jsonb_build_object(
      'premium',       v_life_prem,
      'own',           ROUND(v_life_own, 2),
      'bump',          ROUND(v_life_bump, 2),
      'pay',           ROUND(v_life_own + v_life_bump, 2),
      'pct',           CASE WHEN v_life_prem > 0 THEN ROUND(100 * (v_life_own + v_life_bump) / v_life_prem, 1) END,
      'step_dollars',  c_pc_life_dollar_step,
      'next_step_pay', ROUND(v_next_step_pay, 2)));
END;
$function$

