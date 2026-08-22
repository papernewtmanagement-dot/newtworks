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
  -- SMVC (% rates)
  v_on_time   numeric;
  v_last_wk   numeric;
  v_last_q    numeric;
  v_last_year numeric;
  v_diff      numeric;
  -- Scorecard ($)
  v_sc_on_time   numeric;
  v_sc_last_wk   numeric;
  v_sc_last_q    numeric;
  v_sc_last_year numeric;
  v_sc_diff      numeric;
  -- Budgets
  v_prize_budget numeric;
  v_wtq_budget   numeric;
BEGIN
  v_data := public.get_cpr_section_11(p_agency_id, p_week_ending_date);
  v_smvc := v_data->'smvc';
  v_sc   := v_data->'scorecard_bonus';

  v_on_time   := NULLIF(v_smvc->>'on_time',     '')::numeric;
  v_last_wk   := NULLIF(v_smvc->>'last_wk',     '')::numeric;
  v_last_q    := NULLIF(v_smvc->>'last_q',      '')::numeric;
  v_last_year := NULLIF(v_smvc->>'last_year',   '')::numeric;
  v_diff      := NULLIF(v_smvc->>'dollar_diff', '')::numeric;

  v_sc_on_time   := NULLIF(v_sc->>'on_time',     '')::numeric;
  v_sc_last_wk   := NULLIF(v_sc->>'last_wk',     '')::numeric;
  v_sc_last_q    := NULLIF(v_sc->>'last_q',      '')::numeric;
  v_sc_last_year := NULLIF(v_sc->>'last_year',   '')::numeric;
  v_sc_diff      := NULLIF(v_sc->>'dollar_diff', '')::numeric;

  v_prize_budget := NULLIF((v_data->'prize_cart_budget'->>'value'), '')::numeric;
  v_wtq_budget   := NULLIF((v_data->'wtq_trip_budget'->>'value'), '')::numeric;

  -- Header row: Last Wk | Last Q | Last Year | On-Time | $ Diff
  v_html :=
       '<div style="margin:18px 0 12px">'
    || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px;margin-bottom:8px">🎯 SMVC &amp; SCORECARD</div>'
    || '<table style="width:100%;border-collapse:collapse;font-size:12px">'
    || '<thead><tr>'
    || '<th style="padding:6px 10px;text-align:left;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px"></th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Last Wk</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Last Q</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px;background:#f1f5f9">Last Year</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">On-Time</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px;background:#eff6ff">$ Diff</th>'
    || '</tr></thead>'
    || '<tbody>';

  -- SMVC row: Last Wk | Last Q | Last Year | On-Time | $ Diff
  v_html := v_html
    || '<tr>'
    || '<td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;font-weight:600;color:#1e293b">SMVC</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'
       || CASE WHEN v_last_wk IS NULL THEN '—' ELSE to_char(v_last_wk * 100, 'FM990.00') || '%' END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'
       || CASE WHEN v_last_q IS NULL THEN '—' ELSE to_char(v_last_q * 100, 'FM990.00') || '%' END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155;font-weight:700;background:#f1f5f9">'
       || CASE WHEN v_last_year IS NULL THEN '—' ELSE to_char(v_last_year * 100, 'FM990.00') || '%' END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'
       || CASE WHEN v_on_time IS NULL THEN '—' ELSE to_char(v_on_time * 100, 'FM990.00') || '%' END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;font-weight:700;background:#eff6ff;color:'
       || CASE WHEN v_diff IS NULL THEN '#64748b' WHEN v_diff >= 0 THEN '#15803d' ELSE '#b91c1c' END
       || '">'
       || CASE WHEN v_diff IS NULL THEN '—'
               ELSE (CASE WHEN v_diff >= 0 THEN '+$' ELSE '-$' END)
                    || to_char(ABS(v_diff), 'FM999,999,999') END
       || '</td>'
    || '</tr>';

  -- Scorecard Bonus row: Last Wk | Last Q | Last Year | On-Time | $ Diff
  v_html := v_html
    || '<tr>'
    || '<td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;font-weight:600;color:#1e293b">Scorecard Bonus</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#94a3b8">'
       || CASE WHEN v_sc_last_wk IS NULL THEN '—'
               ELSE '$' || to_char(ROUND(v_sc_last_wk), 'FM999,999,999') END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#94a3b8">'
       || CASE WHEN v_sc_last_q IS NULL THEN '—'
               ELSE '$' || to_char(ROUND(v_sc_last_q), 'FM999,999,999') END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;font-weight:700;background:#f1f5f9;color:'
       || CASE WHEN v_sc_last_year IS NULL THEN '#94a3b8' ELSE '#334155' END
       || '">'
       || CASE WHEN v_sc_last_year IS NULL THEN '—'
               ELSE '$' || to_char(ROUND(v_sc_last_year), 'FM999,999,999') END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'
       || CASE WHEN v_sc_on_time IS NULL THEN '—'
               ELSE '$' || to_char(ROUND(v_sc_on_time), 'FM999,999,999') END
       || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;font-weight:700;background:#eff6ff;color:'
       || CASE WHEN v_sc_diff IS NULL THEN '#64748b' WHEN v_sc_diff >= 0 THEN '#15803d' ELSE '#b91c1c' END
       || '">'
       || CASE WHEN v_sc_diff IS NULL THEN '—'
               ELSE (CASE WHEN v_sc_diff >= 0 THEN '+$' ELSE '-$' END)
                    || to_char(ABS(ROUND(v_sc_diff)), 'FM999,999,999') END
       || '</td>'
    || '</tr>'
    || '</tbody></table>'
    || '<table style="width:100%;border-collapse:collapse;margin-top:8px"><tr>'
    || '<td style="width:50%;padding:0 18px;vertical-align:top;font-size:12px;color:#475569">Prize Cart Budget: '
       || '<span style="' || CASE WHEN v_prize_budget IS NULL THEN 'color:#94a3b8' ELSE 'color:#0f172a;font-weight:700' END || '">'
       || CASE WHEN v_prize_budget IS NULL THEN '—' ELSE '$' || to_char(ROUND(v_prize_budget), 'FM999,999,999') END
       || '</span></td>'
    || '<td style="width:50%;padding:0 18px;vertical-align:top;font-size:12px;color:#475569">WtQ Trip Budget: '
       || '<span style="' || CASE WHEN v_wtq_budget IS NULL THEN 'color:#94a3b8' ELSE 'color:#0f172a;font-weight:700' END || '">'
       || CASE WHEN v_wtq_budget IS NULL THEN '—' ELSE '$' || to_char(ROUND(v_wtq_budget), 'FM999,999,999') END
       || '</span></td>'
    || '</tr></table>'
    || '</div>';

  RETURN v_html;
END;
$function$;
