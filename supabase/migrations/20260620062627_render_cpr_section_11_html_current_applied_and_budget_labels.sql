CREATE OR REPLACE FUNCTION public.render_cpr_section_11_html(p_agency_id uuid, p_week_ending_date date)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_data      jsonb;
  v_smvc      jsonb;
  v_sc        jsonb;
  v_html      text := '';
  v_on_time   numeric;
  v_last_wk   numeric;
  v_last_q    numeric;
  v_current   numeric;
  v_diff      numeric;

  -- HTML formatting helpers (inline)
  fmt_pct text;
  fmt_dollar text;
BEGIN
  v_data := public.get_cpr_section_11(p_agency_id, p_week_ending_date);
  v_smvc := v_data->'smvc';
  v_sc   := v_data->'scorecard_bonus';

  v_on_time := NULLIF(v_smvc->>'on_time', '')::numeric;
  v_last_wk := NULLIF(v_smvc->>'last_wk', '')::numeric;
  v_last_q  := NULLIF(v_smvc->>'last_q', '')::numeric;
  -- "Current" column = this year's applied SMVC rate (agency.smvc_rate_pc).
  -- get_cpr_section_11 surfaces this as smvc.applied. The smvc.current field
  -- (= pre-Better-Of live pace) is no longer rendered. Mirrors CPRDetail.jsx.
  v_current := NULLIF(v_smvc->>'applied', '')::numeric;
  v_diff    := NULLIF(v_smvc->>'dollar_diff', '')::numeric;

  v_html :=
       '<div style="margin:18px 0 12px">'
    || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px;margin-bottom:8px">🎯 SMVC &amp; SCORECARD</div>'
    || '<table style="width:100%;border-collapse:collapse;font-size:12px">'
    || '<thead><tr>'
    || '<th style="padding:6px 10px;text-align:left;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px"></th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">On-Time</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Last Wk</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Last Q</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Current</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px;background:#eff6ff">$ Diff</th>'
    || '</tr></thead>'
    || '<tbody>';

  -- SMVC row
  v_html := v_html
    || '<tr>'
    || '<td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;font-weight:600;color:#1e293b">SMVC</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'
       || CASE WHEN v_on_time IS NULL THEN '—' ELSE to_char(v_on_time * 100, 'FM990.00') || '%' END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'
       || CASE WHEN v_last_wk IS NULL THEN '—' ELSE to_char(v_last_wk * 100, 'FM990.00') || '%' END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'
       || CASE WHEN v_last_q IS NULL THEN '—' ELSE to_char(v_last_q * 100, 'FM990.00') || '%' END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155;font-weight:700">'
       || CASE WHEN v_current IS NULL THEN '—' ELSE to_char(v_current * 100, 'FM990.00') || '%' END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;font-weight:700;background:#eff6ff;color:'
       || CASE WHEN v_diff IS NULL THEN '#64748b' WHEN v_diff >= 0 THEN '#15803d' ELSE '#b91c1c' END
       || '">'
       || CASE WHEN v_diff IS NULL THEN '—'
               ELSE (CASE WHEN v_diff >= 0 THEN '+$' ELSE '-$' END)
                    || to_char(ABS(v_diff), 'FM999,999,999') END
       || '</td>'
    || '</tr>';

  -- Scorecard Bonus row (all placeholders for now)
  v_html := v_html
    || '<tr>'
    || '<td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;font-weight:600;color:#1e293b">Scorecard Bonus</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#94a3b8">—</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#94a3b8">—</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#94a3b8">—</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#94a3b8">—</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#94a3b8;background:#eff6ff">—</td>'
    || '</tr>'
    || '</tbody></table>'
    -- Two budget lines (Peter 2026-06-20 evening: "Next Quarter On-Time " prefix stripped)
    || '<div style="font-size:12px;color:#475569;margin-top:8px;padding-left:14px">Prize Cart Budget: <span style="color:#94a3b8">—</span></div>'
    || '<div style="font-size:12px;color:#475569;margin-top:2px;padding-left:14px">WtQ Trip Budget: <span style="color:#94a3b8">—</span></div>'
    -- Footnote about what's pending
    || '<div style="font-size:11px;color:#94a3b8;font-style:italic;margin-top:6px;padding-left:14px">SMVC row computed live. Scorecard Bonus row + budget lines pending compute_scorecard_bonus() function and budget formulas.</div>'
    || '</div>';

  RETURN v_html;
END;
$function$;
