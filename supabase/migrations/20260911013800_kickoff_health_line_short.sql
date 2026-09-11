-- Peter 2026-09-10: kickoff health line becomes "Remember health! Check in at 7 pm."
-- The 🏃 emoji stays; only the words change.
DO $mig$
DECLARE d text; n int;
BEGIN
  d := pg_get_functiondef('public.team_checkin_send_reminder'::regproc);
  n := (SELECT count(*) FROM regexp_matches(d, $re$🏃 Get started on your health goal! We''ll check in at 7 pm\.$re$, 'g'));
  IF n <> 1 THEN RAISE EXCEPTION 'kickoff health line matched % times, expected 1', n; END IF;
  d := regexp_replace(d, $re$🏃 Get started on your health goal! We''ll check in at 7 pm\.$re$,
                         $rep$🏃 Remember health! Check in at 7 pm.$rep$);
  EXECUTE d;
END
$mig$;