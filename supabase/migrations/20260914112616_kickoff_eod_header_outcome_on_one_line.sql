-- Peter 2026-09-14: the EOD header on the morning kickoff drops "(last week
-- close)" and carries the outcome on the same line as the emoji plus Won or
-- Missed. Anchored replace against the live definition.
DO $mig$
DECLARE
  v_def text;
  v_before text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'team_checkin_send_reminder';

  v_before := v_def;
  v_def := replace(v_def, $a$v_outcome_line := '🏆 Won last week'$a$, $a$v_outcome_line := '🏆 Won'$a$);
  IF v_def = v_before THEN RAISE EXCEPTION 'anchor 1 (won label) not found'; END IF;

  v_before := v_def;
  v_def := replace(v_def, $a$v_outcome_line := '❌ Missed last week'$a$, $a$v_outcome_line := '❌ Missed'$a$);
  IF v_def = v_before THEN RAISE EXCEPTION 'anchor 2 (missed label) not found'; END IF;

  v_before := v_def;
  v_def := replace(v_def,
    $a$v_header_label := format(E'📊 EOD %s (last week close)\n%s',$a$,
    $a$v_header_label := format('📊 EOD %s %s',$a$);
  IF v_def = v_before THEN RAISE EXCEPTION 'anchor 3 (two-line header) not found'; END IF;

  v_before := v_def;
  v_def := replace(v_def,
    $a$v_header_label := format('📊 EOD %s (last week close)', to_char(v_last_eod_date, 'Mon DD'));$a$,
    $a$v_header_label := format('📊 EOD %s', to_char(v_last_eod_date, 'Mon DD'));$a$);
  IF v_def = v_before THEN RAISE EXCEPTION 'anchor 4 (no-outcome header) not found'; END IF;

  EXECUTE v_def;
END $mig$;