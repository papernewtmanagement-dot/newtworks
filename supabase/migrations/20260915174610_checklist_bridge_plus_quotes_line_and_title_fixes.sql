-- Ledger record of two changes made live earlier in the same session.
UPDATE public.checklist_items SET title='Opportunity Lists 01-14 done'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='opp_lists';
UPDATE public.checklist_items SET title='Claims touched and reviewed'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND item_key='claims';

CREATE OR REPLACE FUNCTION public.render_daily_checklist_bridge(p_agency_id uuid, p_today date)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_prev date; v_prev_week_end date; v_total int; v_done int; v_open text;
  v_week_end date; v_week_start date; v_risk int; v_text text;
  v_report_id uuid; v_audited int; v_missed int;
BEGIN
  v_prev := public.checklist_prev_workday(p_agency_id, p_today);
  IF v_prev IS NULL THEN RETURN NULL; END IF;
  v_prev_week_end := v_prev + (6 - EXTRACT(DOW FROM v_prev)::int);
  v_week_end := p_today + (6 - EXTRACT(DOW FROM p_today)::int);
  v_week_start := v_week_end - 6;

  IF v_prev_week_end < v_week_end THEN
    SELECT r.id INTO v_report_id FROM public.weekly_cpr_reports r
    WHERE r.agency_id = p_agency_id AND r.week_ending_date = v_prev_week_end;

    SELECT COUNT(*) INTO v_audited FROM public.weekly_cpr_checklist c
    WHERE c.weekly_cpr_report_id = v_report_id;

    IF v_report_id IS NOT NULL AND COALESCE(v_audited, 0) > 0 THEN
      SELECT COUNT(*) INTO v_total FROM public.checklist_items_for_week(p_agency_id, v_prev_week_end);

      SELECT COUNT(*), string_agg('• ' || public.checklist_short_title(m.title), E'\n' ORDER BY m.sort_order, m.title)
      INTO v_missed, v_open
      FROM public.cpr_checklist_team_miss_items(p_agency_id, v_prev_week_end) m;

      v_text := format('✅ Checklist, %s: %s/%s', to_char(v_prev_week_end, 'Mon FMDD'),
                       COALESCE(v_total, 0) - COALESCE(v_missed, 0), COALESCE(v_total, 0));
      IF COALESCE(v_missed, 0) > 0 THEN v_text := v_text || E':\n' || v_open; END IF;
      RETURN v_text;
    END IF;
  END IF;

  SELECT COUNT(*), COUNT(k.id) INTO v_total, v_done
  FROM public.checklist_items_for_week(p_agency_id, v_prev_week_end) i
  LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = v_prev
  WHERE i.effective_from <= v_prev AND (i.effective_to IS NULL OR i.effective_to >= v_prev);
  IF COALESCE(v_total, 0) = 0 THEN RETURN NULL; END IF;

  v_text := format('✅ Checklist, %s: %s/%s', to_char(v_prev, 'Mon FMDD'), v_done, v_total);

  IF v_done < v_total THEN
    SELECT string_agg('• ' || public.checklist_short_title(i.title), E'\n' ORDER BY i.sort_order, i.title)
    INTO v_open
    FROM public.checklist_items_for_week(p_agency_id, v_prev_week_end) i
    LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = v_prev
    WHERE i.effective_from <= v_prev AND (i.effective_to IS NULL OR i.effective_to >= v_prev)
      AND k.id IS NULL;
    v_text := v_text || E':\n' || v_open;
  END IF;

  SELECT COUNT(DISTINCT i.id) INTO v_risk
  FROM public.checklist_items_for_week(p_agency_id, v_week_end) i
  CROSS JOIN LATERAL (
    SELECT g::date AS d FROM generate_series(v_week_start, p_today - 1, interval '1 day') g
    WHERE public.checklist_is_workday(p_agency_id, g::date)
  ) d
  LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = d.d
  WHERE k.id IS NULL AND i.effective_from <= d.d
    AND (i.effective_to IS NULL OR i.effective_to >= d.d);
  IF COALESCE(v_risk, 0) > 0 THEN
    -- Short form, Peter 2026-09-15.
    v_text := v_text || format(E'\n+%s quote%s if not cleared',
                               v_risk, CASE WHEN v_risk = 1 THEN '' ELSE 's' END);
  END IF;
  RETURN v_text;
END;
$function$;
