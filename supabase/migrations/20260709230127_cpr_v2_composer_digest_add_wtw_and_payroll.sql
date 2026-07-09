-- CPR v2 email digest — add Win the Week outcome + per-person Weekly Pay snapshot.
-- Both are simple aggregations of the same raw columns the CPR page reads, so drift is bounded.
--
-- Applied via Supabase MCP 2026-07-09; mirrored here for grep-ability + diff visibility.

CREATE OR REPLACE FUNCTION public.compose_weekly_cpr_html(p_agency_id uuid, p_week_ending_date date)
RETURNS text
LANGUAGE plpgsql
AS $function$
DECLARE
  v_report          public.weekly_cpr_reports;
  v_week_start      date;
  v_start_mon       text;
  v_end_mon         text;
  v_start_day       text;
  v_end_day         text;
  v_subject_range   text;
  v_cpr_url         text;
  v_opener_html     text;
  v_lookahead_html  text;
  v_wtw_html        text := '';
  v_payroll_html    text := '';
  v_html            text;
  v_team_quotes     int := 0;
  v_team_sp         numeric := 0;
  v_quote_goal      int := 0;
  v_sp_goal         numeric := 0;
  v_quote_short     int;
  v_sp_short        numeric;
  v_quotes_pass     boolean;
  v_sp_pass         boolean;
BEGIN
  SELECT * INTO v_report
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_ending_date;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No weekly_cpr_reports row for agency=% week=%', p_agency_id, p_week_ending_date;
  END IF;

  v_week_start := p_week_ending_date - 6;
  v_cpr_url := 'https://newtworks.vercel.app/cpr/' || to_char(p_week_ending_date, 'YYYY-MM-DD');

  v_start_mon := upper(to_char(v_week_start,       'Mon'));
  v_end_mon   := upper(to_char(p_week_ending_date, 'Mon'));
  v_start_day := to_char(v_week_start,       'FMDD');
  v_end_day   := to_char(p_week_ending_date, 'FMDD');
  IF v_start_mon = v_end_mon THEN
    v_subject_range := v_start_mon || ' ' || v_start_day || '-' || v_end_day;
  ELSE
    v_subject_range := v_start_mon || ' ' || v_start_day || ' - ' || v_end_mon || ' ' || v_end_day;
  END IF;

  v_opener_html := COALESCE(
    NULLIF(replace(replace(replace(v_report.opener_text, '<', '&lt;'), '>', '&gt;'), E'\n', '<br>'), ''),
    '<em style="color:#94a3b8">Opener not yet drafted.</em>'
  );
  v_lookahead_html := COALESCE(
    NULLIF(replace(replace(replace(v_report.looking_next_week_text, '<', '&lt;'), '>', '&gt;'), E'\n', '<br>'), ''),
    '<em style="color:#94a3b8">Looking ahead not yet drafted.</em>'
  );

  SELECT
    COALESCE(SUM(r.net_quotes), 0)::int,
    COALESCE(SUM(d.sales_points), 0)::numeric
  INTO v_team_quotes, v_team_sp
  FROM public.weekly_cpr_team_detail d
  JOIN public.get_weekly_cpr_requirements(p_agency_id, p_week_ending_date) r
    ON r.team_member_id = d.team_member_id
  WHERE d.weekly_cpr_report_id = v_report.id;

  SELECT COALESCE(quotes_target_total, 0), COALESCE(sp_target, 0)
  INTO v_quote_goal, v_sp_goal
  FROM public.get_win_the_week_state(p_agency_id, p_week_ending_date);

  v_quotes_pass := v_team_quotes >= v_quote_goal;
  v_sp_pass     := v_team_sp     >= v_sp_goal;

  IF v_quotes_pass AND v_sp_pass THEN
    v_wtw_html := '<div style="padding:12px 16px;background:#dcfce7;border-radius:6px;margin:20px 0;color:#166534;font-weight:700;font-size:15px">🏆 WIN THE WEEK — ✓ Team hit both goals</div>';
  ELSE
    v_quote_short := GREATEST(0, v_quote_goal - v_team_quotes);
    v_sp_short    := GREATEST(0, v_sp_goal   - v_team_sp);
    v_wtw_html :=
      '<div style="padding:12px 16px;background:#fef2f2;border-radius:6px;margin:20px 0;color:#991b1b;font-weight:700;font-size:15px">🏆 WIN THE WEEK — Carryover' ||
      CASE
        WHEN v_quote_short > 0 AND v_sp_short > 0 THEN ' ' || v_quote_short::text || ' quotes / ' || round(v_sp_short)::text || ' pts'
        WHEN v_quote_short > 0                    THEN ' ' || v_quote_short::text || ' quotes'
        WHEN v_sp_short    > 0                    THEN ' ' || round(v_sp_short)::text || ' pts'
        ELSE ''
      END ||
      '</div>';
  END IF;

  SELECT string_agg(row_html, '' ORDER BY start_date)
  INTO v_payroll_html
  FROM (
    SELECT
      t.start_date,
      '<tr>' ||
        '<td style="padding:6px 10px;color:#1e293b;font-weight:600;font-size:14px">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</td>' ||
        '<td style="padding:6px 10px;text-align:right;color:#1e293b;font-weight:700;font-size:14px">$' ||
          to_char(
            (COALESCE(d.base_salary,0) + COALESCE(d.commission,0) + COALESCE(d.bonus,0)
             + COALESCE(d.marketing_pool_earned_weekly,0) + COALESCE(d.manager_bonus,0)
             + COALESCE(d.health_bonus,0)
             + COALESCE(t.annual_benefits_value,0)/52.0),
            'FM999,999,990.00'
          ) ||
        '</td>' ||
      '</tr>' AS row_html
    FROM public.weekly_cpr_team_detail d
    JOIN public.team t ON t.id = d.team_member_id
    WHERE d.weekly_cpr_report_id = v_report.id
      AND t.category = 'agency'
      AND t.is_active = true
      AND (t.archived_at IS NULL OR t.archived_at > v_week_start::timestamptz)
      AND NOT COALESCE(t.is_admin_backoffice, false)
      AND COALESCE(t.role_level,'') != 'Owner'
  ) rows;

  v_payroll_html := COALESCE(v_payroll_html, '');

  v_html :=
    '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Oxygen,Ubuntu,sans-serif;max-width:600px;margin:0 auto;padding:20px;color:#1e293b">' ||
      '<h2 style="margin:0 0 20px;font-size:20px;color:#1e293b">📊 CPR RECAP — WEEK OF ' || v_subject_range || '</h2>' ||
      '<div style="color:#b91c1c;font-size:15px;line-height:1.6;margin-bottom:6px">' || v_opener_html || '</div>' ||
      v_wtw_html ||
      '<h3 style="margin:24px 0 8px;font-size:16px;color:#1e293b">💰 WEEKLY PAY</h3>' ||
      '<table style="width:100%;border-collapse:collapse;background:#f8fafc;border-radius:6px;overflow:hidden">' ||
        '<tbody>' || v_payroll_html || '</tbody>' ||
      '</table>' ||
      '<div style="margin:24px 0;text-align:center">' ||
        '<a href="' || v_cpr_url || '" style="display:inline-block;padding:10px 18px;background:#1e40af;color:#ffffff;text-decoration:none;border-radius:6px;font-weight:600">📋 View full CPR report →</a>' ||
      '</div>' ||
      '<h3 style="margin:24px 0 8px;font-size:16px;color:#1e293b">🎯 LOOKING AT NEXT WEEK</h3>' ||
      '<div style="color:#1e40af;font-size:15px;line-height:1.6;margin-bottom:24px">' || v_lookahead_html || '</div>' ||
      '<p style="color:#64748b;font-size:14px;margin:24px 0 0">— Peter</p>' ||
    '</div>';

  RETURN v_html;
END;
$function$;
