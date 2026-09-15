-- Same rule on the reported weeks (anything through 2026-09-12, which reads
-- what was reported rather than live capture). A departed teammate was landing
-- on those boards on the strength of a quarter-to-date figure with zero points
-- for the week. No points change; only who is listed.
DO $do$
DECLARE d text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
    FROM pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
   WHERE n2.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';

  IF position($a$OR t.id IN (SELECT tm FROM mk) OR t.id IN (SELECT tm FROM sp)$a$ IN d) = 0 THEN
    RAISE EXCEPTION 'reported roster anchor not found — do not patch blind';
  END IF;

  d := replace(d,
    $a$OR t.id IN (SELECT tm FROM mk) OR t.id IN (SELECT tm FROM sp)$a$,
    $b$OR t.id IN (SELECT tm FROM mk WHERE COALESCE(points, 0) <> 0)
          OR t.id IN (SELECT tm FROM sp WHERE ROUND(COALESCE(qtd, 0) - COALESCE(prev, 0), 2) <> 0)$b$);

  EXECUTE d;
END $do$;
