-- Rosters pull active team members only (Peter 2026-09-21).
-- Incoming hires (switched off, never archived) were leaking into the health
-- check-ins, the CPR compensation roster, the manager-tier lists, the kickoff
-- commits roster, the earnings curve, the raise and sales-points panels and the
-- retention-points rollups. One surgical edit per function; each edit must match
-- exactly once or the migration aborts. The calendar-invite roster keeps its
-- Friday-before-start rule. Past weeks still read their own snapshot, and
-- someone who left mid-week still counts for that week.
DO $mig$
DECLARE
  r record;
  v_def text;
  v_hits int;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('get_expected_teammates',
     E'  WHERE r.is_test_user IS NOT TRUE\n',
     E'  WHERE r.is_test_user IS NOT TRUE\n    -- Active only: an incoming hire (switched off, never archived) is on no roster\n    -- until they are marked started (Peter 2026-09-21). The calendar invite keeps\n    -- its Friday-before-start rule. Someone archived after the as-of date was\n    -- active then, and the cutoff below still handles them.\n    AND (p_purpose = ''agency_calendar_invite''\n         OR COALESCE(r.is_active, false) = true\n         OR r.archived_at IS NOT NULL)\n'),
    ('daily_commits_for_day',          'AND t.archived_at IS NULL', 'AND t.is_active = true AND t.archived_at IS NULL'),
    ('earnings_curve_positions',       'AND t.archived_at IS NULL', 'AND t.is_active = true AND t.archived_at IS NULL'),
    ('sales_points_band_drop_watcher', 'AND t.archived_at IS NULL', 'AND t.is_active = true AND t.archived_at IS NULL'),
    ('team_raise_progress',            'AND t.archived_at IS NULL', 'AND t.is_active = true AND t.archived_at IS NULL'),
    ('team_sales_points_ratings',      'AND t.archived_at IS NULL', 'AND t.is_active = true AND t.archived_at IS NULL'),
    ('rp_rollup_for',                  '(t.archived_at IS NULL',    '((t.is_active AND t.archived_at IS NULL)'),
    ('team_quarter_to_date',           '(t.archived_at IS NULL',    '((t.is_active AND t.archived_at IS NULL)')
  ) AS v(fn, old_txt, new_txt)
  LOOP
    SELECT pg_get_functiondef(p.oid) INTO STRICT v_def
      FROM pg_proc p WHERE p.proname = r.fn AND p.pronamespace = 'public'::regnamespace;
    v_hits := (length(v_def) - length(replace(v_def, r.old_txt, ''))) / length(r.old_txt);
    IF v_hits <> 1 THEN
      RAISE EXCEPTION '% : expected 1 match, found %', r.fn, v_hits;
    END IF;
    EXECUTE replace(v_def, r.old_txt, r.new_txt);
  END LOOP;
END
$mig$;
