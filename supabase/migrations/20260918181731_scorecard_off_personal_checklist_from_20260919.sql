-- Peter 2026-09-18: Scorecard comes off the personal checklist. It is always
-- done once the team submits their log records, so charging a miss for it is
-- charging for something that cannot be missed.
--
-- Applied from the week ending 2026-09-19 forward ONLY. Earlier weeks in this
-- cycle keep counting it, because their misses fed carryover that has already
-- been paid; rewriting them would change money that is already out the door.
-- The CPR page hides the Scorecard column on the same boundary.
DO $mig$
DECLARE
  v_def    text;
  v_anchor text := '(CASE WHEN COALESCE(d.scorecard_done, false) THEN 0 ELSE 1 END +';
  v_new    text := '(CASE WHEN v_loop_week >= DATE ''2026-09-19'' OR COALESCE(d.scorecard_done, false) THEN 0 ELSE 1 END +';
  v_hits   int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_weekly_cpr_requirements';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'get_weekly_cpr_requirements not found';
  END IF;

  v_hits := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'expected exactly 1 scorecard_done anchor, found %', v_hits;
  END IF;

  EXECUTE replace(v_def, v_anchor, v_new);
END
$mig$;
