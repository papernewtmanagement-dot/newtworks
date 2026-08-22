
CREATE OR REPLACE FUNCTION public.render_cpr_eur_html(p_report public.weekly_cpr_reports)
RETURNS text LANGUAGE sql STABLE
AS $$
  SELECT CASE
    WHEN p_report.eur IS NULL OR btrim(p_report.eur) = '' THEN ''
    ELSE
         '<div style="margin:14px 0">'
      || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px;margin-bottom:6px">🧾 EUR</div>'
      || '<div style="font-size:11px;color:#64748b;margin-bottom:6px">Underwriting Reports — customers with 3+ UW reports run on a single LOB this week.</div>'
      || '<div style="font-size:13px;color:#1e293b;line-height:1.5;padding:10px 12px;background:#f8fafc;border-radius:6px;border:1px solid #e2e8f0">'
      ||   replace(replace(replace(p_report.eur, '<', '&lt;'), '>', '&gt;'), E'\n', '<br>')
      || '</div></div>'
  END;
$$;

CREATE OR REPLACE FUNCTION public.render_cpr_campaigns_html(p_report public.weekly_cpr_reports)
RETURNS text LANGUAGE sql STABLE
AS $$
  SELECT
       '<div style="font-size:13px;color:#1e293b;margin:8px 0">'
    || '<strong style="color:#0f172a">📋 CAMPAIGNS</strong> &nbsp;&nbsp; '
    || 'Defectors '       || COALESCE(to_char(p_report.campaign_defectors_date,   'FMMM/FMDD'), '—')
    || '  •  Single-Line '|| COALESCE(to_char(p_report.campaign_single_line_date, 'FMMM/FMDD'), '—')
    || '  •  A/F Renewals '|| COALESCE(to_char(p_report.campaign_af_renewals_date,'FMMM/FMDD'), '—')
    || '  •  Onboarding ' || COALESCE(to_char(p_report.campaign_onboarding_date,  'FMMM/FMDD'), '—')
    || '</div>';
$$;

CREATE OR REPLACE FUNCTION public.render_cpr_prize_cart_html(
  p_agency_id uuid, p_week_ending_date date
) RETURNS text LANGUAGE plpgsql STABLE
AS $$
DECLARE
  v_quarter_end date;
  v_rows text;
BEGIN
  SELECT cycle_end INTO v_quarter_end
  FROM public.current_cycle_info(p_agency_id, p_week_ending_date);

  SELECT string_agg(
    '<tr><td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;color:#1e293b">'
       || CASE WHEN pc.prize_url IS NOT NULL AND pc.prize_url <> ''
               THEN '<a href="' || pc.prize_url || '" style="color:#1e293b;text-decoration:none">' || COALESCE(pc.prize_description,'') || '</a>'
               ELSE COALESCE(pc.prize_description,'') END
       || '</td>'
    || '<td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;color:'
       || CASE WHEN pc.winner_team_member_id IS NOT NULL THEN '#1e293b' ELSE '#94a3b8' END
       || '">'
       || CASE WHEN pc.winner_team_member_id IS NOT NULL
               THEN COALESCE(NULLIF(t.nickname,''), t.first_name, '(unknown)')
               ELSE '—' END
       || '</td></tr>',
    '' ORDER BY pc.display_order, pc.id
  )
  INTO v_rows
  FROM public.prize_cart pc
  LEFT JOIN public.team t ON t.id = pc.winner_team_member_id
  WHERE pc.agency_id = p_agency_id
    AND pc.quarter_ending_date = v_quarter_end;

  IF v_rows IS NULL OR v_rows = '' THEN
    RETURN '';
  END IF;

  RETURN
       '<div style="margin:14px 0">'
    || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px;margin-bottom:8px">🏆 PRIZE CART</div>'
    || '<table style="width:100%;border-collapse:collapse;font-size:12px">'
    || '<thead><tr>'
    || '<th style="padding:6px 10px;text-align:left;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Prize</th>'
    || '<th style="padding:6px 10px;text-align:left;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Winner</th>'
    || '</tr></thead><tbody>' || v_rows || '</tbody></table></div>';
END;
$$;

