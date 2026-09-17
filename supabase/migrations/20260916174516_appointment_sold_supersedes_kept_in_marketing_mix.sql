-- An appointment that sold must not also pay as kept.
-- One appointment is one record moving set -> kept -> sold, so it pays once,
-- at the highest state it reached. This matches the State Farm activity report,
-- which lists a sold appointment only under Appointment Sold Pivot Escalated.
-- Before this, a row carrying both kept_on and sold_on appeared in the marketing
-- mix twice, paying $5 + $10 instead of $10.
DO $mig$
DECLARE d text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';

  IF d IS NULL THEN
    RAISE EXCEPTION 'rp_week_scoreboard_for not found';
  END IF;

  IF position('ap.kept_on IS NOT NULL AND public.rp_week_end(ap.kept_on)' in d) = 0 THEN
    RAISE EXCEPTION 'kept-appointment filter not found; aborting';
  END IF;

  d := replace(
    d,
    'AND ap.kept_on IS NOT NULL AND public.rp_week_end(ap.kept_on)',
    'AND ap.sold_on IS NULL
      AND ap.kept_on IS NOT NULL AND public.rp_week_end(ap.kept_on)'
  );

  EXECUTE d;
END $mig$;

-- Verify the change landed.
DO $chk$
DECLARE d text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';
  IF position('AND ap.sold_on IS NULL' in d) = 0 THEN
    RAISE EXCEPTION 'change did not land';
  END IF;
END $chk$;
