DO $mig$
DECLARE f text; s int; e int; nb text;
BEGIN
  f := pg_get_functiondef('public.compose_weekly_cpr_html'::regproc);
  s := position(E'  SELECT string_agg(row_html, \'\' ORDER BY start_date)\n  INTO v_payroll_html' in f);
  e := position('  v_payroll_html := COALESCE(v_payroll_html' in f);
  IF s = 0 OR e = 0 OR e < s THEN RAISE EXCEPTION 'markers not found % %', s, e; END IF;
  nb := $nb$  -- Weekly pay comes from team_payroll_week, the one payroll function the Payroll
  -- page and CPR read. The email no longer adds up its own copy (Peter 2026-09-28).
  SELECT string_agg(row_html, '' ORDER BY start_date)
  INTO v_payroll_html
  FROM (
    SELECT
      t.start_date,
      '<tr>' ||
        '<td style="padding:6px 10px;color:#1e293b;font-weight:600;font-size:14px">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</td>' ||
        '<td style="padding:6px 10px;text-align:right;color:#1e293b;font-weight:700;font-size:14px">$' ||
          to_char(COALESCE((pw->>'before_deductions')::numeric, 0), 'FM999,999,990.00') ||
        '</td>' ||
      '</tr>' AS row_html
    FROM jsonb_array_elements(COALESCE(public.team_payroll_week(p_agency_id, p_week_ending_date)->'people', '[]'::jsonb)) pw
    JOIN public.team t ON t.id = (pw->>'team_member_id')::uuid
    JOIN public.weekly_cpr_team_detail d ON d.team_member_id = t.id AND d.weekly_cpr_report_id = v_report.id
    WHERE t.category = 'agency'
      AND (t.archived_at IS NULL OR t.archived_at > v_week_start::timestamptz)
      AND NOT COALESCE(t.is_admin_backoffice, false)
      AND COALESCE(t.role_level,'') != 'Owner'
  ) rows;

$nb$;
  EXECUTE substring(f from 1 for s-1) || nb || substring(f from e);
END $mig$;
