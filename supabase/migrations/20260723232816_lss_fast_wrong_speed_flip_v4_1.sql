-- Fix: when accuracy signal is negative and speed signal is positive,
-- flip the speed signal sign. Fast + wrong reads as rushing/guessing,
-- not fast-and-competent, so it should count as a penalty rather than a
-- reward. All other combinations unchanged. Quadratic amplifier on
-- negative linear signals continues to fire and now correctly amplifies
-- fast+wrong cases (previously they had positive linear signals so the
-- amplifier never engaged).

CREATE OR REPLACE FUNCTION public._cts_lss_apply_v4(
  p_base numeric,
  p_acc_wt numeric,
  p_spd_wt numeric,
  p_acc_signal numeric,
  p_spd_signal numeric,
  p_rel_factor numeric,
  p_has_lss boolean
)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_lin_signal numeric := 0;
  v_lss_delta numeric := 0;
  v_pre_rel numeric;
  v_spd_eff numeric;
BEGIN
  IF p_base IS NULL THEN RETURN NULL; END IF;
  IF p_has_lss THEN
    -- Fast-when-wrong flip: rushing is a penalty, not a reward.
    IF p_acc_signal < 0 AND p_spd_signal > 0 THEN
      v_spd_eff := -p_spd_signal;
    ELSE
      v_spd_eff := p_spd_signal;
    END IF;
    v_lin_signal := (COALESCE(p_acc_wt, 0) * p_acc_signal + COALESCE(p_spd_wt, 0) * v_spd_eff) / 2.0;
    v_lss_delta := 15.0 * v_lin_signal;
    IF v_lin_signal < 0 THEN
      v_lss_delta := v_lss_delta - 20.0 * v_lin_signal * v_lin_signal;
    END IF;
  END IF;
  v_pre_rel := GREATEST(0, LEAST(100, ROUND(p_base + v_lss_delta)));
  IF v_pre_rel >= 50 THEN
    RETURN GREATEST(0, LEAST(100, ROUND(50 + (v_pre_rel - 50) * COALESCE(p_rel_factor, 1.0))))::int;
  ELSE
    RETURN GREATEST(0, LEAST(100, v_pre_rel))::int;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public._cts_lss_delta_v4(
  p_acc_wt numeric,
  p_spd_wt numeric,
  p_acc_signal numeric,
  p_spd_signal numeric,
  p_has_lss boolean
)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_lin_signal numeric;
  v_delta numeric;
  v_spd_eff numeric;
BEGIN
  IF NOT p_has_lss THEN RETURN 0; END IF;
  -- Fast-when-wrong flip: keeps delta preview in sync with apply.
  IF p_acc_signal < 0 AND p_spd_signal > 0 THEN
    v_spd_eff := -p_spd_signal;
  ELSE
    v_spd_eff := p_spd_signal;
  END IF;
  v_lin_signal := (COALESCE(p_acc_wt, 0) * p_acc_signal + COALESCE(p_spd_wt, 0) * v_spd_eff) / 2.0;
  v_delta := 15.0 * v_lin_signal;
  IF v_lin_signal < 0 THEN
    v_delta := v_delta - 20.0 * v_lin_signal * v_lin_signal;
  END IF;
  RETURN ROUND(v_delta, 2);
END;
$function$;
