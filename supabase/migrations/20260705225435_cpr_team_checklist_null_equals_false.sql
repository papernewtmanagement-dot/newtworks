-- Peter directive 2026-07-05: NULL = false. render_cpr_team_checklist_grid_html now two-state.
-- true → ✓ green; anything else (false OR NULL) → ✕ red.
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
