-- Email "owed next wk" now computed at runtime, matching the webpage.
-- Stored weekly_cpr_reports.quotes_owed_next_week is the Saturday snapshot,
-- used by next week's writer chain; the email always reads the live value
-- so retroactive input edits before send propagate immediately.
DO $migration$
DECLARE
  v_src text;
  v_old text;
  v_new text;
BEGIN
  v_src := pg_get_functiondef('public.compose_weekly_cpr_html'::regproc);
  v_old := 'v_quotes_owed_next := COALESCE(v_report.quotes_owed_next_week, 0);';
  v_new := '-- Runtime sum of per-person Next Wk (= Σ total − paid) via get_weekly_cpr_requirements.' || E'\n' ||
           '  -- Stored weekly_cpr_reports.quotes_owed_next_week is the Saturday snapshot used by' || E'\n' ||
           '  -- next week''s writer carryover chain; the display always reads live.' || E'\n' ||
           '  SELECT COALESCE(SUM(owed), 0)::int INTO v_quotes_owed_next' || E'\n' ||
           '  FROM public.get_weekly_cpr_requirements(p_agency_id, p_week_ending_date);';
  IF position(v_old in v_src) = 0 THEN
    RAISE EXCEPTION 'Anchor not found';
  END IF;
  EXECUTE replace(v_src, v_old, v_new);
END;
$migration$;
