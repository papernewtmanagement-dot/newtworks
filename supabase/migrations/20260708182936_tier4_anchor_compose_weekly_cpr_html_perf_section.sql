-- Tier-4 (anchor audit): compose_weekly_cpr_html perf-section annualization
-- was using (p_week_ending_date - Jan 1) as the days-elapsed denominator, even
-- though the ytd values come from v_snap (an agency_snapshot row that may be
-- older than p_week_ending_date). Same anchor-drift bug pattern as the
-- Dashboard P&C growth widget fixed earlier the same day (2026-07-08).
--
-- All 7 usages of `ytd * 365.0 / v_days_elapsed` in the perf CTE share the
-- same v_days_elapsed variable. Fix one line, fix all seven.
--
-- Anchor rule: effective_as_of = LEAST(v_snap.snapshot_date, p_week_ending_date).
-- Since the SELECT INTO v_snap already filters snapshot_date <= p_week_ending_date,
-- COALESCE(v_snap.snapshot_date, p_week_ending_date) IS effectively LEAST().
--
-- Payroll on-time (payroll_with_ota CTE) is separately anchored to
-- days_employed_year using p_week_ending_date -- stays as-is because payroll
-- YTD is stream data, and p_week_ending_date is the correct endpoint anchor
-- per the stream-vs-snapshot distinction in the anchor rule.

DO $mig$
DECLARE
  v_current_def   text;
  v_updated_def   text;
  v_old_line      text := 'v_days_elapsed := GREATEST(1, (p_week_ending_date - make_date(EXTRACT(YEAR FROM p_week_ending_date)::int, 1, 1))::int + 1);';
  v_new_line      text := '-- Anchored to v_snap.snapshot_date (not p_week_ending_date) so annualization denominator matches numerator freshness. See op-rule "Runtime compute annualization anchor" (2026-06-29, generalized 2026-07-08).' || E'\n  ' ||
                         'v_days_elapsed := GREATEST(1, (COALESCE(v_snap.snapshot_date, p_week_ending_date) - make_date(EXTRACT(YEAR FROM COALESCE(v_snap.snapshot_date, p_week_ending_date))::int, 1, 1))::int + 1);';
  v_hits          int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_current_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'compose_weekly_cpr_html';

  IF v_current_def IS NULL THEN
    RAISE EXCEPTION 'compose_weekly_cpr_html not found in pg_proc';
  END IF;

  v_hits := (length(v_current_def) - length(replace(v_current_def, v_old_line, ''))) / length(v_old_line);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'Expected exactly 1 occurrence of the old v_days_elapsed line, found %', v_hits;
  END IF;

  v_updated_def := replace(v_current_def, v_old_line, v_new_line);
  EXECUTE v_updated_def;

  RAISE NOTICE 'compose_weekly_cpr_html anchored: v_days_elapsed now derived from v_snap.snapshot_date';
END $mig$;
