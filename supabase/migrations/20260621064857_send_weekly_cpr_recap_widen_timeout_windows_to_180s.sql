
DO $migration$
DECLARE
  v_def text;
  v_new text;
  v_check_count int;
BEGIN
  SELECT pg_get_functiondef('public.send_weekly_cpr_recap(uuid,date)'::regprocedure) INTO v_def;
  v_new := v_def;

  -- 1. pg_net request timeout: 90000ms → 180000ms (must be ≥ our poll window)
  v_new := replace(
    v_new,
    $$    timeout_milliseconds := 90000$$,
    $$    timeout_milliseconds := 180000$$
  );

  -- 2. Poll-loop ceiling: 180×0.5s=90s → 300×0.5s=150s
  v_new := replace(
    v_new,
    $$  v_max_attempts            int := 180;       -- 180 × 0.5s = 90s polling ceiling$$,
    $$  v_max_attempts            int := 300;       -- 300 × 0.5s = 150s polling ceiling$$
  );

  -- 3. Late-recovery sweep: 15s → 30s (comment + sleep)
  v_new := replace(
    v_new,
    $$  -- give Composio one more chance (15s) to land before declaring timeout.$$,
    $$  -- give Composio one more chance (30s) to land before declaring timeout.$$
  );
  v_new := replace(
    v_new,
    $$    PERFORM pg_sleep(15);$$,
    $$    PERFORM pg_sleep(30);$$
  );

  -- 4. Top-of-call comment: 90-second → 180-second
  v_new := replace(
    v_new,
    $$  -- 90-second pg_net request timeout. Composio Gmail occasionally needs >30s
  -- on large HTML payloads (e.g. 2026-06-20: 32.6KB html, returned at 30.6s).$$,
    $$  -- 180-second pg_net request timeout (bumped 2026-06-21 from 90s after a
  -- resend exposed Composio response landing at ~108s). Primary auto-sends
  -- typically land in 30-35s; window sized for slow-Composio days.$$
  );

  -- 5. Error-message text on timeout path
  v_new := replace(
    v_new,
    $$Composio request timed out after ~105s (90s poll + 15s recovery).$$,
    $$Composio request timed out after ~180s (150s poll + 30s recovery).$$
  );

  -- Sanity: verify exactly 5 textual changes landed
  v_check_count := 0;
  IF v_new LIKE '%timeout_milliseconds := 180000%' THEN v_check_count := v_check_count + 1; END IF;
  IF v_new LIKE '%v_max_attempts            int := 300%' THEN v_check_count := v_check_count + 1; END IF;
  IF v_new LIKE '%one more chance (30s) to land%' THEN v_check_count := v_check_count + 1; END IF;
  IF v_new LIKE '%PERFORM pg_sleep(30);%' THEN v_check_count := v_check_count + 1; END IF;
  IF v_new LIKE '%timed out after ~180s (150s poll + 30s recovery)%' THEN v_check_count := v_check_count + 1; END IF;

  -- Bonus: 180-second comment block landed
  IF v_new LIKE '%180-second pg_net request timeout (bumped 2026-06-21%' THEN v_check_count := v_check_count + 1; END IF;

  IF v_check_count <> 6 THEN
    RAISE EXCEPTION 'Patch did not fully land. Expected 6 confirmations, got %', v_check_count;
  END IF;

  -- And confirm no stale 90/105/15-second references remain in updated paths
  IF v_new LIKE '%timeout_milliseconds := 90000%' THEN
    RAISE EXCEPTION 'Stale pg_net timeout (90000) still present';
  END IF;
  IF v_new LIKE '%v_max_attempts            int := 180%' THEN
    RAISE EXCEPTION 'Stale v_max_attempts (180) still present';
  END IF;
  IF v_new LIKE '%pg_sleep(15);%' THEN
    RAISE EXCEPTION 'Stale pg_sleep(15) still present';
  END IF;
  IF v_new LIKE '%timed out after ~105s%' THEN
    RAISE EXCEPTION 'Stale 105s error message still present';
  END IF;

  EXECUTE v_new;
END $migration$;

