CREATE OR REPLACE FUNCTION public.render_daily_checklist_bridge(p_agency_id uuid, p_today date)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_prev date;
  v_prev_week_end date;
  v_total int;
  v_done int;
  v_open text;
  v_more int;
  v_week_end date;
  v_week_start date;
  v_risk int;
  v_text text;
  c_max_listed CONSTANT int := 6;
BEGIN
  v_prev := public.checklist_prev_workday(p_agency_id, p_today);
  IF v_prev IS NULL THEN RETURN NULL; END IF;
  v_prev_week_end := v_prev + (6 - EXTRACT(DOW FROM v_prev)::int);

  -- Counts for the reported day. Items only count on days they were actually
  -- effective: checklist_items_for_week() gates on the week ending date, which
  -- would otherwise back-date a mid-week item to earlier days in the same week.
  SELECT COUNT(*), COUNT(k.id)
  INTO v_total, v_done
  FROM public.checklist_items_for_week(p_agency_id, v_prev_week_end) i
  LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = v_prev
  WHERE i.effective_from <= v_prev
    AND (i.effective_to IS NULL OR i.effective_to >= v_prev);
  IF COALESCE(v_total, 0) = 0 THEN RETURN NULL; END IF;

  v_text := format('📋 Team list %s: %s of %s cleared', to_char(v_prev, 'Dy Mon FMDD'), v_done, v_total);

  IF v_done = v_total THEN
    v_text := v_text || ' ✅';
  ELSE
    -- Name at most c_max_listed open items, then roll the rest into a count.
    SELECT string_agg(t.title, '; ' ORDER BY t.sort_order, t.title)
    INTO v_open
    FROM (
      SELECT i.title, i.sort_order
      FROM public.checklist_items_for_week(p_agency_id, v_prev_week_end) i
      LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = v_prev
      WHERE i.effective_from <= v_prev
        AND (i.effective_to IS NULL OR i.effective_to >= v_prev)
        AND k.id IS NULL
      ORDER BY i.sort_order, i.title
      LIMIT c_max_listed
    ) t;

    v_more := GREATEST((v_total - v_done) - c_max_listed, 0);
    v_text := v_text || E'\nOpen: ' || v_open;
    IF v_more > 0 THEN
      v_text := v_text || format(' (+%s more on the checklist tab)', v_more);
    END IF;
  END IF;

  -- Running warning for the CPR week p_today sits in: items with any past
  -- workday unticked, counting only days the item was effective.
  v_week_end := p_today + (6 - EXTRACT(DOW FROM p_today)::int);
  v_week_start := v_week_end - 6;
  SELECT COUNT(DISTINCT i.id) INTO v_risk
  FROM public.checklist_items_for_week(p_agency_id, v_week_end) i
  CROSS JOIN LATERAL (
    SELECT g::date AS d
    FROM generate_series(v_week_start, p_today - 1, interval '1 day') g
    WHERE public.checklist_is_workday(p_agency_id, g::date)
  ) d
  LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = d.d
  WHERE k.id IS NULL
    AND i.effective_from <= d.d
    AND (i.effective_to IS NULL OR i.effective_to >= d.d);
  IF COALESCE(v_risk, 0) > 0 THEN
    v_text := v_text || format(E'\nThis week at risk: %s item%s (+1 quote each, per person, if the CPR confirms it)',
                               v_risk, CASE WHEN v_risk = 1 THEN '' ELSE 's' END);
  END IF;
  RETURN v_text;
END;
$function$;