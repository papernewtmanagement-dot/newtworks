-- team_checkins.quotes_week is numeric; take numeric so callers never need a cast.
DROP FUNCTION IF EXISTS public.checkin_reaction_emoji(uuid, uuid, integer, date, text);

CREATE OR REPLACE FUNCTION public.checkin_reaction_emoji(
  p_agency_id uuid, p_team_id uuid, p_quotes numeric,
  p_checkin_date date, p_checkin_type text)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'extensions'
AS $function$
-- Peter 2026-09-10. One cheer-only reaction per check-in, from this week's quote pace:
--   👍 logged (below pace, or no quote seat)   👏 on pace (100%+)
--   🔥 ahead of pace (125%+)                    🏆 way ahead (150%+)
-- Weekly quotes, not quarterly sales points: proximal goals with frequent feedback
-- beat distal ones (Bandura & Schunk 1981; Locke & Latham 2002), and feedback on
-- task progress is what moves performance (Kluger & DeNisi 1996).
-- Seat targets mirror compute_wtw_week_targets (sales 15, retention 8) and its
-- end-date seat weight. Keep in step with it.
DECLARE
  v_week_start date := p_checkin_date - extract(dow FROM p_checkin_date)::int;
  v_monday date := v_week_start + 1;
  v_friday date := v_week_start + 5;
  v_target numeric;
  v_end date;
  v_weight numeric := 1;
  v_days numeric;
  v_ratio numeric;
BEGIN
  IF p_team_id IS NULL OR p_quotes IS NULL THEN RETURN '👍'; END IF;

  IF EXISTS (SELECT 1 FROM public.get_expected_teammates(p_agency_id, 'wtw_am_sales', v_week_start) e WHERE e.team_id = p_team_id) THEN
    v_target := 15;
  ELSIF EXISTS (SELECT 1 FROM public.get_expected_teammates(p_agency_id, 'wtw_am_retention', v_week_start) e WHERE e.team_id = p_team_id) THEN
    v_target := 8;
  ELSE
    RETURN '👍';
  END IF;

  SELECT end_date INTO v_end FROM public.team WHERE id = p_team_id;
  IF v_end IS NOT NULL THEN
    v_weight := LEAST(5, GREATEST(0, (LEAST(v_end, v_friday) - v_monday) + 1))::numeric / 5.0;
  END IF;
  IF v_weight <= 0 THEN RETURN '👍'; END IF;

  -- Workdays done by this check-in. Midday counts half of today.
  v_days := LEAST(extract(dow FROM p_checkin_date)::int, 5);
  IF p_checkin_type = 'midday' THEN v_days := v_days - 0.5; END IF;
  v_days := GREATEST(v_days, 0.5);

  v_ratio := p_quotes / (v_target * v_weight * v_days / 5.0);

  RETURN CASE
    WHEN v_ratio >= 1.5  THEN '🏆'
    WHEN v_ratio >= 1.25 THEN '🔥'
    WHEN v_ratio >= 1.0  THEN '👏'
    ELSE '👍'
  END;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.checkin_reaction_emoji(uuid, uuid, numeric, date, text) TO service_role;