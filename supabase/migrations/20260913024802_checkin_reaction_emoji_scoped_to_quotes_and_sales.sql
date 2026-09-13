-- Extends the same four tiers to quotes AND sales together, as the check-in
-- summary build requires. p_sales is THIS WEEK'S sales points increment; leave it
-- NULL and the function behaves exactly as before (quotes only), so the older
-- caller in the telegram edge function keeps working.
--   😴 behind on both   👏 on pace on one   🔥 on pace on both   🏆 150%+ on both
-- Weekly seat targets mirror compute_wtw_week_targets: quotes 15 sales / 8
-- retention, sales points 100 sales / 50 retention. Keep in step with it.
CREATE OR REPLACE FUNCTION public.checkin_reaction_emoji(
  p_agency_id uuid, p_team_id uuid, p_quotes numeric, p_checkin_date date, p_checkin_type text,
  p_sales numeric DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_week_start date := p_checkin_date - extract(dow FROM p_checkin_date)::int;
  v_monday date := v_week_start + 1;
  v_friday date := v_week_start + 5;
  v_q_target numeric; v_s_target numeric;
  v_end date;
  v_weight numeric := 1;
  v_days numeric;
  v_q_ratio numeric; v_s_ratio numeric;
  v_on_pace int := 0; v_way_ahead int := 0; v_measures int := 0;
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
  v_measures := 1;
  IF v_q_ratio >= 1.0 THEN v_on_pace := v_on_pace + 1; END IF;
  IF v_q_ratio >= 1.5 THEN v_way_ahead := v_way_ahead + 1; END IF;

  IF p_sales IS NOT NULL THEN
    v_s_ratio := p_sales / (v_s_target * v_weight * v_days / 5.0);
    v_measures := 2;
    IF v_s_ratio >= 1.0 THEN v_on_pace := v_on_pace + 1; END IF;
    IF v_s_ratio >= 1.5 THEN v_way_ahead := v_way_ahead + 1; END IF;
  END IF;

  RETURN CASE
    WHEN v_way_ahead = v_measures THEN '🏆'
    WHEN v_on_pace  = v_measures THEN '🔥'
    WHEN v_on_pace  > 0          THEN '👏'
    ELSE '😴'
  END;
END;
$function$;
