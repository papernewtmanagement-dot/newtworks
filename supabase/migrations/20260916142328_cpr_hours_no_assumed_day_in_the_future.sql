-- A salaried teammate with no entered figure is assumed to work an 8-hour day.
-- That assumption was applied to every weekday of the week, so an open week
-- claimed all five days from Sunday onward. Retention Points pay on those hours,
-- so mid-week Stephanie was being credited for days she had not worked yet.
-- A day that has not arrived is now zero. An entered salaried_hours_overrides
-- figure still wins, and closed weeks are unchanged because every day is past.
-- Peter 2026-09-16.
DO $mig$
DECLARE
  v_def text;
  v_old text := E'    WHEN so.hours IS NOT NULL THEN so.hours\n    ELSE GREATEST(0, 8 - COALESCE(toff.hours_off, 0))\n';
  v_new text := E'    WHEN so.hours IS NOT NULL THEN so.hours\n'
             || E'    -- A day that has not happened yet is not worked hours (Peter 2026-09-16).\n'
             || E'    WHEN wd.work_date > (now() AT TIME ZONE ''America/Chicago'')::date THEN 0\n'
             || E'    ELSE GREATEST(0, 8 - COALESCE(toff.hours_off, 0))\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_weekly_cpr_hours';

  IF position(E'has not happened yet' IN v_def) > 0 THEN RAISE NOTICE 'already applied'; RETURN; END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'assumed-day branch not in the expected shape - another thread changed get_weekly_cpr_hours';
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
END $mig$;
