-- Peter 2026-09-14:
-- 1. CPR audit line drops "week ending" and reads "19/21 ✅" instead of
--    "19 of 21 cleared". The daily "Team list" line is unchanged.
-- 2. The EOD header drops "(last week close)" and carries the outcome on the
--    same line, shortened to the emoji plus Won or Missed.
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
  v_week_end date;
  v_week_start date;
  v_risk int;
  v_text text;
  v_report_id uuid;
  v_audited int;
  v_missed int;
BEGIN
  v_prev := public.checklist_prev_workday(p_agency_id, p_today);
  IF v_prev IS NULL THEN RETURN NULL; END IF;
  v_prev_week_end := v_prev + (6 - EXTRACT(DOW FROM v_prev)::int);
  v_week_end := p_today + (6 - EXTRACT(DOW FROM p_today)::int);
  v_week_start := v_week_end - 6;

  -- First workday of a new CPR week (normally Monday). The daily ticks for last
  -- week are closed, so the kickoff reports the FINAL CPR AUDIT for that week
  -- instead of the last day's ticks (Peter 2026-09-14). Only when that week's
  -- report was actually audited; otherwise fall through to the daily list.
  IF v_prev_week_end < v_week_end THEN
    SELECT r.id INTO v_report_id
    FROM public.weekly_cpr_reports r
    WHERE r.agency_id = p_agency_id AND r.week_ending_date = v_prev_week_end;

    SELECT COUNT(*) INTO v_audited
    FROM public.weekly_cpr_checklist c
    WHERE c.weekly_cpr_report_id = v_report_id;

    IF v_report_id IS NOT NULL AND COALESCE(v_audited, 0) > 0 THEN
      SELECT COUNT(*) INTO v_total
      FROM public.checklist_items_for_week(p_agency_id, v_prev_week_end);

      SELECT COUNT(*), string_agg('• ' || m.title, E'\n' ORDER BY m.sort_order, m.title)
      INTO v_missed, v_open
      FROM public.cpr_checklist_team_miss_items(p_agency_id, v_prev_week_end) m;

      v_text := format('📋 CPR audit, %s: %s/%s ✅',
                       to_char(v_prev_week_end, 'Mon FMDD'),
                       COALESCE(v_total, 0) - COALESCE(v_missed, 0), COALESCE(v_total, 0));
      IF COALESCE(v_missed, 0) > 0 THEN
        v_text := v_text || E', missed:\n' || v_open;
      END IF;
      RETURN v_text;
    END IF;
  END IF;

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
    -- Only what was missed, one item per line as bullets (Peter 2026-09-14).
    SELECT string_agg('• ' || i.title, E'\n' ORDER BY i.sort_order, i.title)
    INTO v_open
    FROM public.checklist_items_for_week(p_agency_id, v_prev_week_end) i
    LEFT JOIN public.daily_checklist_ticks k ON k.item_id = i.id AND k.tick_date = v_prev
    WHERE i.effective_from <= v_prev
      AND (i.effective_to IS NULL OR i.effective_to >= v_prev)
      AND k.id IS NULL;
    v_text := v_text || E', missed:\n' || v_open;
  END IF;

  -- Running warning for the CPR week p_today sits in: items with any past
  -- workday unticked, counting only days the item was effective.
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