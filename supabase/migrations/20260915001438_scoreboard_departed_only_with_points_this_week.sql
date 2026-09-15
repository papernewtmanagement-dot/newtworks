-- Peter 2026-09-14: a departed teammate should only appear on a week's board
-- if they have points in THAT week. The contributor window was the whole
-- quarter to date, so John Kostov (ended 2026-09-01) kept showing on every
-- later week carrying a quarter-to-date number and zero points for the week.
-- This narrows the roster window to the week being shown. It does NOT change
-- the 2026-09-11 ruling that contributions never expire: a departed person
-- still appears on every week they actually earned in, and no points move.
-- Requirements and targets are the other half and stay untouched.
DO $do$
DECLARE d text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d
    FROM pg_proc p JOIN pg_namespace n2 ON n2.oid = p.pronamespace
   WHERE n2.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';

  IF position($a$AND p.issued_date BETWEEN v_cycle_start AND v_week_end$a$ IN d) = 0
     OR position($a$OR (l.activity_key = 'google_review' AND l.occurred_on BETWEEN v_cycle_start AND v_week_end))$a$ IN d) = 0 THEN
    RAISE EXCEPTION 'contributor window anchors not found — do not patch blind';
  END IF;

  d := replace(d,
    $a$AND p.issued_date BETWEEN v_cycle_start AND v_week_end$a$,
    $b$AND p.issued_date BETWEEN v_week_start AND v_week_end$b$);

  d := replace(d,
    $a$OR (l.activity_key = 'google_review' AND l.occurred_on BETWEEN v_cycle_start AND v_week_end))$a$,
    $b$)$b$);

  d := replace(d,
    $a$-- Peter 2026-09-11: contributions never expire and employment does not gate
    -- them. Anyone with activity inside the window stays on the board, whenever
    -- they left. Same shape rp_rollup_for already uses.$a$,
    $b$-- Peter 2026-09-11: contributions never expire and employment does not gate
    -- them. Anyone with activity inside the window stays on the board, whenever
    -- they left. Same shape rp_rollup_for already uses.
    -- Narrowed 2026-09-14 (Peter): the window is THIS WEEK, not the quarter to
    -- date. A departed teammate belongs on the weeks they earned in and on no
    -- others. Quarter-to-date numbers still show for whoever is on the board;
    -- they just no longer put someone on it.$b$);

  EXECUTE d;
END $do$;
