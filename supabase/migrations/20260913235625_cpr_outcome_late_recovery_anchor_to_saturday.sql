-- The Saturday close guard refuses to run outside a 3-minute window around 23:59 CT.
-- That guard is right to exist: it stops a wrong-time fire from computing the wrong
-- week, because current_cycle_info() asked on a Sunday returns the week ending the
-- NEXT Saturday. But it also means a dropped dispatch loses the week outright, which
-- is what happened on 2026-09-12.
--
-- Keep the guard. Add one recovery branch: if the 23:59 Saturday close lands in the
-- small hours of Sunday, anchor the week back to the Saturday that just closed
-- instead of skipping. Every other wrong-time fire still skips exactly as before.
-- Patched in place so none of the surrounding pay math is retyped.
DO $do$
DECLARE
  v_src  text;
  v_old  text;
  v_new  text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
  WHERE p.proname = 'weekly_cpr_compute_outcome';

  v_old := $old$  IF NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;$old$;

  v_new := $new$  v_today := (now() AT TIME ZONE 'America/Chicago')::date;

  IF NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    IF v_local_time = '23:59'
       AND EXTRACT(DOW FROM v_today) = 0
       AND (now() AT TIME ZONE 'America/Chicago')::time < TIME '06:00' THEN
      v_today := v_today - 1;
    ELSE
      RETURN jsonb_build_object('records_processed', 0,
        'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
    END IF;
  END IF;$new$;

  IF position(v_old in v_src) = 0 THEN
    RAISE EXCEPTION 'Guard block not found unchanged — aborting rather than guessing.';
  END IF;

  EXECUTE replace(v_src, v_old, v_new);
END
$do$;
