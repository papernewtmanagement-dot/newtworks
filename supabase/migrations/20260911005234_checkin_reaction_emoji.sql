-- Peter 2026-09-10: check-in reactions must cheer people on and can show how
-- someone is tracking. Replaces the random emoji pool (which included praying
-- hands). One emoji per check-in, picked from this week's quote pace:
--   👍 logged (below pace, or no quote seat)   👏 on pace (100%+)
--   🔥 ahead of pace (125%+)                    🏆 way ahead (150%+)
-- Nobody gets a negative mark. Behind pace still gets the plain "logged" thumbs up.
--
-- Why weekly quotes and not quarterly sales points: a reaction lands every day,
-- so it should track the goal a person can move this week. Proximal goals with
-- frequent feedback raise effort and self-efficacy more than distal ones
-- (Bandura & Schunk 1981, J. Pers. Soc. Psych. 41:586; Locke & Latham 2002,
-- Am. Psych. 57:705). Feedback aimed at progress on the task, not at the person,
-- is what moves performance (Kluger & DeNisi 1996, Psych. Bull. 119:254).
-- Quarterly sales points are lagging and lumpy; one slow month would pin a
-- person at the bottom tier for the rest of the quarter no matter how hard they work.
--
-- Weekly targets per seat mirror compute_wtw_week_targets: sales seat 15,
-- retention seat 8, scaled by the same end-date seat weight. Keep in step with it.

CREATE OR REPLACE FUNCTION public.checkin_reaction_emoji(
  p_agency_id uuid, p_team_id uuid, p_quotes integer,
  p_checkin_date date, p_checkin_type text)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_week_start date := p_checkin_date - extract(dow FROM p_checkin_date)::int;
  v_monday date := v_week_start + 1;
  v_friday date := v_week_start + 5;
  v_target numeric;
  v_end date;
  v_weight numeric := 1;
  v_days numeric;
  v_expected numeric;
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

  v_expected := v_target * v_weight * v_days / 5.0;
  v_ratio := p_quotes / v_expected;

  RETURN CASE
    WHEN v_ratio >= 1.5  THEN '🏆'
    WHEN v_ratio >= 1.25 THEN '🔥'
    WHEN v_ratio >= 1.0  THEN '👏'
    ELSE '👍'
  END;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.checkin_reaction_emoji(uuid, uuid, integer, date, text) TO service_role;