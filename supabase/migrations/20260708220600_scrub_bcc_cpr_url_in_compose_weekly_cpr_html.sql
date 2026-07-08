CREATE OR REPLACE FUNCTION public.compose_weekly_cpr_html(p_agency_id uuid, p_week_ending_date date)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_report           public.weekly_cpr_reports;
  v_html             text := '';
  v_week_start       date;
  v_team_size        int;
  v_team_checklist_total int := 11;
  v_team_checklist_hit   int;
  v_team_quote_owe   int;
  v_per_checklist_total  int;
  v_per_checklist_hit    int;
  v_personal_quote_owe   int;
  v_code_reds_count  int;
  v_code_yellows_count int;
  v_code_reds_html   text := '';
  v_code_yellows_html text := '';
  v_requirements_rows text := '';
  v_hours_rows       text := '';
  v_activity_rows    text := '';
  v_activity_summary_rows text := '';
  v_payroll_rows     text := '';
  v_perf_rows        text := '';
  v_cpr_url          text;
  v_snap             record;
  v_days_elapsed     int;
  v_carryover        int;
  v_fresh_needed     int;
  v_quote_goal       int;
  v_sales_pts_goal   numeric;
  v_team_net_quotes  int;
  v_team_sales_pts   numeric;
  v_quotes_pass      boolean;
  v_sp_pass          boolean;
  v_quote_short      int;
  v_sp_short         numeric;
  v_retention_jsonb  jsonb;
  v_retention_annual numeric;
BEGIN
  SELECT * INTO v_report FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_ending_date;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No weekly_cpr_reports row for agency=% week=%', p_agency_id, p_week_ending_date;
  END IF;

  v_week_start := p_week_ending_date - 6;
  v_cpr_url := 'https://newtworks.vercel.app/cpr/' || to_char(p_week_ending_date, 'YYYY-MM-DD');

  SELECT count(*) INTO v_team_size FROM public.get_expected_teammates(p_agency_id, 'compensation', v_week_start) et;

  v_team_checklist_hit :=
      (CASE WHEN v_report.shareds_done       IS TRUE THEN 1 ELSE 0 END) +
      (CASE WHEN v_report.texts_done         IS TRUE THEN 1 ELSE 0 END) +
      (CASE WHEN v_report.deposits_done      IS TRUE THEN 1 ELSE 0 END) +
      (CASE WHEN v_report.appts_done         IS TRUE THEN 1 ELSE 0 END) +
      (CASE WHEN v_report.tasks_done         IS TRUE THEN 1 ELSE 0 END) +
      (CASE WHEN v_report.cases_done         IS TRUE THEN 1 ELSE 0 END) +
      (CASE WHEN v_report.no_onboarding_done IS TRUE THEN 1 ELSE 0 END) +
      (CASE WHEN v_report.no_fu_task_done    IS TRUE THEN 1 ELSE 0 END) +
      (CASE WHEN v_report.new_opps_done      IS TRUE THEN 1 ELSE 0 END) +
      (CASE WHEN v_report.no_phone_done      IS TRUE THEN 1 ELSE 0 END) +
      (CASE WHEN v_report.bad_data_done      IS TRUE THEN 1 ELSE 0 END);
  v_team_quote_owe := (v_team_checklist_total - v_team_checklist_hit) * v_team_size;

  v_per_checklist_total := 3 * v_team_size;
  SELECT COALESCE(SUM(
    (CASE WHEN d.cpr_reply_done IS TRUE THEN 1 ELSE 0 END) +
    (CASE WHEN d.wrapup_done    IS TRUE THEN 1 ELSE 0 END) +
    (CASE WHEN d.inbox_done     IS TRUE THEN 1 ELSE 0 END)
  ), 0) INTO v_per_checklist_hit
  FROM public.weekly_cpr_team_detail d
  WHERE d.weekly_cpr_report_id = v_report.id;
  v_personal_quote_owe := v_per_checklist_total - v_per_checklist_hit;

  SELECT
    count(*) FILTER (WHERE d.code_reds    IS NOT NULL AND btrim(d.code_reds)    <> ''),
    count(*) FILTER (WHERE d.code_yellows IS NOT NULL AND btrim(d.code_yellows) <> '')
  INTO v_code_reds_count, v_code_yellows_count
  FROM public.weekly_cpr_team_detail d
  WHERE d.weekly_cpr_report_id = v_report.id;

  IF v_code_reds_count > 0 THEN
    SELECT string_agg('<li>' || replace(replace(btrim(d.code_reds),'<','&lt;'),'>','&gt;') || '</li>', '')
    INTO v_code_reds_html FROM public.weekly_cpr_team_detail d
    WHERE d.weekly_cpr_report_id = v_report.id AND d.code_reds IS NOT NULL AND btrim(d.code_reds) <> '';
  END IF;
  IF v_code_yellows_count > 0 THEN
    SELECT string_agg('<li>' || replace(replace(btrim(d.code_yellows),'<','&lt;'),'>','&gt;') || '</li>', '')
    INTO v_code_yellows_html FROM public.weekly_cpr_team_detail d
    WHERE d.weekly_cpr_report_id = v_report.id AND d.code_yellows IS NOT NULL AND btrim(d.code_yellows) <> '';
  END IF;

  SELECT string_agg(
    '<tr><td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;font-weight:600;color:#1e293b">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || r.carryover::text || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || r.missed::text    || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || r.modified::text  || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || r.cost::text      || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || r.total::text     || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || r.paid::text      || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155;font-weight:700">' || r.owed::text || '</td></tr>',
    '' ORDER BY t.hire_date, t.last_name
  )
  INTO v_requirements_rows
  FROM public.get_weekly_cpr_requirements(p_agency_id, p_week_ending_date) r
  JOIN public.team t ON t.id = r.team_member_id;

  WITH h_pivot AS (
    SELECT team_member_id,
      MAX(hours)    FILTER (WHERE day_label = 'mon') AS mon_h, MAX(location) FILTER (WHERE day_label = 'mon') AS mon_loc,
      MAX(hours)    FILTER (WHERE day_label = 'tue') AS tue_h, MAX(location) FILTER (WHERE day_label = 'tue') AS tue_loc,
      MAX(hours)    FILTER (WHERE day_label = 'wed') AS wed_h, MAX(location) FILTER (WHERE day_label = 'wed') AS wed_loc,
      MAX(hours)    FILTER (WHERE day_label = 'thu') AS thu_h, MAX(location) FILTER (WHERE day_label = 'thu') AS thu_loc,
      MAX(hours)    FILTER (WHERE day_label = 'fri') AS fri_h, MAX(location) FILTER (WHERE day_label = 'fri') AS fri_loc
    FROM public.get_weekly_cpr_hours(p_agency_id, p_week_ending_date) GROUP BY team_member_id
  )
  SELECT string_agg(
    '<tr><td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;font-weight:600;color:#1e293b">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || CASE WHEN COALESCE(hp.mon_h, 0) = 0 THEN '—' ELSE to_char(hp.mon_h, 'FM999.00') || ' ' || CASE WHEN hp.mon_loc='remote' THEN '🟣' WHEN hp.mon_loc='in_office' THEN '🟢' ELSE '' END END || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || CASE WHEN COALESCE(hp.tue_h, 0) = 0 THEN '—' ELSE to_char(hp.tue_h, 'FM999.00') || ' ' || CASE WHEN hp.tue_loc='remote' THEN '🟣' WHEN hp.tue_loc='in_office' THEN '🟢' ELSE '' END END || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || CASE WHEN COALESCE(hp.wed_h, 0) = 0 THEN '—' ELSE to_char(hp.wed_h, 'FM999.00') || ' ' || CASE WHEN hp.wed_loc='remote' THEN '🟣' WHEN hp.wed_loc='in_office' THEN '🟢' ELSE '' END END || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || CASE WHEN COALESCE(hp.thu_h, 0) = 0 THEN '—' ELSE to_char(hp.thu_h, 'FM999.00') || ' ' || CASE WHEN hp.thu_loc='remote' THEN '🟣' WHEN hp.thu_loc='in_office' THEN '🟢' ELSE '' END END || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || CASE WHEN COALESCE(hp.fri_h, 0) = 0 THEN '—' ELSE to_char(hp.fri_h, 'FM999.00') || ' ' || CASE WHEN hp.fri_loc='remote' THEN '🟣' WHEN hp.fri_loc='in_office' THEN '🟢' ELSE '' END END || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155;font-weight:700">' || to_char((COALESCE(hp.mon_h,0) + COALESCE(hp.tue_h,0) + COALESCE(hp.wed_h,0) + COALESCE(hp.thu_h,0) + COALESCE(hp.fri_h,0)), 'FM999.00') || '</td></tr>',
    '' ORDER BY t.hire_date, t.last_name
  )
  INTO v_hours_rows
  FROM public.get_expected_teammates(p_agency_id, 'compensation', v_week_start) et
  JOIN public.team t ON t.id = et.team_id
  LEFT JOIN h_pivot hp ON hp.team_member_id = t.id;

  SELECT string_agg(
    '<tr><td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;font-weight:600;color:#1e293b">' || COALESCE(NULLIF(t.nickname,''), t.first_name) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || COALESCE(d.quotes_discussed::text, '0') || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || COALESCE(r.net_quotes::text, '0')       || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155;font-weight:700">' || COALESCE(d.sales_points::text, '0') || '</td></tr>',
    '' ORDER BY t.hire_date, t.last_name
  )
  INTO v_activity_rows
  FROM public.get_expected_teammates(p_agency_id, 'compensation', v_week_start) et
  JOIN public.team t ON t.id = et.team_id
  LEFT JOIN public.weekly_cpr_team_detail d
    ON d.team_member_id = t.id AND d.weekly_cpr_report_id = v_report.id
  LEFT JOIN public.get_weekly_cpr_requirements(p_agency_id, p_week_ending_date) r
    ON r.team_member_id = t.id;

  v_carryover := COALESCE(v_report.quotes_owed_carryover, 0);
  v_fresh_needed := COALESCE(v_report.quotes_fresh_needed, 0);
  v_quote_goal := v_carryover + v_fresh_needed;
  v_sales_pts_goal := COALESCE(v_report.quarterly_sales_points_target, 0);
  SELECT COALESCE(SUM(net_quotes), 0)::int INTO v_team_net_quotes
  FROM public.get_weekly_cpr_requirements(p_agency_id, p_week_ending_date);
  v_team_sales_pts := COALESCE(v_report.quarterly_sales_points_qtd, 0);
  v_quotes_pass := v_team_net_quotes >= v_quote_goal;
  v_sp_pass     := v_team_sales_pts >= v_sales_pts_goal;
  v_quote_short := GREATEST(0, v_quote_goal - v_team_net_quotes);
  v_sp_short    := GREATEST(0::numeric, v_sales_pts_goal - v_team_sales_pts);

  v_activity_summary_rows :=
       '<tr style="border-top:2px solid #cbd5e1">'
    || '<td style="padding:6px 10px;font-weight:700;color:#1e293b">Team Total</td>'
    || '<td style="padding:6px 10px;text-align:right;color:#334155"></td>'
    || '<td style="padding:6px 10px;text-align:right;font-weight:700;color:#1e293b">' || to_char(v_team_net_quotes, 'FM999,999') || '</td>'
    || '<td style="padding:6px 10px;text-align:right;font-weight:700;color:#1e293b">' || to_char(v_team_sales_pts, 'FM999,999.00') || '</td></tr>'
    || '<tr><td style="padding:6px 10px;font-weight:700;color:#334155">Goal '
       || '<span style="font-weight:400;color:#64748b;font-size:11px">(' || v_carryover::text || ' carryover)</span></td>'
    || '<td style="padding:6px 10px;text-align:right;color:#334155"></td>'
    || '<td style="padding:6px 10px;text-align:right;font-weight:700;color:#334155">' || v_quote_goal::text || '</td>'
    || '<td style="padding:6px 10px;text-align:right;font-weight:700;color:#334155">' || to_char(v_sales_pts_goal, 'FM999,999.00') || '</td></tr>'
    || '<tr><td colspan="4" style="padding:6px 10px;text-align:center;font-weight:700;color:'
       || CASE WHEN v_quotes_pass AND v_sp_pass THEN '#15803d' ELSE '#b91c1c' END || '">'
       || CASE WHEN v_quotes_pass AND v_sp_pass THEN '✓ Win the Week!'
               ELSE 'Carryover: '
                 || CASE WHEN v_quote_short > 0 THEN v_quote_short::text || ' quote' || CASE WHEN v_quote_short = 1 THEN '' ELSE 's' END ELSE '' END
                 || CASE WHEN v_quote_short > 0 AND v_sp_short > 0 THEN ' / ' ELSE '' END
                 || CASE WHEN v_sp_short > 0 THEN to_char(v_sp_short, 'FM999,999') || ' pts' ELSE '' END END
       || '</td></tr>';

  v_retention_jsonb := public.compute_retention_budget_weekly(p_agency_id, p_week_ending_date);
  v_retention_annual := NULLIF(v_retention_jsonb->>'budget','')::numeric;

  WITH payroll_calc AS (
    SELECT t.id, t.hire_date, t.last_name, t.first_name, t.nickname, t.start_date,
      COALESCE(t.annual_benefits_value, 0)         AS annual_benefits,
      COALESCE(t.annual_benefits_value, 0) / 52.0  AS weekly_benefits,
      COALESCE(d.weekly_pay, 0) AS weekly_pay, COALESCE(d.base_advance, 0) AS base_advance,
      COALESCE(d.health_bonus, 0) AS health_bonus, COALESCE(d.service_surge_share, 0) AS retention,
      COALESCE(d.true_pay_bonus, 0) AS true_pay, COALESCE(d.manager_bonus, 0) AS manager_bonus,
      COALESCE(d.agency_profit_share, 0) AS agency_profit, d.payroll_ytd_paid AS payroll_ytd_paid,
      GREATEST(1, (p_week_ending_date - GREATEST(t.start_date, make_date(EXTRACT(YEAR FROM p_week_ending_date)::int, 1, 1)))::int + 1) AS days_employed_year
    FROM public.get_expected_teammates(p_agency_id, 'compensation', v_week_start) et
    JOIN public.team t ON t.id = et.team_id
    LEFT JOIN public.weekly_cpr_team_detail d ON d.team_member_id = t.id AND d.weekly_cpr_report_id = v_report.id
  ),
  payroll_with_totals AS (
    SELECT *,
      (weekly_pay + base_advance + health_bonus + retention + true_pay + manager_bonus + agency_profit) AS week_excl_benefits,
      (weekly_pay + base_advance + health_bonus + weekly_benefits + retention + true_pay + manager_bonus + agency_profit) AS week_total
    FROM payroll_calc
  ),
  payroll_with_ota AS (
    SELECT *,
      CASE WHEN payroll_ytd_paid IS NULL THEN NULL::numeric
           ELSE (payroll_ytd_paid + week_excl_benefits) * 365.0 / days_employed_year + annual_benefits END AS on_time_annual
    FROM payroll_with_totals
  )
  SELECT string_agg(
    '<tr><td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;font-weight:600;color:#1e293b">' || COALESCE(NULLIF(nickname,''), first_name) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || public.cpr_fmt_money(weekly_pay) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || public.cpr_fmt_money(base_advance) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || public.cpr_fmt_money(health_bonus) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || public.cpr_fmt_money(weekly_benefits) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || public.cpr_fmt_money(retention) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || public.cpr_fmt_money(true_pay) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || public.cpr_fmt_money(manager_bonus) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">' || public.cpr_fmt_money(agency_profit) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#1e293b;font-weight:700">' || public.cpr_fmt_money(week_total) || '</td>'
    || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#1e293b;font-weight:700;background:#eff6ff">' || public.cpr_fmt_money(on_time_annual, 0) || '</td></tr>',
    '' ORDER BY hire_date, last_name
  )
  INTO v_payroll_rows
  FROM payroll_with_ota;

  -- Section 10 (Agency Performance): read agency_snapshot as sole source of truth.
  -- Prefill trigger fills 8 YTD fields from prior weekly row on INSERT; UI writes
  -- directly to agency_snapshot for the current Saturday. No _manual shadow.
  SELECT * INTO v_snap FROM public.agency_snapshot
  WHERE agency_id = p_agency_id
    AND snapshot_date <= p_week_ending_date
    AND cadence = 'weekly'
  ORDER BY snapshot_date DESC LIMIT 1;
  -- Anchored to v_snap.snapshot_date (not p_week_ending_date) so annualization denominator matches numerator freshness. See op-rule "Runtime compute annualization anchor" (2026-06-29, generalized 2026-07-08).
  v_days_elapsed := GREATEST(1, (COALESCE(v_snap.snapshot_date, p_week_ending_date) - make_date(EXTRACT(YEAR FROM COALESCE(v_snap.snapshot_date, p_week_ending_date))::int, 1, 1))::int + 1);

  IF v_snap.id IS NOT NULL THEN
    WITH lines AS (
      SELECT 1 AS ord, 'Auto Gain' AS label,
             (COALESCE(v_snap.auto_new_ytd, 0) - COALESCE(v_snap.auto_lost_ytd, 0))::numeric AS ytd,
             (SELECT target_value FROM public.book_performance_goals WHERE agency_id = p_agency_id AND lob = 'auto' AND metric = 'gain' AND year = EXTRACT(YEAR FROM p_week_ending_date)::int LIMIT 1) AS goal,
             false AS is_money
      UNION ALL SELECT 2, 'Fire Gain',
             (COALESCE(v_snap.fire_new_ytd, 0) - COALESCE(v_snap.fire_lost_ytd, 0))::numeric,
             (SELECT target_value FROM public.book_performance_goals WHERE agency_id = p_agency_id AND lob = 'fire' AND metric = 'gain' AND year = EXTRACT(YEAR FROM p_week_ending_date)::int LIMIT 1), false
      UNION ALL SELECT 3, 'Life Gain',
             (COALESCE(v_snap.life_new_ytd, 0) - COALESCE(v_snap.life_lost_ytd, 0))::numeric,
             (SELECT target_value FROM public.book_performance_goals WHERE agency_id = p_agency_id AND lob = 'life' AND metric = 'gain' AND year = EXTRACT(YEAR FROM p_week_ending_date)::int LIMIT 1), false
      UNION ALL SELECT 4, 'Life Paid #',
             COALESCE(v_snap.life_paid_for_count_ytd, 0)::numeric,
             (SELECT target_value FROM public.book_performance_goals WHERE agency_id = p_agency_id AND lob = 'life' AND metric = 'net_paid_for' AND year = EXTRACT(YEAR FROM p_week_ending_date)::int LIMIT 1), false
      UNION ALL SELECT 5, 'Life Premium',
             COALESCE(v_snap.life_paid_for_premium_ytd, 0)::numeric,
             (SELECT target_value FROM public.book_performance_goals WHERE agency_id = p_agency_id AND lob = 'life' AND metric = 'premium' AND year = EXTRACT(YEAR FROM p_week_ending_date)::int LIMIT 1), true
    )
    SELECT string_agg(
      '<tr><td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;font-weight:600;color:#1e293b">' || label || '</td>'
      || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'
         || CASE WHEN is_money THEN '$' || to_char(ytd, 'FM999,999,999') ELSE to_char(ytd, 'FM999,999') END || '</td>'
      || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155">'
         || CASE WHEN is_money THEN '$' || to_char(ROUND(ytd * 365.0 / v_days_elapsed), 'FM999,999,999') ELSE to_char(ROUND(ytd * 365.0 / v_days_elapsed), 'FM999,999') END || '</td>'
      || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;color:#334155;background:#eff6ff">'
         || CASE WHEN goal IS NULL THEN '—' WHEN is_money THEN '$' || to_char(goal, 'FM999,999,999') ELSE to_char(goal, 'FM999,999') END || '</td>'
      || '<td style="padding:6px 10px;text-align:right;border-bottom:1px solid #e5e7eb;font-weight:700;background:#eff6ff;color:'
         || CASE WHEN goal IS NULL THEN '#64748b' WHEN (ROUND(ytd * 365.0 / v_days_elapsed) - goal) >= 0 THEN '#15803d' ELSE '#b91c1c' END || '">'
         || CASE WHEN goal IS NULL THEN '—'
                 WHEN is_money THEN CASE WHEN (ROUND(ytd * 365.0 / v_days_elapsed) - goal) >= 0 THEN '+$' ELSE '-$' END
                                || to_char(ABS(ROUND(ytd * 365.0 / v_days_elapsed) - goal), 'FM999,999,999')
                 ELSE CASE WHEN (ROUND(ytd * 365.0 / v_days_elapsed) - goal) >= 0 THEN '+' ELSE '' END
                                || to_char(ROUND(ytd * 365.0 / v_days_elapsed) - goal, 'FM999,999') END
         || '</td></tr>',
      '' ORDER BY ord) INTO v_perf_rows FROM lines;
  END IF;

  v_html :=
       '<div style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;color:#0f172a;max-width:760px;margin:0 auto;padding:24px 18px;background:#ffffff">'
    || '<div style="font-size:13px;color:#475569;margin-bottom:18px">Week ending ' || to_char(p_week_ending_date, 'FMDay, FMMonth FMDD, YYYY') || '</div>'
    || '<div style="font-size:15px;line-height:1.55;color:#b91c1c;margin-bottom:18px">'
    ||   COALESCE(replace(replace(replace(v_report.opener_text, '<', '&lt;'), '>', '&gt;'), E'\n', '<br>'), '<em style="color:#94a3b8">(no opener written)</em>')
    || '</div>'
    || '<div style="margin:16px 0 24px"><a href="' || v_cpr_url || '" style="display:inline-block;padding:10px 18px;background:#2563eb;color:#ffffff;border-radius:6px;font-size:13px;font-weight:700;text-decoration:none">📋 View the full CPR report →</a></div>'
    || '<hr style="border:none;border-top:1px solid #e2e8f0;margin:20px 0">'
    || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.6px;margin-bottom:8px">🎯 LOOKING AT NEXT WEEK</div>'
    || '<div style="font-size:14px;line-height:1.55;color:#1e40af;margin-bottom:18px">'
    ||   COALESCE(replace(replace(replace(v_report.looking_next_week_text, '<', '&lt;'), '>', '&gt;'), E'\n', '<br>'), '<em style="color:#94a3b8">(not written)</em>')
    || '</div>'
    || '<hr style="border:none;border-top:1px solid #e2e8f0;margin:20px 0">';

  IF v_code_reds_count = 0 AND v_code_yellows_count = 0 THEN
    v_html := v_html || '<div style="font-size:13px;color:#475569;margin:8px 0">🔴 0 reds  •  🟡 0 yellows</div>';
  ELSE
    IF v_code_reds_count > 0 THEN
      v_html := v_html
        || '<div style="font-size:13px;font-weight:800;color:#dc2626;letter-spacing:0.4px;margin-bottom:6px">🔴 CODE REDS (' || v_code_reds_count || ')</div>'
        || '<ul style="margin:0 0 14px 22px;padding:0;font-size:13px;color:#1e293b">' || v_code_reds_html || '</ul>';
    END IF;
    IF v_code_yellows_count > 0 THEN
      v_html := v_html
        || '<div style="font-size:13px;font-weight:800;color:#d97706;letter-spacing:0.4px;margin-bottom:6px">🟡 CODE YELLOWS (' || v_code_yellows_count || ')</div>'
        || '<ul style="margin:0 0 14px 22px;padding:0;font-size:13px;color:#1e293b">' || v_code_yellows_html || '</ul>';
    END IF;
  END IF;

  v_html := v_html
    || '<div style="margin:18px 0 12px">'
    || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px;margin-bottom:8px">✅ TEAM CHECKLIST &nbsp; <span style="font-weight:400;color:#64748b;font-size:12px">Hit: ' || v_team_checklist_hit || ' of ' || v_team_checklist_total || CASE WHEN v_team_checklist_hit = v_team_checklist_total THEN '  ✓' ELSE '' END || '</span></div>'
    || '<div style="background:#ffffff;border:1px solid #e2e8f0;border-radius:6px;padding:12px 8px">'
    || '<div style="font-size:10px;font-weight:800;color:#64748b;letter-spacing:0.6px;text-transform:uppercase;margin:0 0 6px 4px">Daily Ops</div>'
    || public.render_cpr_team_checklist_grid_html(v_report)
    || '</div>';
  IF v_team_checklist_hit < v_team_checklist_total THEN
    v_html := v_html || '<div style="font-size:12px;color:#475569;margin-top:6px;padding-left:4px">→ ' || v_team_quote_owe || ' extra quotes owed next week  (' || (v_team_checklist_total - v_team_checklist_hit) || ' miss' || CASE WHEN (v_team_checklist_total - v_team_checklist_hit) = 1 THEN '' ELSE 'es' END || ' × ' || v_team_size || '-person team)</div>';
  END IF;
  v_html := v_html || '</div>';

  v_html := v_html
    || '<div style="margin:18px 0 12px">'
    || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px;margin-bottom:8px">🧍 PERSONAL CHECKLIST &nbsp; <span style="font-weight:400;color:#64748b;font-size:12px">Hit: ' || v_per_checklist_hit || ' of ' || v_per_checklist_total || CASE WHEN v_per_checklist_hit = v_per_checklist_total THEN '  ✓' ELSE '' END || '</span></div>'
    || public.render_cpr_personal_checklist_html(p_agency_id, p_week_ending_date);
  IF v_per_checklist_hit < v_per_checklist_total THEN
    v_html := v_html || '<div style="font-size:12px;color:#475569;margin-top:6px;padding-left:4px">→ ' || v_personal_quote_owe || ' extra quotes owed next week  (1 per missed person)</div>';
  END IF;
  v_html := v_html || '</div>';

  v_html := v_html
    || '<div style="margin:18px 0 12px">'
    || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px;margin-bottom:8px">⭐ REQUIREMENTS</div>'
    || '<table style="width:100%;border-collapse:collapse;font-size:12px"><thead><tr>'
    || '<th style="padding:6px 10px;text-align:left;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Team Member</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Last Wk</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">This Wk</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Modified</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Cost</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Total</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Paid</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Next Wk</th>'
    || '</tr></thead><tbody>' || COALESCE(v_requirements_rows, '') || '</tbody></table></div>'
    || '<hr style="border:none;border-top:1px solid #e2e8f0;margin:20px 0">';

  IF v_perf_rows IS NOT NULL AND v_perf_rows <> '' THEN
    v_html := v_html
      || '<div style="margin:14px 0">'
      || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px;margin-bottom:8px">🎯 AGENCY PERFORMANCE</div>'
      || '<table style="width:100%;border-collapse:collapse;font-size:12px"><thead><tr>'
      || '<th style="padding:6px 10px;text-align:left;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Metric</th>'
      || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">YTD</th>'
      || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">On Time</th>'
      || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px;background:#eff6ff">Goal</th>'
      || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px;background:#eff6ff">Diff</th>'
      || '</tr></thead><tbody>' || v_perf_rows || '</tbody></table></div>';
  END IF;

  v_html := v_html || public.render_cpr_section_11_html(p_agency_id, p_week_ending_date);

  v_html := v_html
    || '<div style="font-size:13px;color:#1e293b;margin:8px 0"><strong style="color:#0f172a">🚨 CLAIMS</strong> &nbsp;&nbsp; New: ' || COALESCE(v_report.new_claims, 0)
    || '  •  Unreviewed: ' || COALESCE(v_report.unreviewed_claims, 0)
    || '  •  Open: ' || COALESCE(v_report.open_claims, 0) || '</div>'
    || '<div style="font-size:13px;color:#1e293b;margin:8px 0"><strong style="color:#0f172a">🛑 NON-PAYS</strong> &nbsp;&nbsp; This week: ' || COALESCE(v_report.non_pays, 0) || '</div>';

  v_html := v_html || public.render_cpr_eur_html(v_report);
  v_html := v_html || public.render_cpr_campaigns_html(v_report)
    || '<hr style="border:none;border-top:1px solid #e2e8f0;margin:20px 0">';

  v_html := v_html
    || '<div style="margin:14px 0">'
    || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px;margin-bottom:8px">🕐 HOURS WORKED</div>'
    || '<table style="width:100%;border-collapse:collapse;font-size:12px"><thead><tr>'
    || '<th style="padding:6px 10px;text-align:left;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Team Member</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Mon</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Tue</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Wed</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Thu</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Fri</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Total</th>'
    || '</tr></thead><tbody>' || COALESCE(v_hours_rows, '') || '</tbody></table></div>';

  v_html := v_html
    || '<div style="margin:14px 0">'
    || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px;margin-bottom:8px">📊 TEAM ACTIVITY</div>'
    || '<table style="width:100%;border-collapse:collapse;font-size:12px"><thead><tr>'
    || '<th style="padding:6px 10px;text-align:left;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Team Member</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Quotes</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Net Quotes</th>'
    || '<th style="padding:6px 10px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:10px;letter-spacing:0.4px">Q Sales Pts</th>'
    || '</tr></thead><tbody>' || COALESCE(v_activity_rows, '') || v_activity_summary_rows || '</tbody></table></div>';

  v_html := v_html
    || '<div style="margin:14px 0">'
    || '<div style="font-size:13px;font-weight:800;color:#0f172a;letter-spacing:0.4px;margin-bottom:8px">💰 PAYROLL</div>'
    || '<table style="width:100%;border-collapse:collapse;font-size:11px"><thead><tr>'
    || '<th style="padding:6px 8px;text-align:left;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">Team Member</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">Weekly Pay</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">Base Adv</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">Health</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">Benefits</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">Retention'
       || CASE WHEN v_retention_annual IS NOT NULL
               THEN '<br><span style="font-weight:400;color:#94a3b8;font-size:8px;text-transform:none;letter-spacing:0">(' || public.cpr_fmt_money(v_retention_annual, 0) || ')</span>'
               ELSE '' END
       || '</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">True Pay</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">Mgr</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">Agcy Profit</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px">Week Total</th>'
    || '<th style="padding:6px 8px;text-align:right;border-bottom:1px solid #cbd5e1;color:#64748b;font-weight:700;text-transform:uppercase;font-size:9px;letter-spacing:0.4px;background:#eff6ff">On-Time Annual</th>'
    || '</tr></thead><tbody>' || COALESCE(v_payroll_rows, '') || '</tbody></table></div>';

  v_html := v_html || public.render_cpr_marketing_bonus_html(p_agency_id, p_week_ending_date);

  v_html := v_html || public.render_cpr_prize_cart_html(p_agency_id, p_week_ending_date);

  v_html := v_html || '<div style="font-size:14px;color:#1e293b;margin-top:24px">— Peter</div></div>';
  RETURN v_html;
END;
$function$
