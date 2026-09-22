DO $mig$
DECLARE d text; r text[][] := ARRAY[
  ARRAY['    FROM public.rp_entry_rows(a.agency_id, v_from, v_to, false) r',
        '    -- Default window (no dates picked): also show anything RECORDED in the window,
    -- so a cancel logged today with an older cancel date still shows (Peter 2026-09-22).
    FROM public.rp_entry_rows(a.agency_id, CASE WHEN p_from IS NULL THEN DATE ''1900-01-01'' ELSE v_from END, v_to, false) r'],
  ARRAY['   WHERE (v_who IS NULL OR r.team_member_id = v_who)',
        '   WHERE (v_who IS NULL OR r.team_member_id = v_who)
     AND (p_from IS NOT NULL OR r.occurred_on >= v_from
          OR (r.created_at AT TIME ZONE ''America/Chicago'')::date >= v_from)']
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
