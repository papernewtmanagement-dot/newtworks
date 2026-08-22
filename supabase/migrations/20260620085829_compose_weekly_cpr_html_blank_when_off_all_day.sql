-- Email-side parity for the CPRDetail webpage Hours change:
-- Off-entire-day cells (hours NULL or 0) render as '—' with no location icon.
-- Surgical DO block patches each day's cell pattern in compose_weekly_cpr_html.

DO $migration$
DECLARE
  v_src text;
  v_new text;
  v_day text;
  v_old_pattern text;
  v_new_pattern text;
  v_replaced int := 0;
BEGIN
  v_src := pg_get_functiondef('public.compose_weekly_cpr_html'::regproc);

  FOREACH v_day IN ARRAY ARRAY['mon','tue','wed','thu','fri'] LOOP
    v_old_pattern := 'COALESCE(hp.' || v_day || '_h::text, ''0'') || '' '' || CASE WHEN hp.' || v_day || '_loc=''remote'' THEN ''🟣'' WHEN hp.' || v_day || '_loc=''in_office'' THEN ''🟢'' ELSE '''' END';
    v_new_pattern := 'CASE WHEN COALESCE(hp.' || v_day || '_h, 0) = 0 THEN ''—'' ELSE hp.' || v_day || '_h::text || '' '' || CASE WHEN hp.' || v_day || '_loc=''remote'' THEN ''🟣'' WHEN hp.' || v_day || '_loc=''in_office'' THEN ''🟢'' ELSE '''' END END';

    IF position(v_old_pattern in v_src) = 0 THEN
      RAISE EXCEPTION 'Pattern not found for day %', v_day;
    END IF;

    v_src := replace(v_src, v_old_pattern, v_new_pattern);
    v_replaced := v_replaced + 1;
  END LOOP;

  IF v_replaced <> 5 THEN
    RAISE EXCEPTION 'Expected 5 day replacements, got %', v_replaced;
  END IF;

  EXECUTE v_src;
  RAISE NOTICE 'compose_weekly_cpr_html patched: % day cells now blank-on-off', v_replaced;
END;
$migration$;
