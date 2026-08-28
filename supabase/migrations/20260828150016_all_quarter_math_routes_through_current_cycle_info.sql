-- Peter directive 2026-08-28: "There should only be one function that calculates that."
--
-- Six functions computed their own quarter start with date_trunc('quarter', ...), which returns
-- the CALENDAR quarter start (2026-07-01) rather than the State Farm cycle start (2026-07-05).
-- Consequence: every quarter's CLOSING Saturday was read as week 1 of the NEXT quarter --
-- 2025-04-05, 2025-07-05, 2025-10-04, 2026-01-03, 2026-04-04 and 2026-07-04 all landed in the
-- wrong quarter for pool accrual, rolling averages, marketing-bonus windows and leaderboards.
--
-- All ten occurrences now resolve through current_cycle_info, the single source. Rewritten by
-- regex over pg_get_functiondef so each body is otherwise carried byte-for-byte -- no hand-
-- retyping of comp logic.
--
-- Functions touched: audit_weekly_leaderboard_crossings, compute_rolling_4wk_sp,
-- compute_weekly_comp_residual_pool, compute_weekly_marketing_bonus, write_weekly_comp_v2,
-- write_weekly_marketing_bonus. All six take p_agency_id as their first argument.

DO $migrate$
DECLARE
  r          record;
  v_def      text;
  v_new      text;
  v_touched  int := 0;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname <> 'current_cycle_info'
      AND pg_get_functiondef(p.oid) LIKE '%date_trunc(''quarter''%'
    ORDER BY p.proname
  LOOP
    v_def := pg_get_functiondef(r.oid);

    v_new := regexp_replace(
      v_def,
      'date_trunc\(''quarter'', ([a-zA-Z0-9_\.]+)::timestamp\)::date',
      '(SELECT cci.cycle_start FROM public.current_cycle_info(p_agency_id, \1) cci)',
      'g'
    );

    IF v_new = v_def THEN
      RAISE EXCEPTION 'no substitution made in %, aborting whole migration', r.proname;
    END IF;

    IF v_new LIKE '%date_trunc(''quarter''%' THEN
      RAISE EXCEPTION 'leftover calendar-quarter expression in %, aborting', r.proname;
    END IF;

    EXECUTE v_new;
    v_touched := v_touched + 1;
  END LOOP;

  IF v_touched <> 6 THEN
    RAISE EXCEPTION 'expected to rewrite 6 functions, rewrote %', v_touched;
  END IF;

  RAISE NOTICE 'repointed % functions to current_cycle_info', v_touched;
END
$migrate$;
