DO $mig$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.production_rows_for'::regproc);
  IF position('(c.created_at AT TIME ZONE ''America/Chicago'')::date AS recorded_on' IN d) = 0 THEN
    RAISE EXCEPTION 'production_rows_for changed shape; re-read before patching';
  END IF;
  d := replace(d,
    '(c.created_at AT TIME ZONE ''America/Chicago'')::date AS recorded_on',
    '-- Peter 2026-09-21: a cancelation or chargeback counts toward the last CPR
           -- until that CPR is frozen (sent). Recorded after its week ended but before
           -- it was sent -> it lands on that week. Otherwise on the day recorded.
           CASE WHEN NOT EXISTS (
                  SELECT 1 FROM public.weekly_cpr_reports r
                   WHERE r.agency_id = c.agency_id
                     AND r.week_ending_date = rd.prev_sat
                     AND r.sent_to_team_at IS NOT NULL
                     AND r.sent_to_team_at <= c.created_at)
                THEN rd.prev_sat ELSE rd.d END AS recorded_on');
  d := replace(d,
    'FROM public.cancelation_log c
     WHERE c.agency_id',
    'FROM public.cancelation_log c
      CROSS JOIN LATERAL (
        SELECT (c.created_at AT TIME ZONE ''America/Chicago'')::date AS d,
               (c.created_at AT TIME ZONE ''America/Chicago'')::date
                 - (EXTRACT(DOW FROM (c.created_at AT TIME ZONE ''America/Chicago''))::int + 1) AS prev_sat
      ) rd
     WHERE c.agency_id');
  IF position('CROSS JOIN LATERAL (' IN d) = 0 THEN
    RAISE EXCEPTION 'second patch did not apply';
  END IF;
  EXECUTE d;
END
$mig$;
