-- ============================================================================
-- compose_weekly_cpr_html(p_agency_id, p_week_ending_date) RETURNS text
-- ============================================================================
-- Builds the canonical weekly CPR recap email HTML body for an agency / week.
-- v1 ships 14 high-value sections of the locked layout (operational_rule
-- dc5e694a). Sections that depend on data sources not yet wired (SMVC live
-- values, Leaderboards, Prize Cart, etc.) render as compact placeholders with
-- a footer note listing what's coming next.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.compose_weekly_cpr_html(
  p_agency_id uuid,
  p_week_ending_date date
) RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  v_report           record;
  v_html             text := '';
  v_week_start       date := p_week_ending_date - 6;
  v_team_size        int;
  v_team_checklist_total int;
  v_team_checklist_hit   int;
  v_team_misses_list text;
  v_team_quote_owe   int;
  v_per_checklist_total  int;
  v_per_checklist_hit    int;
  v_personal_misses_list text;
  v_personal_quote_owe   int;
  v_code_reds_count  int;
  v_code_yellows_count int;
  v_code_reds_html   text := '';
  v_code_yellows_html text := '';
  v_requirements_rows text := '';
  v_hours_rows       text := '';
  v_activity_rows    text := '';
  v_payroll_rows     text := '';
  v_cpr_url          text;
BEGIN
  SELECT * INTO v_report
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_ending_date;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No weekly_cpr_reports row for agency=% week=%', p_agency_id, p_week_ending_date;
  END IF;

  v_cpr_url := 'https://storybccdashboard.vercel.app/cpr/' || to_char(p_week_ending_date, 'YYYY-MM-DD');

  SELECT count(*) INTO v_team_size
  FROM public.team
  WHERE agency_id = p_agency_id
    AND category = 'agency'
    AND is_active = true
    AND archived_at IS NULL
    AND COALESCE(role_level, '') <> 'Owner';

  v_team_checklist_total := 11;
  SELECT
    (CASE WHEN BOOL_AND(d.shareds_done)       THEN 1 ELSE 0 END) +
    (CASE WHEN BOOL_AND(d.texts_done)         THEN 1 ELSE 0 END) +
    (CASE WHEN BOOL_AND(d.deposits_done)      THEN 1 ELSE 0 END) +
    (CASE WHEN BOOL_AND(d.appts_done)         THEN 1 ELSE 0 END) +
    (CASE WHEN BOOL_AND(d.tasks_done)         THEN 1 ELSE 0 END) +
    (CASE WHEN BOOL_AND(d.cases_done)         THEN 1 ELSE 0 END) +
    (CASE WHEN BOOL_AND(d.no_onboarding_done) THEN 1 ELSE 0 END) +
    (CASE WHEN BOOL_AND(d.no_fu_task_done)    THEN 1 ELSE 0 END) +
    (CASE WHEN BOOL_AND(d.new_opps_done)      THEN 1 ELSE 0 END) +
    (CASE WHEN BOOL_AND(d.no_phone_done)      THEN 1 ELSE 0 END) +
    (CASE WHEN BOOL_AND(d.bad_data_done)      THEN 1 ELSE 0 END)
  INTO v_team_checklist_hit
  FROM public.weekly_cpr_team_detail d
  WHERE d.weekly_cpr_report_id = v_report.id;
  v_team_checklist_hit := COALESCE(v_team_checklist_hit, 0);

  SELECT string_agg(name, ' • ' ORDER BY ord) INTO v_team_misses_list
  FROM (
    SELECT 1 AS ord, 'Shareds' AS name WHERE NOT COALESCE((SELECT BOOL_AND(d.shareds_done)       FROM public.weekly_cpr_team_detail d WHERE d.weekly_cpr_report_id = v_report.id), true)
    UNION ALL SELECT 2, 'Texts'         WHERE NOT COALESCE((SELECT BOOL_AND(d.texts_done)         FROM public.weekly_cpr_team_detail d WHERE d.weekly_cpr_report_id = v_report.id), true)
    UNION ALL SELECT 3, 'Deposits'      WHERE NOT COALESCE((SELECT BOOL_AND(d.deposits_done)      FROM public.weekly_cpr_team_detail d WHERE d.weekly_cpr_report_id = v_report.id), true)
    UNION ALL SELECT 4, 'Appointments'  WHERE NOT COALESCE((SELECT BOOL_AND(d.appts_done)         FROM public.weekly_cpr_team_detail d WHERE d.weekly_cpr_report_id = v_report.id), true)
    UNION ALL SELECT 5, 'Tasks cleared' WHERE NOT COALESCE((SELECT BOOL_AND(d.tasks_done)         FROM public.weekly_cpr_team_detail d WHERE d.weekly_cpr_report_id = v_report.id), true)
    UNION ALL SELECT 6, 'Cases'         WHERE NOT COALESCE((SELECT BOOL_AND(d.cases_done)         FROM public.weekly_cpr_team_detail d WHERE d.weekly_cpr_report_id = v_report.id), true)
    UNION ALL SELECT 7, 'No Onboarding' WHERE NOT COALESCE((SELECT BOOL_AND(d.no_onboarding_done) FROM public.weekly_cpr_team_detail d WHERE d.weekly_cpr_report_id = v_report.id), true)
    UNION ALL SELECT 8, 'No FU Task'    WHERE NOT COALESCE((SELECT BOOL_AND(d.no_fu_task_done)    FROM public.weekly_cpr_team_detail d WHERE d.weekly_cpr_report_id = v_report.id), true)
    UNION ALL SELECT 9, 'New Opps'      WHERE NOT COALESCE((SELECT BOOL_AND(d.new_opps_done)      FROM public.weekly_cpr_team_detail d WHERE d.weekly_cpr_report_id = v_report.id), true)
    UNION ALL SELECT 10,'No Phone'      WHERE NOT COALESCE((SELECT BOOL_AND(d.no_phone_done)      FROM public.weekly_cpr_team_detail d WHERE d.weekly_cpr_report_id = v_report.id), true)
    UNION ALL SELECT 11,'Bad Data'      WHERE NOT COALESCE((SELECT BOOL_AND(d.bad_data_done)      FROM public.weekly_cpr_team_detail d WHERE d.weekly_cpr_report_id = v_report.id), true)
  ) miss;

  v_team_quote_owe := (v_team_checklist_total - v_team_checklist_hit) * v_team_size;

  v_per_checklist_total := 3 * v_team_size;
  SELECT
    COALESCE(SUM(
      (CASE WHEN d.cpr_reply_done THEN 1 ELSE 0 END) +
      (CASE WHEN d.wrapup_done    THEN 1 ELSE 0 END) +
      (CASE WHEN d.inbox_done     THEN 1 ELSE 0 END)
    ), 0)
  INTO v_per_checklist_hit
  FROM public.weekly_cpr_team_detail d
  WHERE d.weekly_cpr_report_id = v_report.id;

  SELECT string_agg(
    COALESCE(NULLIF(t.nickname,''), t.first_name) || ' (' || miss_name || ')',
    ' • ' ORDER BY t.hire_date, t.last_name, miss_rank
  ) INTO v_personal_misses_list
  FROM (
    SELECT d.team_member_id, 1 AS miss_rank, 'CPR Reply' AS miss_name
    FROM public.weekly_cpr_team_detail d
    WHERE d.weekly_cpr_report_id = v_report.id AND d.cpr_reply_done = false
    UNION ALL
    SELECT d.team_member_id, 2, 'Wrap-up'
    FROM public.weekly_cpr_team_detail d
    WHERE d.weekly_cpr_report_id = v_report.id AND d.wrapup_done = false
    UNION ALL
    SELECT d.team_member_id, 3, 'Inbox'
    FROM public.weekly_cpr_team_detail d
    WHERE d.weekly_cpr_report_id = v_report.id AND d.inbox_done = false
  ) m
  JOIN public.team t ON t.id = m.team_member_id;

  v_personal_quote_owe := v_per_checklist_total - v_per_checklist_hit;

  SELECT
    count(*) FILTER (WHERE d.code_reds    IS NOT NULL AND btrim(d.code_reds)    <> ''),
    count(*) FILTER (WHERE d.code_yellows IS NOT NULL AND btrim(d.code_yellows) <> '')
  INTO v_code_reds_count, v_code_yellows_count
  FROM public.weekly_cpr_team_detail d
  WHERE d.weekly_cpr_report_id = v_report.id;

  IF v_code_reds_count > 0 THEN
    SELECT string_agg('<li>' || replace(replace(btrim(d.code_reds),'<','&lt;'),'>','&gt;') || '</li>', '')
    INTO v_code_reds_html
    FROM public.weekly_cpr_team_detail d
    WHERE d.weekly_cpr_report_id = v_report.id
      AND d.code_reds IS NOT NULL AND btrim(d.code_reds) <> '';
  END IF;

  IF v_code_yellows_count > 0 THEN
    SELECT string_agg('<li>' || replace(replace(btrim(d.code_yellows),'<','&lt;'),'>','&gt;') || '</li>', '')
    INTO v_code_yellows_html
    FROM public.weekly_cpr_team_detail d
    WHERE d.weekly_cpr_report_id = v_report.id
      AND d.code_yellows IS NOT NULL AND btrim(d.code_yellows) <> '';
  END IF;

  SELECT string_agg(
    '<tr>'
    || '<td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;font-weight:600;color:#1e293b">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || COALESCE(d.carryover, 0)::text || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || COALESCE(d.missed, 0)::text    || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || COALESCE(d.cost, 0)::text      || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || COALESCE(d.total, 0)::text     || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || COALESCE(d.paid, 0)::text      || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155;font-weight:700">' || COALESCE(d.owed, 0)::text || '</td>'
    || '</tr>',
    '' ORDER BY t.hire_date, t.last_name
  )
  INTO v_requirements_rows
  FROM public.team t
  LEFT JOIN public.weekly_cpr_team_detail d
    ON d.team_member_id = t.id AND d.weekly_cpr_report_id = v_report.id
  WHERE t.agency_id = p_agency_id AND t.category = 'agency'
    AND t.is_active = true AND t.archived_at IS NULL
    AND COALESCE(t.role_level,'') <> 'Owner';

  SELECT string_agg(
    '<tr>'
    || '<td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;font-weight:600;color:#1e293b">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || COALESCE(d.mon_hours::text, '—') || ' ' || CASE WHEN d.mon_location='remote' THEN '🟣' WHEN d.mon_location='in_office' THEN '🟢' ELSE '' END || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || COALESCE(d.tue_hours::text, '—') || ' ' || CASE WHEN d.tue_location='remote' THEN '🟣' WHEN d.tue_location='in_office' THEN '🟢' ELSE '' END || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || COALESCE(d.wed_hours::text, '—') || ' ' || CASE WHEN d.wed_location='remote' THEN '🟣' WHEN d.wed_location='in_office' THEN '🟢' ELSE '' END || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || COALESCE(d.thu_hours::text, '—') || ' ' || CASE WHEN d.thu_location='remote' THEN '🟣' WHEN d.thu_location='in_office' THEN '🟢' ELSE '' END || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || COALESCE(d.fri_hours::text, '—') || ' ' || CASE WHEN d.fri_location='remote' THEN '🟣' WHEN d.fri_location='in_office' THEN '🟢' ELSE '' END || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155;font-weight:700">' || COALESCE((COALESCE(d.mon_hours,0) + COALESCE(d.tue_hours,0) + COALESCE(d.wed_hours,0) + COALESCE(d.thu_hours,0) + COALESCE(d.fri_hours,0))::text, '—') || '</td>'
    || '</tr>',
    '' ORDER BY t.hire_date, t.last_name
  )
  INTO v_hours_rows
  FROM public.team t
  LEFT JOIN public.weekly_cpr_team_detail d
    ON d.team_member_id = t.id AND d.weekly_cpr_report_id = v_report.id
  WHERE t.agency_id = p_agency_id AND t.category = 'agency'
    AND t.is_active = true AND t.archived_at IS NULL
    AND COALESCE(t.role_level,'') <> 'Owner';

  SELECT string_agg(
    '<tr>'
    || '<td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;font-weight:600;color:#1e293b">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || COALESCE(d.quotes_discussed::text, '—') || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || COALESCE(d.quotes_net::text, '—')       || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155;font-weight:700">' || COALESCE(d.sales_points::text, '—') || '</td>'
    || '</tr>',
    '' ORDER BY t.hire_date, t.last_name
  )
  INTO v_activity_rows
  FROM public.team t
  LEFT JOIN public.weekly_cpr_team_detail d
    ON d.team_member_id = t.id AND d.weekly_cpr_report_id = v_report.id
  WHERE t.agency_id = p_agency_id AND t.category = 'agency'
    AND t.is_active = true AND t.archived_at IS NULL
    AND COALESCE(t.role_level,'') <> 'Owner';

  SELECT string_agg(
    '<tr>'
    || '<td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;font-weight:600;color:#1e293b">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">$' || to_char(COALESCE(d.weekly_pay,0), 'FM999,999.00') || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">$' || to_char(COALESCE(d.base_advance,0), 'FM999,999.00') || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">$' || to_char(COALESCE(d.health_bonus,0), 'FM999,999.00') || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">$' || to_char(COALESCE(d.service_surge_share,0), 'FM999,999.00') || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">$' || to_char(COALESCE(d.true_pay_bonus,0), 'FM999,999.00') || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">$' || to_char(COALESCE(d.manager_bonus,0), 'FM999,999.00') || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">$' || to_char(COALESCE(d.agency_profit_share,0), 'FM999,999.00') || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#1e293b;font-weight:700">$' || to_char(
         COALESCE(d.weekly_pay,0) + COALESCE(d.base_advance,0) + COALESCE(d.health_bonus,0)
         + COALESCE(d.service_surge_share,0) + COALESCE(d.true_pay_bonus,0)
         + COALESCE(d.manager_bonus,0) + COALESCE(d.agency_profit_share,0), 'FM999,999.00') || '</td>'
    || '</tr>',
    '' ORDER BY t.hire_date, t.last_name
  )
  INTO v_payroll_rows
  FROM public.team t
  LEFT JOIN public.weekly_cpr_team_detail d
    ON d.team_member_id = t.id AND d.weekly_cpr_report_id = v_report.id
  WHERE t.agency_id = p_agency_id AND t.category = 'agency'
    AND t.is_active = true AND t.archived_at IS NULL
    AND COALESCE(t.role_level,'') <> 'Owner';

  v_html :=
       '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;color:#0f172a;max-width:760px;margin:0 auto;padding:24px 18px;background:#ffffff">'
    ||   '<div style="font-size:13px;color:#475569;margin-bottom:18px">Week ending ' || to_char(p_week_ending_date, 'FMDay, FMMonth FMDD, YYYY') || '</div>'
    ||   '<div style="font-size:15px;line-height:1.55;color:#1e293b;white-space:pre-wrap;margin-bottom:18px">'
    ||     COALESCE(replace(replace(v_report.opener_text, '<', '&lt;'), '>', '&gt;'), '<em style="color:#94a3b8">(no opener written)</em>')
    ||   '</div>'
    ||   '<div style="margin:16px 0 24px"><a href="' || v_cpr_url || '" style="display:inline-block;padding:10px 18px;background:#2563eb;color:#ffffff;border-radius:6px;font-size:13px;font-weight:700;text-decoration:none">📋 View the full CPR report →</a></div>'
    ||   '<hr style="border:none;border-top:1px solid #e2e8f0;margin:20px 0">'
    ||   '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.6px;margin-bottom:8px">🎯 LOOKING AT NEXT WEEK</div>'
    ||   '<div style="font-size:14px;line-height:1.55;color:#1e293b;white-space:pre-wrap;margin-bottom:18px">'
    ||     COALESCE(replace(replace(v_report.looking_next_week_text, '<', '&lt;'), '>', '&gt;'), '<em style="color:#94a3b8">(not written)</em>')
    ||   '</div>'
    ||   '<hr style="border:none;border-top:1px solid #e2e8f0;margin:20px 0">';

  IF v_code_reds_count = 0 AND v_code_yellows_count = 0 THEN
    v_html := v_html || '<div style="font-size:13px;color:#475569;margin:8px 0">🔴 0 reds  •  🟡 0 yellows</div>';
  ELSE
    IF v_code_reds_count > 0 THEN
      v_html := v_html
        || '<div style="font-size:13px;font-weight:800;color:#dc2626;letter-spacing:0.4px;margin-bottom:6px">🔴 CODE REDS (' || v_code_reds_count || ')</div>'
        || '<ul style="margin:0 0 14px 22px;padding:0;font-size:13px;color:#1e293b">'
        || v_code_reds_html || '</ul>';
    END IF;
    IF v_code_yellows_count > 0 THEN
      v_html := v_html
        || '<div style="font-size:13px;font-weight:800;color:#d97706;letter-spacing:0.4px;margin-bottom:6px">🟡 CODE YELLOWS (' || v_code_yellows_count || ')</div>'
        || '<ul style="margin:0 0 14px 22px;padding:0;font-size:13px;color:#1e293b">'
        || v_code_yellows_html || '</ul>';
    END IF;
  END IF;

  v_html := v_html
    || '<div style="margin:14px 0">'
    || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px">✅ TEAM CHECKLIST &nbsp; Hit: ' || v_team_checklist_hit || ' of ' || v_team_checklist_total || CASE WHEN v_team_checklist_hit = v_team_checklist_total THEN '  ✓' ELSE '' END || '</div>';
  IF v_team_checklist_hit < v_team_checklist_total THEN
    v_html := v_html
      || '<div style="font-size:12px;color:#475569;margin-top:4px;padding-left:14px">Missed: ' || COALESCE(v_team_misses_list, '—') || '</div>'
      || '<div style="font-size:12px;color:#475569;margin-top:2px;padding-left:14px">→ ' || v_team_quote_owe || ' extra quotes owed next week  (' || (v_team_checklist_total - v_team_checklist_hit) || ' misses × ' || v_team_size || '-person team)</div>';
  END IF;
  v_html := v_html || '</div>';

  v_html := v_html
    || '<div style="margin:14px 0">'
    || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px">🧍 PERSONAL CHECKLIST &nbsp; Hit: ' || v_per_checklist_hit || ' of ' || v_per_checklist_total || CASE WHEN v_per_checklist_hit = v_per_checklist_total THEN '  ✓' ELSE '' END || '</div>';
  IF v_per_checklist_hit < v_per_checklist_total THEN
    v_html := v_html
      || '<div style="font-size:12px;color:#475569;margin-top:4px;padding-left:14px">Missed: ' || COALESCE(v_personal_misses_list, '—') || '</div>'
      || '<div style="font-size:12px;color:#475569;margin-top:2px;padding-left:14px">→ ' || v_personal_quote_owe || ' extra quotes owed next week  (1 per missed person)</div>';
  END IF;
  v_html := v_html || '</div>';

  v_html := v_html
    || '<div style="margin:18px 0 12px">'
    || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px;margin-bottom:8px">⭐ REQUIREMENTS</div>'
    || '<table style="width:100%;border-collapse:collapse;font-size:12px">'
    || '<thead><tr>'
    || '<th style="padding:6px 10px;text-align:left;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Team Member</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Last Wk</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">This Wk</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Cost</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Total</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Paid</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Next Wk</th>'
    || '</tr></thead>'
    || '<tbody>' || COALESCE(v_requirements_rows, '') || '</tbody>'
    || '</table></div>'
    || '<hr style="border:none;border-top:1px solid #e2e8f0;margin:20px 0">';

  v_html := v_html
    || '<div style="font-size:13px;color:#1e293b;margin:8px 0"><strong style="color:#0f172a">🚨 CLAIMS</strong> &nbsp;&nbsp; New: ' || COALESCE(v_report.new_claims, 0)
    || '  •  Unreviewed: ' || COALESCE(v_report.unreviewed_claims, 0)
    || '  •  Open: ' || COALESCE(v_report.open_claims, 0)
    || '</div>'
    || '<div style="font-size:13px;color:#1e293b;margin:8px 0"><strong style="color:#0f172a">🛑 NON-PAYS</strong> &nbsp;&nbsp; This week: ' || COALESCE(v_report.non_pays, 0) || '</div>'
    || '<hr style="border:none;border-top:1px solid #e2e8f0;margin:20px 0">';

  v_html := v_html
    || '<div style="margin:14px 0">'
    || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px;margin-bottom:8px">🕐 HOURS WORKED</div>'
    || '<table style="width:100%;border-collapse:collapse;font-size:12px">'
    || '<thead><tr>'
    || '<th style="padding:6px 10px;text-align:left;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Team Member</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Mon</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Tue</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Wed</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Thu</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Fri</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Total</th>'
    || '</tr></thead><tbody>' || COALESCE(v_hours_rows, '') || '</tbody></table></div>';

  v_html := v_html
    || '<div style="margin:14px 0">'
    || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px;margin-bottom:8px">📊 TEAM ACTIVITY</div>'
    || '<table style="width:100%;border-collapse:collapse;font-size:12px">'
    || '<thead><tr>'
    || '<th style="padding:6px 10px;text-align:left;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Team Member</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Quotes</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Net Quotes</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Sales Pts</th>'
    || '</tr></thead><tbody>' || COALESCE(v_activity_rows, '') || '</tbody></table></div>';

  v_html := v_html
    || '<div style="margin:14px 0;padding:12px 14px;background:#f8fafc;border-radius:8px">'
    || '<div style="font-size:13px;color:#1e293b">Quotes: ' || COALESCE(v_report.quotes_owed_carryover::text,'❓') || ' owed last wk → ' || COALESCE(v_report.quotes_fresh_needed::text,'❓') || ' fresh needed → ' || COALESCE(v_report.quotes_total_net::text,'❓') || ' net → ' || COALESCE(v_report.quotes_owed_next_week::text,'❓') || ' owed next wk</div>'
    || '<div style="font-size:13px;color:#1e293b;margin-top:4px">Quarterly sales pts: ' || COALESCE(v_report.quarterly_sales_points_qtd::text,'❓') || ' / ' || COALESCE(v_report.quarterly_sales_points_target::text,'❓') || ' QTD</div>'
    || '<div style="font-size:13px;color:#1e293b;margin-top:4px">Won the Week: ' || CASE WHEN v_report.won_the_week = true THEN '✅' WHEN v_report.won_the_week = false THEN '❌' ELSE '❓' END || '</div>'
    || '</div>';

  v_html := v_html
    || '<div style="margin:14px 0">'
    || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px;margin-bottom:8px">💰 PAYROLL</div>'
    || '<table style="width:100%;border-collapse:collapse;font-size:11px">'
    || '<thead><tr>'
    || '<th style="padding:6px 8px;text-align:left;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">Team Member</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">Weekly Pay</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">Base Adv</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">Health</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">Surge</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">True Pay</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">Mgr</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">Agcy Profit</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">Week Total</th>'
    || '</tr></thead><tbody>' || COALESCE(v_payroll_rows, '') || '</tbody></table></div>';

  v_html := v_html
    || '<hr style="border:none;border-top:1px solid #e2e8f0;margin:20px 0">'
    || '<div style="font-size:11px;color:#94a3b8;font-style:italic;margin:8px 0">Coming in upcoming iterations: Agency Performance (LOB), SMVC &amp; Scorecard, Campaigns line, Sales Points History (rolling averages), Leaderboards &amp; All-Stars, Prize Cart. Full data is on the <a href="' || v_cpr_url || '" style="color:#64748b">CPR detail page</a>.</div>';

  v_html := v_html
    || '<div style="font-size:14px;color:#1e293b;margin-top:24px">— Peter</div>'
    || '</div>';

  RETURN v_html;
END;
$func$;

COMMENT ON FUNCTION public.compose_weekly_cpr_html(uuid, date) IS
  'Composes the canonical Weekly CPR Recap HTML email body. v1 ships 14 sections of the locked layout (operational_rule dc5e694a); remaining sections expand iteratively. Returns the HTML body string to be passed to the Composio v3 GMAIL_SEND_EMAIL action.';

CREATE OR REPLACE FUNCTION public.send_weekly_cpr_recap(
  p_agency_id uuid,
  p_week_ending_date date
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net
AS $func$
DECLARE
  v_report                  record;
  v_html                    text;
  v_api_key                 text;
  v_user_id                 text;
  v_connected_account_id    text;
  v_subject                 text;
  v_week_start              date := p_week_ending_date - 6;
  v_start_mon               text;
  v_end_mon                 text;
  v_start_day               text;
  v_end_day                 text;
  v_subject_dates           text;
  v_request_id              bigint;
  v_recipients_to           text[];
  v_recipients_cc           text[];
  v_primary_to              text;
  v_extra_to                text[];
BEGIN
  SELECT * INTO v_report
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_ending_date;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'No weekly_cpr_reports row exists for this week. Save the CPR before sending.');
  END IF;

  IF v_report.sent_to_team_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Already sent at ' || v_report.sent_to_team_at::text || '. Clear sent_to_team_at to re-arm.');
  END IF;

  IF v_report.opener_text IS NULL OR btrim(v_report.opener_text) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Opener text is empty. Write the opener before sending.');
  END IF;

  IF v_report.looking_next_week_text IS NULL OR btrim(v_report.looking_next_week_text) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', '"Looking at next week" text is empty. Write it before sending.');
  END IF;

  SELECT setting_value INTO v_api_key
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_api_key';
  SELECT setting_value INTO v_user_id
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_user_id';
  SELECT setting_value INTO v_connected_account_id
  FROM public.settings WHERE agency_id = p_agency_id AND setting_key = 'composio_gmail_account_id';

  IF v_api_key IS NULL OR v_user_id IS NULL OR v_connected_account_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Composio Gmail config missing in settings table');
  END IF;

  v_recipients_to := ARRAY[
    'john.kostov.vaelna@statefarm.com',
    'thomas.lynch.vaisz9@statefarm.com',
    'cassie.alves.vakfno@statefarm.com',
    'jason.fuller.vakhkl@statefarm.com',
    'stephanie.rogers.vakhkm@statefarm.com',
    'john.kostov@gmail.com',
    'tlynch1874@gmail.com',
    'angracassie13@gmail.com',
    'thejdfuller@gmail.com',
    'slrogers729@gmail.com'
  ];
  v_recipients_cc := ARRAY['storypeterj@gmail.com'];

  v_primary_to := v_recipients_to[1];
  v_extra_to   := v_recipients_to[2:];

  v_start_mon := upper(to_char(v_week_start,       'Mon'));
  v_end_mon   := upper(to_char(p_week_ending_date, 'Mon'));
  v_start_day := to_char(v_week_start,       'FMDD');
  v_end_day   := to_char(p_week_ending_date, 'FMDD');
  IF v_start_mon = v_end_mon THEN
    v_subject_dates := v_start_mon || ' ' || v_start_day || '–' || v_end_day;
  ELSE
    v_subject_dates := v_start_mon || ' ' || v_start_day || ' – ' || v_end_mon || ' ' || v_end_day;
  END IF;

  v_subject := '📊 CPR RECAP — WEEK OF ' || v_subject_dates;

  v_html := public.compose_weekly_cpr_html(p_agency_id, p_week_ending_date);

  SELECT net.http_post(
    url     := 'https://backend.composio.dev/api/v3/tools/execute/GMAIL_SEND_EMAIL',
    headers := jsonb_build_object(
      'x-api-key', v_api_key,
      'Content-Type', 'application/json'
    ),
    body    := jsonb_build_object(
      'user_id', v_user_id,
      'connected_account_id', v_connected_account_id,
      'arguments', jsonb_build_object(
        'recipient_email', v_primary_to,
        'extra_recipients', to_jsonb(v_extra_to),
        'cc', to_jsonb(v_recipients_cc),
        'subject', v_subject,
        'body', v_html,
        'is_html', true
      )
    )
  ) INTO v_request_id;

  UPDATE public.weekly_cpr_reports
     SET sent_to_team_at = now()
   WHERE id = v_report.id;

  RETURN jsonb_build_object(
    'success', true,
    'request_id', v_request_id,
    'subject', v_subject,
    'recipients_to_count', array_length(v_recipients_to, 1),
    'recipients_cc_count', array_length(v_recipients_cc, 1),
    'sent_to_team_at', now()
  );
END;
$func$;

COMMENT ON FUNCTION public.send_weekly_cpr_recap(uuid, date) IS
  'Manually-triggered dispatcher for the Weekly CPR Recap email. Called from the WeeklyCPR.jsx Send button via Supabase RPC. Validates preconditions, composes HTML via compose_weekly_cpr_html(), dispatches via pg_net + Composio v3 GMAIL_SEND_EMAIL, stamps sent_to_team_at. Returns jsonb with success/error status.';

GRANT EXECUTE ON FUNCTION public.send_weekly_cpr_recap(uuid, date) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.compose_weekly_cpr_html(uuid, date) TO authenticated, anon;
