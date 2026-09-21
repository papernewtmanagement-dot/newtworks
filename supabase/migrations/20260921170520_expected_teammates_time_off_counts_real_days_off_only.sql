DO $mig$
DECLARE
  v_def text := pg_get_functiondef('public.get_expected_teammates(uuid,text,date,text)'::regprocedure);
  v_anchor text := $a$AND tor.status            = 'approved'$a$;
  v_new text;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 THEN
    RAISE EXCEPTION 'anchor not found exactly once in get_expected_teammates';
  END IF;
  v_new := replace(v_def, v_anchor, v_anchor || $b$
            -- Only real days off count. A standing-preference request, a remote
            -- half day or a four-day-off change is dated but is not time away
            -- (time_off_day_hours returns 0 for them). Stephanie's standing
            -- preference request dated 2026-09-21 hid her from every check-in.
            AND public.time_off_day_hours(tor.request_type, tor.partial_day) > 0$b$);
  EXECUTE v_new;
END
$mig$;
