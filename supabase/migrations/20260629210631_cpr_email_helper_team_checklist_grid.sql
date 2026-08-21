
CREATE OR REPLACE FUNCTION public.render_cpr_team_checklist_grid_html(
  p_report public.weekly_cpr_reports
) RETURNS text
LANGUAGE sql STABLE
AS $$
  SELECT
       '<table style="width:100%;border-collapse:collapse;font-size:12px;color:#334155"><tbody>'
    || '<tr><td style="padding:4px 8px;width:50%">'
       || CASE WHEN COALESCE(p_report.shareds_done,true) THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Shared Outlook folders</td>'
    || '<td style="padding:4px 8px;width:50%">'
       || CASE WHEN COALESCE(p_report.texts_done,true) THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Texts recorded</td></tr>'
    || '<tr><td style="padding:4px 8px">'
       || CASE WHEN COALESCE(p_report.deposits_done,true) THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Deposits finalized</td>'
    || '<td style="padding:4px 8px">'
       || CASE WHEN COALESCE(p_report.appts_done,true) THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Appointments formatted</td></tr>'
    || '<tr><td style="padding:4px 8px">'
       || CASE WHEN COALESCE(p_report.tasks_done,true) THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Tasks cleared</td>'
    || '<td style="padding:4px 8px">'
       || CASE WHEN COALESCE(p_report.cases_done,true) THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Onboarding cases created</td></tr>'
    || '<tr><td style="padding:4px 8px" colspan="2">'
       || CASE WHEN COALESCE(p_report.no_onboarding_done,true) THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Non-onboarding cases closed</td></tr>'
    || '</tbody></table>'
    || '<div style="height:10px"></div>'
    || '<div style="font-size:10px;font-weight:800;color:#64748b;letter-spacing:0.6px;text-transform:uppercase;margin:0 0 6px 4px">Opp Lists Cleared</div>'
    || '<table style="width:100%;border-collapse:collapse;font-size:12px;color:#334155"><tbody>'
    || '<tr><td style="padding:4px 8px;width:50%">'
       || CASE WHEN COALESCE(p_report.no_fu_task_done,true) THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Missing follow-up</td>'
    || '<td style="padding:4px 8px;width:50%">'
       || CASE WHEN COALESCE(p_report.new_opps_done,true) THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' New leads</td></tr>'
    || '<tr><td style="padding:4px 8px">'
       || CASE WHEN COALESCE(p_report.no_phone_done,true) THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' No phone</td>'
    || '<td style="padding:4px 8px">'
       || CASE WHEN COALESCE(p_report.bad_data_done,true) THEN '<span style="color:#16a34a;font-weight:700">✓</span>' ELSE '<span style="color:#dc2626;font-weight:700">✕</span>' END
       || ' Quotes w/ missing data</td></tr>'
    || '</tbody></table>';
$$;

