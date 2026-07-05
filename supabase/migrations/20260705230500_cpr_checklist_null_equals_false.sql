-- Peter directive 2026-07-05: NULL = false. render_cpr_team_checklist_grid_html + render_cpr_personal_checklist_html now two-state.
-- true → ✓ green; anything else (false OR NULL) → ✕ red. Supersedes 20260705225000_cpr_team_checklist_null_as_miss.

CREATE OR REPLACE FUNCTION public.render_cpr_team_checklist_grid_html(p_report weekly_cpr_reports)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT
       '<table style="width:100%;border-collapse:collapse;font-size:12px;color:#334155"><tbody>'
    || '<tr><td style="padding:4px 8px;width:50%">'
       || CASE WHEN p_report.shareds_done IS TRUE THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Shared Outlook folders</td>'
    || '<td style="padding:4px 8px;width:50%">'
       || CASE WHEN p_report.texts_done IS TRUE THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Texts recorded</td></tr>'
    || '<tr><td style="padding:4px 8px">'
       || CASE WHEN p_report.deposits_done IS TRUE THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Deposits finalized</td>'
    || '<td style="padding:4px 8px">'
       || CASE WHEN p_report.appts_done IS TRUE THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Appointments formatted</td></tr>'
    || '<tr><td style="padding:4px 8px">'
       || CASE WHEN p_report.tasks_done IS TRUE THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Tasks cleared</td>'
    || '<td style="padding:4px 8px">'
       || CASE WHEN p_report.cases_done IS TRUE THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Onboarding cases created</td></tr>'
    || '<tr><td style="padding:4px 8px" colspan="2">'
       || CASE WHEN p_report.no_onboarding_done IS TRUE THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Non-onboarding cases closed</td></tr>'
    || '</tbody></table>'
    || '<div style="height:10px"></div>'
    || '<div style="font-size:10px;font-weight:800;color:#64748b;letter-spacing:0.6px;text-transform:uppercase;margin:0 0 6px 4px">Opp Lists Cleared</div>'
    || '<table style="width:100%;border-collapse:collapse;font-size:12px;color:#334155"><tbody>'
    || '<tr><td style="padding:4px 8px;width:50%">'
       || CASE WHEN p_report.no_fu_task_done IS TRUE THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Missing follow-up</td>'
    || '<td style="padding:4px 8px;width:50%">'
       || CASE WHEN p_report.new_opps_done IS TRUE THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' New leads</td></tr>'
    || '<tr><td style="padding:4px 8px">'
       || CASE WHEN p_report.no_phone_done IS TRUE THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' No phone</td>'
    || '<td style="padding:4px 8px">'
       || CASE WHEN p_report.bad_data_done IS TRUE THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Quotes w/ missing data</td></tr>'
    || '</tbody></table>';
$function$;

CREATE OR REPLACE FUNCTION public.render_cpr_personal_checklist_html(p_agency_id uuid, p_week_ending_date date)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_rows text;
BEGIN
  SELECT string_agg(
    '<tr><td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;font-weight:600;color:#1e293b">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</td>'
    || '<td style="padding:6px 10px;text-align:center;border-bottom:1px solid #e5e7eb">'
       || CASE WHEN d.cpr_reply_done IS TRUE THEN '<span style="color:#16a34a;font-weight:700">✓</span>'
               ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:center;border-bottom:1px solid #e5e7eb">'
       || CASE WHEN d.wrapup_done IS TRUE THEN '<span style="color:#16a34a;font-weight:700">✓</span>'
               ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:center;border-bottom:1px solid #e5e7eb">'
       || CASE WHEN d.inbox_done IS TRUE THEN '<span style="color:#16a34a;font-weight:700">✓</span>'
               ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || '</td></tr>',
    '' ORDER BY t.hire_date, t.last_name
  )
  INTO v_rows
  FROM public.weekly_cpr_team_detail d
  JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
  JOIN public.team t ON t.id = d.team_member_id
  WHERE r.agency_id = p_agency_id
    AND r.week_ending_date = p_week_ending_date
    AND t.category = 'agency'
    AND COALESCE(t.role_level,'') <> 'Owner'
    AND t.is_admin_backoffice = false;

  RETURN
       '<table style="width:100%;border-collapse:collapse;font-size:12px"><thead><tr>'
    || '<th style="padding:6px 10px;text-align:left;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Person</th>'
    || '<th style="padding:6px 10px;text-align:center;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">CPR Reply</th>'
    || '<th style="padding:6px 10px;text-align:center;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Wrap-up</th>'
    || '<th style="padding:6px 10px;text-align:center;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Inbox</th>'
    || '</tr></thead><tbody>' || COALESCE(v_rows,'') || '</tbody></table>';
END;
$function$;
