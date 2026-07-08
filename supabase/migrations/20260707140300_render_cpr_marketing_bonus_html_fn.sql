-- Render marketing bonus section for the weekly CPR email
CREATE OR REPLACE FUNCTION public.render_cpr_marketing_bonus_html(
  p_agency_id UUID,
  p_week_ending_date DATE
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_pool           JSONB;
  v_envelope_ann   NUMERIC;
  v_envelope_ytd   NUMERIC;
  v_spend_ytd      NUMERIC;
  v_pool_ytd       NUMERIC;
  v_total_points   NUMERIC;
  v_underspend_ytd NUMERIC;
  v_rows           TEXT := '';
  v_html           TEXT := '';
  v_pool_state_color TEXT;
  v_pool_state_msg   TEXT;
BEGIN
  v_pool := public.compute_weekly_marketing_bonus(p_agency_id, p_week_ending_date);

  v_envelope_ann   := COALESCE((v_pool->'envelope'->>'annual')::numeric, 0);
  v_envelope_ytd   := COALESCE((v_pool->'envelope'->>'ytd_target')::numeric, 0);
  v_spend_ytd      := COALESCE((v_pool->'spend'->>'ytd')::numeric, 0);
  v_underspend_ytd := COALESCE((v_pool->'pool'->>'underspend_ytd')::numeric, 0);
  v_pool_ytd       := COALESCE((v_pool->'pool'->>'pool_ytd')::numeric, 0);
  v_total_points   := COALESCE((v_pool->'pool'->>'total_points_ytd')::numeric, 0);

  IF v_pool_ytd > 0 THEN
    v_pool_state_color := '#15803d';
    v_pool_state_msg := 'Pool YTD: ' || public.cpr_fmt_money(v_pool_ytd);
  ELSE
    v_pool_state_color := '#b91c1c';
    v_pool_state_msg := 'Pool YTD: $0 (over envelope by ' || public.cpr_fmt_money(v_spend_ytd - v_envelope_ytd) || ')';
  END IF;

  SELECT string_agg(
    '<tr>'
    || '<td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;font-weight:600;color:#1e293b">'
       || COALESCE(NULLIF(t.nickname, ''), t.first_name) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'
       || to_char(COALESCE((elem->>'points_ytd')::numeric, 0), 'FM999,999') || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'
       || to_char(COALESCE((elem->>'share_pct')::numeric, 0), 'FM990.00') || '%</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'
       || public.cpr_fmt_money(COALESCE((elem->>'earned_ytd')::numeric, 0)) || '</td>'
    || '</tr>',
    '' ORDER BY t.hire_date, t.last_name
  )
  INTO v_rows
  FROM jsonb_array_elements(v_pool->'people') elem
  JOIN public.team t ON t.id = (elem->>'team_member_id')::uuid;

  v_html :=
       '<div style="margin:14px 0">'
    || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px;margin-bottom:8px">📢 MARKETING BONUS POOL '
       || '<span style="font-weight:400;color:' || v_pool_state_color || ';font-size:12px">'
       || v_pool_state_msg || '</span></div>'
    || '<div style="font-size:12px;color:#64748b;margin-bottom:8px">'
       || 'Envelope: ' || public.cpr_fmt_money(v_envelope_ann, 0) || '/yr  •  '
       || 'YTD target: ' || public.cpr_fmt_money(v_envelope_ytd) || '  •  '
       || 'YTD spent: ' || public.cpr_fmt_money(v_spend_ytd) || '  •  '
       || 'Team points: ' || to_char(v_total_points, 'FM999,999')
       || '</div>';

  IF v_rows IS NOT NULL AND v_rows <> '' THEN
    v_html := v_html
      || '<table style="width:100%;border-collapse:collapse;font-size:12px"><thead><tr>'
      || '<th style="padding:6px 10px;text-align:left;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Team Member</th>'
      || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Points YTD</th>'
      || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Share</th>'
      || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Earned YTD</th>'
      || '</tr></thead><tbody>' || v_rows || '</tbody></table>';
  ELSE
    v_html := v_html
      || '<div style="font-size:12px;color:#94a3b8;font-style:italic;padding:8px">No marketing points logged yet this year.</div>';
  END IF;

  v_html := v_html || '</div>';
  RETURN v_html;
END;
$$;

GRANT EXECUTE ON FUNCTION public.render_cpr_marketing_bonus_html(UUID, DATE) TO anon, authenticated;
