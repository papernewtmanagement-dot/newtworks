-- Migration 20260915001438 narrowed the DEPARTED-TEAMMATE roster window from the
-- quarter to the week. It did that with a blind string replace of
--   AND p.issued_date BETWEEN v_cycle_start AND v_week_end
-- and that exact line also lived in the prod CTE, which is what the sales-point
-- math reads. So sales points quietly collapsed from quarter-to-date to this
-- week only. Thomas showed 26.90 for the quarter on 2026-09-15.
-- The contributors window stays at the week. Only prod goes back to the quarter.
DO $do$
DECLARE
  d text;
  anchor_old constant text := 'AND p.issued_date IS NOT NULL
      AND p.issued_date BETWEEN v_week_start AND v_week_end';
  anchor_new constant text := 'AND p.issued_date IS NOT NULL
      AND p.issued_date BETWEEN v_cycle_start AND v_week_end';
  hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';

  IF d IS NULL THEN
    RAISE EXCEPTION 'rp_week_scoreboard_for not found';
  END IF;

  hits := (length(d) - length(replace(d, anchor_old, ''))) / length(anchor_old);
  IF hits <> 1 THEN
    RAISE EXCEPTION 'expected exactly one prod-window line, found %', hits;
  END IF;

  EXECUTE replace(d, anchor_old, anchor_new);
END
$do$;
