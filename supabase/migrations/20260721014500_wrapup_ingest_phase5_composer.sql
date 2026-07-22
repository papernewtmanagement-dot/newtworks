-- =========================================================================
-- Wrapup ingest — phase 5 (2026-07-21)
-- compose_weekly_cpr_html: inject Team Wrap-ups section between opener
-- and WEEKLY PAY. One row per rostered teammate for the week; shows their
-- coverage badge (Complete / Partial / Not submitted) plus a 250-char
-- preview of the organized wrapup_text. Full detail on the CPR page.
-- =========================================================================

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
  v_mvp_html        text := '';
  v_mvp_name        text;
  v_mvp_sp          numeric;
  v_mvp_draws       int;
  v_draws_label     text;
  v_crossings_html  text := '';
  v_all_star_rows   text := '';
  v_trailblazer_rows text := '';
  v_payroll_html    text := '';
  v_wrapup_html     text := '';
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
    v_wtw_html := '<div style="padding:12px 16px;background:#dcfce7;border-radius:6px;margin:0 0 20px;color:#166534;font-weight:700;font-size:15px">🏆 WIN THE WEEK — ✓ Team hit both goals</div>';

    SELECT COALESCE(NULLIF(t.nickname,''), t.first_name), mh.sales_points_earned, mh.prize_draws
    INTO v_mvp_name, v_mvp_sp, v_mvp_draws
    FROM public.mvp_history mh
    JOIN public.team t ON t.id = mh.team_member_id
    WHERE mh.agency_id = p_agency_id AND mh.week_ending_date = p_week_ending_date
    LIMIT 1;

    IF v_mvp_name IS NOT NULL THEN
      v_draws_label := v_mvp_draws::text || ' prize draw' || CASE WHEN v_mvp_draws = 1 THEN '' ELSE 's' END;
      v_mvp_html :=
        '<div style="padding:14px 18px;background:linear-gradient(90deg,#dcfce7 0%,#bbf7d0 100%);border:2px solid #16a34a;border-radius:10px;margin:0 0 20px;display:flex;flex-direction:column;gap:4px">' ||
          '<div style="font-size:11px;font-weight:700;color:#166534;text-transform:uppercase;letter-spacing:0.5px">🏆 This Week''s MVP</div>' ||
          '<div style="font-size:20px;font-weight:800;color:#14532d">' || v_mvp_name || '</div>' ||
          '<div style="font-size:13px;color:#166534">' || round(v_mvp_sp)::text || ' SP earned · ' || v_draws_label || '</div>' ||
        '</div>';
    END IF;
  ELSE
    v_quote_short := GREATEST(0, v_quote_goal - v_team_quotes);
    v_sp_short    := GREATEST(0, v_sp_goal   - v_team_sp);
    v_wtw_html :=
      '<div style="padding:12px 16px;background:#fef2f2;border-radius:6px;margin:0 0 20px;color:#991b1b;font-weight:700;font-size:15px">🏆 WIN THE WEEK — Carryover' ||
      CASE
        WHEN v_quote_short > 0 AND v_sp_short > 0 THEN ' ' || v_quote_short::text || ' quotes / ' || round(v_sp_short)::text || ' pts'
        WHEN v_quote_short > 0                    THEN ' ' || v_quote_short::text || ' quotes'
        WHEN v_sp_short    > 0                    THEN ' ' || round(v_sp_short)::text || ' pts'
        ELSE ''
      END ||
      '</div>';
  END IF;

  SELECT string_agg(row_html, '' ORDER BY sort_order) INTO v_all_star_rows
  FROM (
    SELECT
      CASE ac.category
        WHEN 'quarter_sp'   THEN 1
        WHEN 'four_week_sp' THEN 2
        WHEN 'week_sp'      THEN 3
        WHEN 'week_quotes'  THEN 4
        ELSE 9
      END AS sort_order,
      '<div style="padding:4px 0;font-size:13px;color:#334155">' ||
        '<span style="font-weight:700;color:#1e293b">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</span> — ' ||
        CASE ac.category
          WHEN 'week_quotes' THEN round(ac.value_at_crossing)::text || ' Weekly Quotes (floor ' || round(ac.floor_at_crossing)::text || ')'
          WHEN 'week_sp'      THEN '$' || to_char(ac.value_at_crossing, 'FM999,999,990') || ' Weekly Sales (floor $' || to_char(ac.floor_at_crossing, 'FM999,999,990') || ')'
          WHEN 'four_week_sp' THEN '$' || to_char(ac.value_at_crossing, 'FM999,999,990') || ' 4-Week Sales (floor $' || to_char(ac.floor_at_crossing, 'FM999,999,990') || ')'
          WHEN 'quarter_sp'   THEN '$' || to_char(ac.value_at_crossing, 'FM999,999,990') || ' Quarterly Sales (floor $' || to_char(ac.floor_at_crossing, 'FM999,999,990') || ')'
          ELSE ac.category || ' ' || round(ac.value_at_crossing)::text
        END ||
      '</div>' AS row_html
    FROM public.all_star_crossings ac
    JOIN public.team t ON t.id = ac.team_member_id
    WHERE ac.agency_id = p_agency_id AND ac.week_ending = p_week_ending_date
  ) rows;

  SELECT string_agg(row_html, '' ORDER BY sort_order) INTO v_trailblazer_rows
  FROM (
    SELECT
      CASE tc.category
        WHEN 'quarter_sp'   THEN 1
        WHEN 'four_week_sp' THEN 2
        WHEN 'week_sp'      THEN 3
        WHEN 'week_quotes'  THEN 4
        ELSE 9
      END AS sort_order,
      '<div style="padding:4px 0;font-size:13px;color:#334155">' ||
        '<span style="font-weight:700;color:#1e293b">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</span> — ' ||
        CASE tc.category
          WHEN 'week_quotes' THEN round(tc.value_at_crossing)::text || ' Weekly Quotes (record ' || round(tc.floor_at_crossing)::text || ')'
          WHEN 'week_sp'      THEN '$' || to_char(tc.value_at_crossing, 'FM999,999,990') || ' Weekly Sales (record $' || to_char(tc.floor_at_crossing, 'FM999,999,990') || ')'
          WHEN 'four_week_sp' THEN '$' || to_char(tc.value_at_crossing, 'FM999,999,990') || ' 4-Week Sales (record $' || to_char(tc.floor_at_crossing, 'FM999,999,990') || ')'
          WHEN 'quarter_sp'   THEN '$' || to_char(tc.value_at_crossing, 'FM999,999,990') || ' Quarterly Sales (record $' || to_char(tc.floor_at_crossing, 'FM999,999,990') || ')'
          ELSE tc.category || ' ' || round(tc.value_at_crossing)::text
        END ||
      '</div>' AS row_html
    FROM public.trailblazer_crossings tc
    JOIN public.team t ON t.id = tc.team_member_id
    WHERE tc.agency_id = p_agency_id AND tc.week_ending = p_week_ending_date
  ) rows;

  IF v_all_star_rows IS NOT NULL OR v_trailblazer_rows IS NOT NULL THEN
    v_crossings_html := '<div style="padding:14px 18px;background:#fefce8;border:1px solid #fde68a;border-radius:8px;margin:0 0 20px">';
    IF v_all_star_rows IS NOT NULL THEN
      v_crossings_html := v_crossings_html ||
        '<div style="font-size:11px;font-weight:700;color:#854d0e;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:4px">⭐ All-Star Crossings</div>' ||
        v_all_star_rows;
    END IF;
    IF v_trailblazer_rows IS NOT NULL THEN
      v_crossings_html := v_crossings_html ||
        '<div style="font-size:11px;font-weight:700;color:#7c2d12;text-transform:uppercase;letter-spacing:0.5px;margin:8px 0 4px">🔥 Trailblazer Crossings</div>' ||
        v_trailblazer_rows;
    END IF;
    v_crossings_html := v_crossings_html || '</div>';
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
             + COALESCE(d.goals_bonus,0)
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

  -- Team wrap-ups block (2026-07-21). Per rostered teammate: name +
  -- coverage badge (Complete / Partial / Not submitted) + first ~350 chars
  -- of the organized wrapup_text. Full detail on the CPR page.
  SELECT string_agg(row_html, '' ORDER BY start_date, first_name)
  INTO v_wrapup_html
  FROM (
    SELECT
      t.start_date,
      COALESCE(NULLIF(t.nickname,''), t.first_name) AS first_name,
      '<div style="border-bottom:1px solid #e2e8f0;padding:10px 12px">' ||
        '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:4px">' ||
          '<span style="font-weight:700;color:#1e293b;font-size:14px">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</span>' ||
          CASE
            WHEN d.wrapup_done = true THEN
              '<span style="background:#dcfce7;color:#166534;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:700">✓ COMPLETE</span>'
            WHEN d.wrapup_text IS NOT NULL AND LENGTH(d.wrapup_text) > 20 THEN
              '<span style="background:#fef3c7;color:#92400e;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:700">PARTIAL</span>'
            ELSE
              '<span style="background:#fee2e2;color:#991b1b;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:700">NOT SUBMITTED</span>'
          END ||
        '</div>' ||
        CASE
          WHEN d.wrapup_text IS NOT NULL AND LENGTH(d.wrapup_text) > 0 THEN
            '<div style="font-size:13px;color:#475569;line-height:1.5;white-space:pre-wrap">' ||
              replace(
                replace(
                  replace(
                    LEFT(d.wrapup_text, 350) || CASE WHEN LENGTH(d.wrapup_text) > 350 THEN '…' ELSE '' END,
                    '<', '&lt;'
                  ),
                  '>', '&gt;'
                ),
                E'\n', '<br>'
              ) ||
            '</div>'
          ELSE ''
        END ||
      '</div>' AS row_html
    FROM public.weekly_cpr_team_detail d
    JOIN public.team t ON t.id = d.team_member_id
    WHERE d.weekly_cpr_report_id = v_report.id
      AND t.category = 'agency'
      AND t.is_active = true
      AND (t.archived_at IS NULL OR t.archived_at > v_week_start::timestamptz)
      AND NOT COALESCE(t.is_admin_backoffice, false)
      AND COALESCE(t.role_level,'') != 'Owner'
  ) wrapup_rows;

  IF v_wrapup_html IS NOT NULL AND LENGTH(v_wrapup_html) > 0 THEN
    v_wrapup_html :=
      '<h3 style="margin:24px 0 8px;font-size:16px;color:#1e293b">📝 TEAM WRAP-UPS</h3>' ||
      '<div style="background:#f8fafc;border-radius:6px;overflow:hidden">' ||
        v_wrapup_html ||
      '</div>';
  ELSE
    v_wrapup_html := '';
  END IF;

  -- Assembly. Wrap-ups sit between the opener and WEEKLY PAY (2026-07-21):
  -- Peter's voice → team voice → pay → view button → lookahead.
  v_html :=
    '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Oxygen,Ubuntu,sans-serif;max-width:600px;margin:0 auto;padding:20px;color:#1e293b">' ||
      '<h2 style="margin:0 0 20px;font-size:20px;color:#1e293b">📊 CPR RECAP — WEEK OF ' || v_subject_range || '</h2>' ||
      v_wtw_html ||
      v_mvp_html ||
      v_crossings_html ||
      '<div style="color:#b91c1c;font-size:15px;line-height:1.6;margin-bottom:6px">' || v_opener_html || '</div>' ||
      v_wrapup_html ||
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
