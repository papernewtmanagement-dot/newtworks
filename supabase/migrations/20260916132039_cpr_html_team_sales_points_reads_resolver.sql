-- compose_weekly_cpr_html built the team sales points total by adding up the typed-in
-- column on this week's report rows. Adding across PEOPLE is right; the source was not.
-- It now adds up the resolver's figure for the same people, so the report email agrees
-- with every other screen. The roster gate (rows on this week's report) is unchanged.
DO $migrate$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'compose_weekly_cpr_html';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'compose_weekly_cpr_html not found';
  END IF;

  v_old :=
    '    COALESCE(SUM(d.sales_points), 0)::numeric' || E'\n' ||
    '  INTO v_team_quotes, v_team_sp' || E'\n' ||
    '  FROM public.weekly_cpr_team_detail d' || E'\n' ||
    '  JOIN public.get_weekly_cpr_requirements(p_agency_id, p_week_ending_date) r' || E'\n' ||
    '    ON r.team_member_id = d.team_member_id' || E'\n' ||
    '  WHERE d.weekly_cpr_report_id = v_report.id;';

  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'expected team sales points block not found - another thread changed this function, re-read before patching';
  END IF;

  v_new :=
    '    COALESCE(SUM(g.sales_points), 0)::numeric' || E'\n' ||
    '  INTO v_team_quotes, v_team_sp' || E'\n' ||
    '  FROM public.weekly_cpr_team_detail d' || E'\n' ||
    '  JOIN public.get_weekly_cpr_requirements(p_agency_id, p_week_ending_date) r' || E'\n' ||
    '    ON r.team_member_id = d.team_member_id' || E'\n' ||
    '  LEFT JOIN public.get_sales_points_qtd(p_agency_id, p_week_ending_date) g' || E'\n' ||
    '    ON g.team_id = d.team_member_id' || E'\n' ||
    '  WHERE d.weekly_cpr_report_id = v_report.id;';

  EXECUTE replace(v_def, v_old, v_new);
END
$migrate$;
