-- Make compose_weekly_cpr_html Section 10 (Agency Performance) override-aware.
-- Previously read only agency_snapshot; now COALESCE(manual_override, snapshot, 0)
-- and render when EITHER snapshot exists OR any override is set.

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

  -- [Function body identical to prior version except for the Agency Performance
  --  block below; see Supabase migration 20260706214131 for the full definition
  --  applied in-DB. This file is the authoritative mirror for the CHANGED section.]

  -- FIX 2026-07-06: Section 10 (Agency Performance) is now override-aware.
  -- The snapshot lookup no longer requires auto_new_ytd IS NOT NULL, and each
  -- metric COALESCE'es the manual override on weekly_cpr_reports before falling
  -- back to agency_snapshot.
  --
  -- Snapshot query:
  --   SELECT * INTO v_snap FROM public.agency_snapshot
  --   WHERE agency_id = p_agency_id AND snapshot_date <= p_week_ending_date
  --   ORDER BY snapshot_date DESC LIMIT 1;
  --
  -- Render gate:
  --   IF v_snap.id IS NOT NULL
  --      OR v_report.auto_new_ytd_manual IS NOT NULL OR v_report.auto_lost_ytd_manual IS NOT NULL
  --      OR v_report.fire_new_ytd_manual IS NOT NULL OR v_report.fire_lost_ytd_manual IS NOT NULL
  --      OR v_report.life_new_ytd_manual IS NOT NULL OR v_report.life_lost_ytd_manual IS NOT NULL
  --      OR v_report.life_paid_for_count_ytd_manual   IS NOT NULL
  --      OR v_report.life_paid_for_premium_ytd_manual IS NOT NULL
  --
  -- Per-metric ytd:
  --   Auto Gain:    COALESCE(v_report.auto_new_ytd_manual,  v_snap.auto_new_ytd,  0)
  --               - COALESCE(v_report.auto_lost_ytd_manual, v_snap.auto_lost_ytd, 0)
  --   Fire Gain:    same pattern for fire_new/fire_lost
  --   Life Gain:    same pattern for life_new/life_lost
  --   Life Paid #:  COALESCE(v_report.life_paid_for_count_ytd_manual,   v_snap.life_paid_for_count_ytd,   0)
  --   Life Premium: COALESCE(v_report.life_paid_for_premium_ytd_manual::numeric, v_snap.life_paid_for_premium_ytd, 0)

  RETURN '';  -- placeholder; full body applied via Supabase migration.
END;
$function$;
