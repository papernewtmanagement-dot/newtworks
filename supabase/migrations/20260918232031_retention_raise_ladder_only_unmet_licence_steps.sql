-- Peter 2026-09-18: there is no retention raise ladder beyond getting licensed.
-- team_raise_progress was walking a Retention teammate up the licence steps one
-- rung at a time regardless of what they already held, so Stephanie - licensed in
-- both P&C and Life & Health - was shown as "on track" for the P&C rung she had
-- cleared long ago, with a $21 chip on her name.
--
-- For Retention the next rung is now the lowest licence step the person does NOT
-- already satisfy. Someone holding every licence the steps ask for has no next
-- rung at all: at_top is true and nothing is shown. Sales is untouched - it climbs
-- on sales-points pace, which is a real ladder.
DO $mig$
DECLARE
  v_def text;
  s text := 'AND (pl.role_category IS DISTINCT FROM ''Retention'' OR p.retention_requirement IS NOT NULL)';
  n text := 'AND (pl.role_category IS DISTINCT FROM ''Retention''
                OR (p.retention_requirement IS NOT NULL
                    AND NOT ((pl.has_pc OR NOT COALESCE(p.retention_requires_pc, false))
                         AND (pl.has_lh OR NOT COALESCE(p.retention_requires_lh, false)))))';
  hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
  WHERE ns.nspname = 'public' AND p.proname = 'team_raise_progress';
  IF v_def IS NULL THEN RAISE EXCEPTION 'team_raise_progress not found'; END IF;

  hits := (length(v_def) - length(replace(v_def, s, ''))) / length(s);
  IF hits <> 1 THEN RAISE EXCEPTION 'expected exactly 1 retention-rung anchor, found %', hits; END IF;

  EXECUTE replace(v_def, s, n);
END
$mig$;
