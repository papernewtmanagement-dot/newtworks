-- Point refresh_daily_checklist_huddle_summary at public.manuals instead of
-- public.processes. Reads and writes now go through the unified table.
-- The "Daily Wrap-up" page lives with manual_type='processes'.
CREATE OR REPLACE FUNCTION public.refresh_daily_checklist_huddle_summary(p_agency_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
  v_summary TEXT;
  v_current TEXT;
  v_new TEXT;
BEGIN
  v_summary := public.render_huddle_summary_md(p_agency_id);

  SELECT content INTO v_current
  FROM public.manuals
  WHERE agency_id = p_agency_id
    AND manual_type = 'processes'
    AND title = 'Daily Wrap-up';
  IF NOT FOUND THEN RETURN; END IF;

  IF v_current NOT LIKE '%<!-- HUDDLE_SUMMARY:START -->%' THEN
    RETURN;
  END IF;

  v_new := regexp_replace(
    v_current,
    '<!-- HUDDLE_SUMMARY:START -->[\s\S]*?<!-- HUDDLE_SUMMARY:END -->',
    '<!-- HUDDLE_SUMMARY:START -->' || E'\n' || v_summary || E'\n' || '<!-- HUDDLE_SUMMARY:END -->',
    'g'
  );

  IF v_new IS DISTINCT FROM v_current THEN
    UPDATE public.manuals
    SET content = v_new, updated_at = NOW()
    WHERE agency_id = p_agency_id
      AND manual_type = 'processes'
      AND title = 'Daily Wrap-up';
  END IF;
END;
$function$;
