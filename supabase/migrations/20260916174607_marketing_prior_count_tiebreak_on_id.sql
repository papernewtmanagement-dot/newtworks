-- Two marketing events on the same day, saved in the same instant, each failed to
-- count the other as a prior. Both then priced as the same one in the run, which
-- pays less than it should. Adds the row id as the last tie-break so the order is
-- always settled. Applies to online reviews, referrals sold, and appointments sold.
DO $mig$
DECLARE d text; n int := 0;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
  FROM pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
  WHERE n2.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';

  IF d IS NULL THEN RAISE EXCEPTION 'rp_week_scoreboard_for not found'; END IF;

  IF position('(p.occurred_on < l.occurred_on OR (p.occurred_on = l.occurred_on AND p.created_at < l.created_at))' in d) > 0 THEN
    d := replace(d,
      '(p.occurred_on < l.occurred_on OR (p.occurred_on = l.occurred_on AND p.created_at < l.created_at))',
      '(p.occurred_on < l.occurred_on OR (p.occurred_on = l.occurred_on AND (p.created_at < l.created_at OR (p.created_at = l.created_at AND p.id < l.id))))');
    n := n + 1;
  END IF;

  IF position('(p.submitted_date < s.submitted_date OR (p.submitted_date = s.submitted_date AND p.created_at < s.created_at))' in d) > 0 THEN
    d := replace(d,
      '(p.submitted_date < s.submitted_date OR (p.submitted_date = s.submitted_date AND p.created_at < s.created_at))',
      '(p.submitted_date < s.submitted_date OR (p.submitted_date = s.submitted_date AND (p.created_at < s.created_at OR (p.created_at = s.created_at AND p.id < s.id))))');
    n := n + 1;
  END IF;

  IF position('(q.sold_on < ap.sold_on OR (q.sold_on = ap.sold_on AND q.created_at < ap.created_at))' in d) > 0 THEN
    d := replace(d,
      '(q.sold_on < ap.sold_on OR (q.sold_on = ap.sold_on AND q.created_at < ap.created_at))',
      '(q.sold_on < ap.sold_on OR (q.sold_on = ap.sold_on AND (q.created_at < ap.created_at OR (q.created_at = ap.created_at AND q.id < ap.id))))');
    n := n + 1;
  END IF;

  IF n <> 3 THEN
    RAISE EXCEPTION 'expected 3 prior-count blocks, patched %', n;
  END IF;

  EXECUTE d;
END $mig$;

DO $chk$
DECLARE d text; hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
  FROM pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
  WHERE n2.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';
  hits := (length(d) - length(replace(d, '.id < ', ''))) / length('.id < ');
  IF hits < 3 THEN RAISE EXCEPTION 'tie-breaks did not land (%)', hits; END IF;
END $chk$;
