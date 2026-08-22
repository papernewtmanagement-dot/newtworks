-- Email parity for the webpage Team Total fix.
-- Team Net Quotes Total is now the sum of per-person Net Quotes (= Σ quotes_discussed − paid)
-- via get_weekly_cpr_requirements, NOT the stored weekly_cpr_reports.quotes_total_net.
-- The stored column (despite its name) holds the team's GROSS quotes for the week —
-- used by Win-the-Week pass/fail math in weekly_cpr_compute_outcome, but not for display.

DO $migration$
DECLARE
  v_src text;
  v_new text;
  v_old_pattern text;
  v_new_pattern text;
BEGIN
  v_src := pg_get_functiondef('public.compose_weekly_cpr_html'::regproc);

  v_old_pattern := 'v_team_net_quotes := COALESCE(v_report.quotes_total_net, 0);';
  v_new_pattern :=
    '-- Sum per-person Net Quotes at runtime (= Σ quotes_discussed − paid).' || E'\n' ||
    '  -- Stored weekly_cpr_reports.quotes_total_net holds the team''s GROSS quotes' || E'\n' ||
    '  -- for the week (Telegram checkin sum, written by weekly_cpr_compute_outcome).' || E'\n' ||
    '  -- That feeds Win-the-Week pass/fail math, but not this display value.' || E'\n' ||
    '  SELECT COALESCE(SUM(net_quotes), 0)::int INTO v_team_net_quotes' || E'\n' ||
    '  FROM public.get_weekly_cpr_requirements(p_agency_id, p_week_ending_date);';

  IF position(v_old_pattern in v_src) = 0 THEN
    RAISE EXCEPTION 'Anchor pattern not found in compose_weekly_cpr_html';
  END IF;

  v_new := replace(v_src, v_old_pattern, v_new_pattern);
  EXECUTE v_new;
  RAISE NOTICE 'compose_weekly_cpr_html patched: Team Net Quotes Total now runtime-computed';
END;
$migration$;
