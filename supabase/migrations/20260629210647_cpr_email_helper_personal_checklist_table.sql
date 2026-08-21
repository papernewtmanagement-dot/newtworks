
CREATE OR REPLACE FUNCTION public.render_cpr_personal_checklist_html(
  p_agency_id uuid, p_week_ending_date date
) RETURNS text
LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_rows text;
BEGIN
  SELECT string_agg(
    '<tr><td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;font-weight:600;color:#1e293b">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</td>'
    || '<td style="padding:6px 10px;text-align:center;border-bottom:1px solid #e5e7eb">'
       || CASE WHEN d.cpr_reply_done = true THEN '<span style="color:#16a34a;font-weight:700">✓</span>'
               WHEN d.cpr_reply_done = false THEN '<span style="color:#dc2626;font-weight:700">✕</span>'
               ELSE '<span style="color:#cbd5e1">—</span>' END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:center;border-bottom:1px solid #e5e7eb">'
       || CASE WHEN d.wrapup_done = true THEN '<span style="color:#16a34a;font-weight:700">✓</span>'
               WHEN d.wrapup_done = false THEN '<span style="color:#dc2626;font-weight:700">✕</span>'
               ELSE '<span style="color:#cbd5e1">—</span>' END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:center;border-bottom:1px solid #e5e7eb">'
       || CASE WHEN d.inbox_done = true THEN '<span style="color:#16a34a;font-weight:700">✓</span>'
               WHEN d.inbox_done = false THEN '<span style="color:#dc2626;font-weight:700">✕</span>'
               ELSE '<span style="color:#cbd5e1">—</span>' END
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
    AND COALESCE(t.role_level,'') <> 'Owner';

  RETURN
       '<table style="width:100%;border-collapse:collapse;font-size:12px"><thead><tr>'
    || '<th style="padding:6px 10px;text-align:left;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Person</th>'
    || '<th style="padding:6px 10px;text-align:center;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">CPR Reply</th>'
    || '<th style="padding:6px 10px;text-align:center;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Wrap-up</th>'
    || '<th style="padding:6px 10px;text-align:center;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Inbox</th>'
    || '</tr></thead><tbody>' || COALESCE(v_rows,'') || '</tbody></table>';
END;
$$;

