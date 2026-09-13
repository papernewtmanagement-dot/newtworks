-- daily_checklist_state now carries the per-item help text (info icon on the
-- Checklist tab) and says whether this is the last workday of the CPR week,
-- which is the cue that opens the weekly wrap-up.
CREATE OR REPLACE FUNCTION public.daily_checklist_state(p_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_me uuid := public.current_team_member_id();
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_day date;
  v_week_end date;
  v_week_start date;
  v_prev date;
  v_leader text;
  v_items jsonb;
  v_carry jsonb;
  v_risk jsonb;
  v_risk_count int;
  v_last_workday boolean;
BEGIN
  v_day := COALESCE(p_date, v_today);
  IF v_day > v_today THEN v_day := v_today; END IF;
  IF NOT public.checklist_is_workday(v_agency, v_day) THEN
    v_day := COALESCE(public.checklist_prev_workday(v_agency, v_day), v_day);
  END IF;
  v_week_end := v_day + (6 - EXTRACT(DOW FROM v_day)::int);
  v_week_start := v_week_end - 6;
  v_prev := public.checklist_prev_workday(v_agency, v_day);

  -- No workday left in this CPR week after today, so the week wraps here.
  SELECT NOT EXISTS (
    SELECT 1 FROM generate_series(v_day + 1, v_week_end, interval '1 day') g
    WHERE public.checklist_is_workday(v_agency, g::date)
  ) INTO v_last_workday;

  SELECT COALESCE(NULLIF(t.nickname, ''), t.first_name) INTO v_leader
  FROM public.agency_huddle_config c
  JOIN public.team t ON t.id = c.current_week_leader_team_id
  WHERE c.agency_id = v_agency;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', i.id, 'title', i.title, 'sort_order', i.sort_order,
           'help_text', i.help_text, 'help_excerpt_id', i.help_excerpt_id,
           'ticked_by', COALESCE(NULLIF(tm.nickname, ''), tm.first_name),
           'ticked_at', k.ticked_at) ORDER BY i.sort_order, i.title), '[]'::jsonb)
  INTO v_items
  FROM public.checklist_items_for_week(v_agency, v_week_end) i
  LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = v_day
  LEFT JOIN public.team tm ON tm.id = k.ticked_by;

  IF v_prev IS NOT NULL THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', i.id, 'title', i.title) ORDER BY i.sort_order, i.title), '[]'::jsonb)
    INTO v_carry
    FROM public.checklist_items_for_week(v_agency, v_prev + (6 - EXTRACT(DOW FROM v_prev)::int)) i
    LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = v_prev
    WHERE k.id IS NULL;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', r.id, 'title', r.title, 'days', r.days) ORDER BY r.sort_order, r.title), '[]'::jsonb),
         COUNT(*)
  INTO v_risk, v_risk_count
  FROM (
    SELECT i.id, i.title, i.sort_order, jsonb_agg(to_char(d.d, 'Dy') ORDER BY d.d) AS days
    FROM public.checklist_items_for_week(v_agency, v_week_end) i
    CROSS JOIN LATERAL (
      SELECT g::date AS d
      FROM generate_series(v_week_start, v_day - 1, interval '1 day') g
      WHERE public.checklist_is_workday(v_agency, g::date)
    ) d
    LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = d.d
    WHERE k.id IS NULL
    GROUP BY i.id, i.title, i.sort_order
  ) r;

  RETURN jsonb_build_object(
    'date', v_day,
    'today', v_today,
    'is_today', v_day = v_today,
    'label', to_char(v_day, 'Dy Mon FMDD'),
    'me', v_me,
    'leader', v_leader,
    'week_ending', v_week_end,
    'is_last_workday', COALESCE(v_last_workday, false),
    'items', v_items,
    'carry', CASE WHEN v_prev IS NULL THEN NULL
                  ELSE jsonb_build_object('date', v_prev, 'label', to_char(v_prev, 'Dy Mon FMDD'), 'open', COALESCE(v_carry, '[]'::jsonb)) END,
    'at_risk', v_risk,
    'at_risk_count', v_risk_count
  );
END;
$function$;
