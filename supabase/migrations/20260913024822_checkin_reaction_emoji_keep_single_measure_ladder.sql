-- Correction to the previous migration: with p_sales NULL the function must keep
-- Peter's locked single-measure ladder (1.0 👏 / 1.25 🔥 / 1.5 🏆). Only the
-- two-measure path uses the both/one shape.
CREATE OR REPLACE FUNCTION public.checkin_reaction_emoji(
  p_agency_id uuid, p_team_id uuid, p_quotes numeric, p_checkin_date date, p_checkin_type text,
  p_sales numeric DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'extensions'
AS $function$
-- Peter 2026-09-10, bottom tier changed 2026-09-11, sales added 2026-09-12.
-- Quotes only (p_sales NULL): 😴 behind / 👏 on pace 100%+ / 🔥 ahead 125%+ / 🏆 150%+.
-- Quotes AND sales (p_sales given): 😴 behind on both / 👏 on pace on one /
-- 🔥 on pace on both / 🏆 150%+ on both.
-- No 👍 anywhere: it reads as praise for being behind, and it is the emoji the
-- team reacts with to acknowledge a check-in, so it cannot also be a score.
-- Weekly seat targets mirror compute_wtw_week_targets: quotes 15 sales / 8
-- retention, sales points 100 sales / 50 retention. Keep in step with it.
-- Weekly, not quarterly: proximal goals with frequent feedback beat distal ones
-- (Bandura & Schunk 1981; Locke & Latham 2002).
DECLARE
  v_week_start date := p_checkin_date - extract(dow FROM p_checkin_date)::int;
  v_monday date := v_week_start + 1;
  v_friday date := v_week_start + 5;
  v_q_target numeric; v_s_target numeric;
  v_end date;
  v_weight numeric := 1;
  v_days numeric;
  v_q_ratio numeric; v_s_ratio numeric;
BEGIN
  IF p_team_id IS NULL OR p_quotes IS NULL THEN RETURN '😴'; END IF;

  IF EXISTS (SELECT 1 FROM public.get_expected_teammates(p_agency_id, 'wtw_am_sales', v_week_start) e WHERE e.team_id = p_team_id) THEN
    v_q_target := 15; v_s_target := 100;
  ELSIF EXISTS (SELECT 1 FROM public.get_expected_teammates(p_agency_id, 'wtw_am_retention', v_week_start) e WHERE e.team_id = p_team_id) THEN
    v_q_target := 8; v_s_target := 50;
  ELSE
    RETURN '😴';
  END IF;

  SELECT end_date INTO v_end FROM public.team WHERE id = p_team_id;
  IF v_end IS NOT NULL THEN
    v_weight := LEAST(5, GREATEST(0, (LEAST(v_end, v_friday) - v_monday) + 1))::numeric / 5.0;
  END IF;
  IF v_weight <= 0 THEN RETURN '😴'; END IF;

  -- Workdays done by this check-in. Midday counts half of today.
  v_days := LEAST(extract(dow FROM p_checkin_date)::int, 5);
  IF p_checkin_type = 'midday' THEN v_days := v_days - 0.5; END IF;
  v_days := GREATEST(v_days, 0.5);

  v_q_ratio := p_quotes / (v_q_target * v_weight * v_days / 5.0);

  IF p_sales IS NULL THEN
    RETURN CASE
      WHEN v_q_ratio >= 1.5  THEN '🏆'
      WHEN v_q_ratio >= 1.25 THEN '🔥'
      WHEN v_q_ratio >= 1.0  THEN '👏'
      ELSE '😴'
    END;
  END IF;

  v_s_ratio := p_sales / (v_s_target * v_weight * v_days / 5.0);

  RETURN CASE
    WHEN v_q_ratio >= 1.5 AND v_s_ratio >= 1.5 THEN '🏆'
    WHEN v_q_ratio >= 1.0 AND v_s_ratio >= 1.0 THEN '🔥'
    WHEN v_q_ratio >= 1.0 OR  v_s_ratio >= 1.0 THEN '👏'
    ELSE '😴'
  END;
END;
$function$;
