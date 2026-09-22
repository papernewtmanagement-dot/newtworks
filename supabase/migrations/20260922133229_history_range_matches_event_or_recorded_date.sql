DO $mig$
DECLARE d text; r text[][] := ARRAY[
  ARRAY['    FROM public.rp_entry_rows(a.agency_id, CASE WHEN p_from IS NULL THEN DATE ''1900-01-01'' ELSE v_from END, v_to, false) r',
        '    FROM public.rp_entry_rows(a.agency_id, DATE ''1900-01-01'', DATE ''9999-12-31'', false) r'],
  ARRAY['     AND (p_from IS NOT NULL OR r.occurred_on >= v_from
          OR (r.created_at AT TIME ZONE ''America/Chicago'')::date >= v_from)',
        '     -- Peter 2026-09-22: a row is in the date range if it is dated in it OR was
     -- entered in it, so a cancel logged today with an older date still shows.
     AND (r.occurred_on BETWEEN v_from AND v_to
          OR (r.created_at AT TIME ZONE ''America/Chicago'')::date BETWEEN v_from AND v_to)']
]; i int;
BEGIN
  d := pg_get_functiondef('public.rp_recent_entries(integer,uuid,integer,text,date,date,text)'::regprocedure);
  FOR i IN 1..array_length(r,1) LOOP
    IF (length(d) - length(replace(d, r[i][1], ''))) / length(r[i][1]) <> 1 THEN
      RAISE EXCEPTION 'patch % did not match exactly once', i;
    END IF;
    d := replace(d, r[i][1], r[i][2]);
  END LOOP;
  EXECUTE d;
END $mig$;
