-- Migration: cpr_email_agency_performance_override_aware
-- Applied: 2026-07-06 21:41 UTC via Supabase apply_migration
-- Purpose: Make compose_weekly_cpr_html Section 10 (Agency Performance) override-aware.
--
-- Prior behavior: Section 10 read only from public.agency_snapshot; the 8 manual
-- override columns on weekly_cpr_reports (auto_new_ytd_manual, auto_lost_ytd_manual,
-- fire_new_ytd_manual, fire_lost_ytd_manual, life_new_ytd_manual,
-- life_lost_ytd_manual, life_paid_for_count_ytd_manual,
-- life_paid_for_premium_ytd_manual) were ignored by the composer even though the
-- CPR page rendered them correctly. Op-rule "CPR Agency Performance manual override
-- columns" was misleading — override-awareness had only been implemented for
-- Section 11 (SMVC/Scorecard) via render_cpr_section_11_html.
--
-- New behavior:
-- 1. Snapshot query no longer filters on `AND auto_new_ytd IS NOT NULL` so the
--    section can still render on override-only weeks (no snapshot data).
-- 2. Render gate is now: v_snap.id IS NOT NULL OR any manual override IS NOT NULL.
-- 3. Each of the 5 rendered rows uses COALESCE(v_report.<metric>_manual,
--    v_snap.<metric>, 0) so overrides win when populated and fall back to
--    snapshot values otherwise.

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
  SELECT * INTO v_report
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_ending_date;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No weekly_cpr_reports row for agency=% week=%', p_agency_id, p_week_ending_date;
  END IF;

  v_week_start := p_week_ending_date - 6;
  v_cpr_url := 'https://storybccdashboard.vercel.app/cpr/' || to_char(p_week_ending_date, 'YYYY-MM-DD');

  SELECT count(*) INTO v_team_size
  FROM public.team t
  WHERE t.agency_id = p_agency_id AND t.category = 'agency'
    AND COALESCE(t.role_level, '') <> 'Owner'
    AND t.is_admin_backoffice = false
    AND (t.archived_at IS NULL OR t.archived_at > v_week_start::timestamptz);

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

  -- (Full function body continues; see prior version at commit 25f0adc7 for
  -- unchanged sections. The critical CHANGE is the Agency Performance block
  -- reproduced below in full.)

  -- ====== FIX 2026-07-06 ======
  SELECT * INTO v_snap FROM public.agency_snapshot
  WHERE agency_id = p_agency_id AND snapshot_date <= p_week_ending_date
  ORDER BY snapshot_date DESC LIMIT 1;
  v_days_elapsed := GREATEST(1, (p_week_ending_date - make_date(EXTRACT(YEAR FROM p_week_ending_date)::int, 1, 1))::int + 1);

  IF v_snap.id IS NOT NULL
     OR v_report.auto_new_ytd_manual  IS NOT NULL OR v_report.auto_lost_ytd_manual  IS NOT NULL
     OR v_report.fire_new_ytd_manual  IS NOT NULL OR v_report.fire_lost_ytd_manual  IS NOT NULL
     OR v_report.life_new_ytd_manual  IS NOT NULL OR v_report.life_lost_ytd_manual  IS NOT NULL
     OR v_report.life_paid_for_count_ytd_manual   IS NOT NULL
     OR v_report.life_paid_for_premium_ytd_manual IS NOT NULL
  THEN
    WITH lines AS (
      SELECT 1 AS ord, 'Auto Gain' AS label,
             (COALESCE(v_report.auto_new_ytd_manual,  v_snap.auto_new_ytd,  0)
              - COALESCE(v_report.auto_lost_ytd_manual, v_snap.auto_lost_ytd, 0))::numeric AS ytd,
             (SELECT target_value FROM public.book_performance_goals WHERE agency_id = p_agency_id AND lob = 'auto' AND metric = 'gain' AND year = EXTRACT(YEAR FROM p_week_ending_date)::int LIMIT 1) AS goal,
             false AS is_money
      UNION ALL SELECT 2, 'Fire Gain',
             (COALESCE(v_report.fire_new_ytd_manual,  v_snap.fire_new_ytd,  0)
              - COALESCE(v_report.fire_lost_ytd_manual, v_snap.fire_lost_ytd, 0))::numeric,
             (SELECT target_value FROM public.book_performance_goals WHERE agency_id = p_agency_id AND lob = 'fire' AND metric = 'gain' AND year = EXTRACT(YEAR FROM p_week_ending_date)::int LIMIT 1), false
      UNION ALL SELECT 3, 'Life Gain',
             (COALESCE(v_report.life_new_ytd_manual,  v_snap.life_new_ytd,  0)
              - COALESCE(v_report.life_lost_ytd_manual, v_snap.life_lost_ytd, 0))::numeric,
             (SELECT target_value FROM public.book_performance_goals WHERE agency_id = p_agency_id AND lob = 'life' AND metric = 'gain' AND year = EXTRACT(YEAR FROM p_week_ending_date)::int LIMIT 1), false
      UNION ALL SELECT 4, 'Life Paid #',
             COALESCE(v_report.life_paid_for_count_ytd_manual, v_snap.life_paid_for_count_ytd, 0)::numeric,
             (SELECT target_value FROM public.book_performance_goals WHERE agency_id = p_agency_id AND lob = 'life' AND metric = 'net_paid_for' AND year = EXTRACT(YEAR FROM p_week_ending_date)::int LIMIT 1), false
      UNION ALL SELECT 5, 'Life Premium',
             COALESCE(v_report.life_paid_for_premium_ytd_manual::numeric, v_snap.life_paid_for_premium_ytd, 0),
             (SELECT target_value FROM public.book_performance_goals WHERE agency_id = p_agency_id AND lob = 'life' AND metric = 'premium' AND year = EXTRACT(YEAR FROM p_week_ending_date)::int LIMIT 1), true
    )
    SELECT string_agg(
      '<tr><td>' || label || '</td><td>' || CASE WHEN is_money THEN '$' || to_char(ytd, 'FM999,999,999') ELSE to_char(ytd, 'FM999,999') END || '</td><td>' || CASE WHEN is_money THEN '$' || to_char(ROUND(ytd * 365.0 / v_days_elapsed), 'FM999,999,999') ELSE to_char(ROUND(ytd * 365.0 / v_days_elapsed), 'FM999,999') END || '</td></tr>',
      '' ORDER BY ord) INTO v_perf_rows FROM lines;
  END IF;

  -- (HTML assembly and remaining sections unchanged; see Supabase pg_get_functiondef
  -- output for the authoritative complete definition.)

  RETURN v_html;  -- placeholder for mirror; complete rendering logic in DB
END;
$function$;

-- Note: This mirror file captures the CHANGED section (Agency Performance override
-- awareness) authoritatively. Unchanged sections (~500 lines of HTML assembly)
-- are elided for readability; see Supabase pg_get_functiondef for full body.
