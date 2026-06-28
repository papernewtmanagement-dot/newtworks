-- Migration 039: True Pay Bonus formula fix per Peter (2026-06-27)
-- For Retention, the earned pool now also includes prior weeks' weekly_pay (in
-- addition to sales_points + prior HSM). This makes the formula treat each
-- Retention team member's base pay as 'earned' (not as advance against sales),
-- which mirrors how Peter actually computes TPB by hand.
-- Sales formula is unchanged: prior WP is NOT added (their WP is already
-- subtracted against sales-points-driven earnings).
--
-- With this fix on the 6/27 week:
--   Stephanie  TPB = 1,204 + 7,661.52 + 704.10 - 9,491.50 = $78.12
--   Cassandra  TPB = 140 + 6,271.27 + 619.73 - 7,031.96 = -0.96 → $0
--   John       TPB = unchanged ($0)
--   Tommy      TPB = unchanged ($0)

CREATE OR REPLACE FUNCTION public.compute_weekly_pay(p_agency_id uuid, p_week_ending_date date)
 RETURNS TABLE(team_member_id uuid, weekly_pay numeric, base_advance numeric, health_bonus numeric, service_surge_share numeric, true_pay_bonus numeric, manager_bonus numeric, agency_profit_share numeric, diagnostics jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_week_start_date    date := p_week_ending_date - 6;
  v_cycle_start        date;
  v_prior_qtr_end      date;
  v_retention_jsonb    jsonb;
  v_annual_budget      numeric;
  v_weekly_budget      numeric;
  v_scorecard          jsonb;
  v_scorecard_annual   numeric;
  v_team_total_sp      numeric;
  v_required_count_avg numeric;
  v_weeks_elapsed      int;
  v_manager_baseline   numeric;
BEGIN
  SELECT cci.cycle_start INTO v_cycle_start
  FROM public.current_cycle_info(p_agency_id, p_week_ending_date) cci;
  v_prior_qtr_end := v_cycle_start - 1;

  v_weeks_elapsed := GREATEST(1, FLOOR((p_week_ending_date - v_cycle_start)::numeric / 7.0)::int + 1);

  v_retention_jsonb := public.compute_retention_budget_weekly(p_agency_id, p_week_ending_date);
  v_annual_budget   := NULLIF(v_retention_jsonb->>'budget','')::numeric;
  v_weekly_budget   := v_annual_budget / 52.0;
  v_scorecard       := public.compute_scorecard_bonus(p_agency_id, p_week_ending_date);
  v_scorecard_annual := NULLIF(v_scorecard->>'bonus_projected','')::numeric;

  SELECT COALESCE(SUM(wctd.sales_points), 0) INTO v_team_total_sp
    FROM public.weekly_cpr_team_detail wctd
    JOIN public.weekly_cpr_reports     r ON r.id = wctd.weekly_cpr_report_id
    JOIN public.team                   t ON t.id = wctd.team_member_id
   WHERE r.agency_id = p_agency_id
     AND r.week_ending_date = p_week_ending_date
     AND t.category = 'agency'
     AND COALESCE(t.role_level,'') <> 'Owner';

  SELECT AVG(required_sales_members_count)::numeric INTO v_required_count_avg
    FROM public.weekly_cpr_reports
   WHERE agency_id = p_agency_id
     AND week_ending_date >= v_cycle_start
     AND week_ending_date <= p_week_ending_date
     AND required_sales_members_count IS NOT NULL;

  v_manager_baseline := CASE WHEN COALESCE(v_required_count_avg, 0) > 0
    THEN v_team_total_sp / v_required_count_avg / v_weeks_elapsed::numeric
    ELSE 0
  END;

  RETURN QUERY
  WITH base AS (
    SELECT wctd.team_member_id,
      COALESCE(wctd.sales_points,0) AS this_week_qtd_sp,
      wctd.payroll_ytd_paid AS this_week_payroll_ytd,
      COALESCE((
        SELECT SUM(COALESCE(prior.health_bonus,0)
                 + COALESCE(prior.service_surge_share,0)
                 + COALESCE(prior.manager_bonus,0))
        FROM public.weekly_cpr_team_detail prior
        JOIN public.weekly_cpr_reports     prior_r ON prior_r.id = prior.weekly_cpr_report_id
        WHERE prior_r.agency_id = p_agency_id
          AND prior_r.week_ending_date >= v_cycle_start
          AND prior_r.week_ending_date <  p_week_ending_date
          AND prior.team_member_id = wctd.team_member_id
      ), 0) AS hsm_prior_total,
      -- NEW: prior weeks' weekly_pay, used in the Retention TPB earned pool
      COALESCE((
        SELECT SUM(COALESCE(prior.weekly_pay,0))
        FROM public.weekly_cpr_team_detail prior
        JOIN public.weekly_cpr_reports     prior_r ON prior_r.id = prior.weekly_cpr_report_id
        WHERE prior_r.agency_id = p_agency_id
          AND prior_r.week_ending_date >= v_cycle_start
          AND prior_r.week_ending_date <  p_week_ending_date
          AND prior.team_member_id = wctd.team_member_id
      ), 0) AS prior_wp_total,
      (SELECT anchor_d.payroll_ytd_paid
         FROM public.weekly_cpr_team_detail anchor_d
         JOIN public.weekly_cpr_reports     anchor_r ON anchor_r.id = anchor_d.weekly_cpr_report_id
        WHERE anchor_r.agency_id = p_agency_id
          AND anchor_r.week_ending_date = v_prior_qtr_end
          AND anchor_d.team_member_id = wctd.team_member_id) AS prior_qtr_end_payroll_ytd,
      t.role, t.role_level, t.role_category, t.category, t.pay_type, t.pay_rate, t.work_location, t.start_date,
      t.license_pc, t.license_lh, t.license_ips,
      CASE WHEN t.role='Reception' THEN COALESCE((
          SELECT SUM(EXTRACT(EPOCH FROM (tce.clock_out_at-tce.clock_in_at))/3600.0)
          FROM public.time_clock_entries tce
          WHERE tce.agency_id=p_agency_id AND tce.team_member_id=t.id
            AND tce.clock_in_at >= (v_week_start_date::timestamp AT TIME ZONE 'America/Chicago')
            AND tce.clock_in_at <  ((p_week_ending_date+1)::timestamp AT TIME ZONE 'America/Chicago')
            AND tce.clock_out_at IS NOT NULL), 0) ELSE NULL END                       AS reception_hours,
      COALESCE((SELECT SUM(CASE WHEN tor.partial_day IN ('morning','afternoon') THEN 4 ELSE 8 END
          * (SELECT COUNT(*)::int FROM generate_series(GREATEST(tor.start_date,v_week_start_date),
               LEAST(tor.end_date,p_week_ending_date), '1 day'::interval) d
             WHERE EXTRACT(DOW FROM d) BETWEEN 1 AND 5))
        FROM public.time_off_requests tor
        WHERE tor.agency_id=p_agency_id AND tor.requester_team_id=t.id AND tor.status='approved'
          AND tor.start_date<=p_week_ending_date AND tor.end_date>=v_week_start_date AND tor.is_paid=true),0) AS paid_off_hours,
      COALESCE((SELECT SUM(CASE WHEN tor.partial_day IN ('morning','afternoon') THEN 4 ELSE 8 END
          * (SELECT COUNT(*)::int FROM generate_series(GREATEST(tor.start_date,v_week_start_date),
               LEAST(tor.end_date,p_week_ending_date), '1 day'::interval) d
             WHERE EXTRACT(DOW FROM d) BETWEEN 1 AND 5))
        FROM public.time_off_requests tor
        WHERE tor.agency_id=p_agency_id AND tor.requester_team_id=t.id AND tor.status='approved'
          AND tor.start_date<=p_week_ending_date AND tor.end_date>=v_week_start_date AND tor.is_paid=false),0) AS unpaid_off_hours,
      GREATEST(
        COALESCE((SELECT COUNT(*)::int FROM public.team_health_checkins thc
          WHERE thc.agency_id=p_agency_id AND thc.team_id=t.id
            AND thc.log_date BETWEEN v_week_start_date AND p_week_ending_date
            AND thc.hit_today=true),0),
        COALESCE((SELECT MAX(thc.week_total_override)::int FROM public.team_health_checkins thc
          WHERE thc.agency_id=p_agency_id AND thc.team_id=t.id
            AND thc.log_date BETWEEN v_week_start_date AND p_week_ending_date
            AND thc.week_total_override IS NOT NULL),0)
      ) AS week_health_days,
      COALESCE((SELECT wctd_last.sales_points FROM public.weekly_cpr_team_detail wctd_last
        JOIN public.weekly_cpr_reports r_last ON r_last.id=wctd_last.weekly_cpr_report_id
        WHERE r_last.agency_id=p_agency_id AND r_last.week_ending_date=p_week_ending_date-7
          AND wctd_last.team_member_id=t.id),0) AS last_week_qtd_sp
    FROM public.weekly_cpr_team_detail wctd
    JOIN public.weekly_cpr_reports     r ON r.id=wctd.weekly_cpr_report_id
    JOIN public.team                   t ON t.id=wctd.team_member_id
    WHERE r.agency_id=p_agency_id AND r.week_ending_date=p_week_ending_date),
  hours AS (SELECT b.*,
      CASE WHEN b.role='Reception' THEN ROUND(b.reception_hours, 2)
           ELSE ROUND(GREATEST(0, 40.0 - b.paid_off_hours - b.unpaid_off_hours), 2) END AS hours_for_surge,
      ROUND(b.reception_hours, 2) AS hourly_hours,
      GREATEST(0,(40.0-b.unpaid_off_hours)/40.0) AS salaried_paid_fraction FROM base b),
  weighted AS (SELECT h.*,
      CASE WHEN h.role='Reception' THEN 1.00 WHEN h.role IN ('Acquisition','Inside Sales') THEN 0.25 ELSE 0 END AS role_w,
      CASE WHEN h.work_location='in_office' THEN 1.00 WHEN h.work_location='remote' THEN 0.85 ELSE 1.00 END AS location_w,
      LEAST(1.00,GREATEST(0,FLOOR((p_week_ending_date-h.start_date)::numeric/7.0)/52.0)) AS tenure_w,
      LEAST(1.00,0.50 + CASE WHEN h.license_pc THEN 0.35 ELSE 0 END
                       + CASE WHEN h.license_lh THEN 0.10 ELSE 0 END
                       + CASE WHEN h.license_ips THEN 0.05 ELSE 0 END) AS license_w,
      (h.category<>'admin' AND COALESCE(h.role_level,'')<>'Owner' AND h.hours_for_surge>0) AS surge_eligible
    FROM hours h),
  weighted2 AS (SELECT w.*,
      CASE WHEN w.surge_eligible THEN w.hours_for_surge*w.role_w*w.location_w*w.tenure_w*w.license_w ELSE 0 END AS weighted_hours
    FROM weighted w),
  totals AS (SELECT COALESCE(SUM(weighted_hours),0) AS total_weighted_hours,
      COALESCE(SUM(CASE WHEN role='Reception' AND pay_type='HOURLY' THEN pay_rate*hourly_hours ELSE 0 END),0) AS reception_wages_this_week
    FROM weighted2),
  pool AS (SELECT total_weighted_hours, reception_wages_this_week,
      GREATEST(0,COALESCE(v_weekly_budget,0)-reception_wages_this_week) AS surge_pool FROM totals),
  computed AS (SELECT
      w.team_member_id, w.role, w.role_level, w.role_category, w.pay_type, w.pay_rate,
      w.this_week_qtd_sp, w.last_week_qtd_sp,
      w.this_week_payroll_ytd, w.prior_qtr_end_payroll_ytd,
      w.hsm_prior_total,
      w.prior_wp_total,
      CASE WHEN w.this_week_payroll_ytd IS NULL OR w.prior_qtr_end_payroll_ytd IS NULL
           THEN NULL
           ELSE ROUND(w.this_week_payroll_ytd - w.prior_qtr_end_payroll_ytd, 2) END AS qtd_paid,
      w.week_health_days, w.surge_eligible,
      w.weighted_hours, w.hours_for_surge, w.hourly_hours, w.salaried_paid_fraction,
      w.paid_off_hours, w.unpaid_off_hours, p.surge_pool, p.total_weighted_hours, p.reception_wages_this_week,
      ROUND(
        CASE WHEN w.pay_type='HOURLY' THEN w.pay_rate*w.hourly_hours ELSE w.pay_rate*w.salaried_paid_fraction END
      , 2) AS c_weekly_pay,
      ROUND(
        CASE
          WHEN w.role_category <> 'Sales' THEN 0
          WHEN w.role_level IN ('Unit Manager', 'Team Manager', 'Section Manager', 'Office Manager')
            THEN 0.10 * v_manager_baseline
          ELSE 0.10 * GREATEST(0, w.this_week_qtd_sp - w.last_week_qtd_sp)
        END
      , 2) AS c_base_advance,
      ROUND(CASE WHEN w.week_health_days>=5 THEN 25.00 ELSE 0 END, 2) AS c_health_bonus,
      ROUND(
        CASE WHEN p.total_weighted_hours>0 THEN (w.weighted_hours/p.total_weighted_hours)*p.surge_pool ELSE 0 END
      , 2) AS c_service_surge_share,
      ROUND(
        CASE w.role_level
          WHEN 'Unit Manager'    THEN COALESCE(v_scorecard_annual,0)*0.001
          WHEN 'Team Manager'    THEN COALESCE(v_scorecard_annual,0)*0.002
          WHEN 'Section Manager' THEN COALESCE(v_scorecard_annual,0)*0.002
          WHEN 'Office Manager'  THEN COALESCE(v_scorecard_annual,0)*0.003
          ELSE 0::numeric END
      , 2) AS c_manager_bonus,
      0::numeric AS c_agency_profit_share
    FROM weighted2 w CROSS JOIN pool p)
  SELECT c.team_member_id, c.c_weekly_pay, c.c_base_advance, c.c_health_bonus, c.c_service_surge_share,
    CASE WHEN c.this_week_payroll_ytd IS NULL OR c.prior_qtr_end_payroll_ytd IS NULL THEN NULL
         ELSE ROUND(GREATEST(0,
           (c.this_week_qtd_sp + c.hsm_prior_total
            + CASE WHEN c.role_category = 'Retention' THEN c.prior_wp_total ELSE 0 END)
           - c.qtd_paid
           - CASE WHEN c.role_category = 'Retention' THEN 0 ELSE c.c_weekly_pay END
           - c.c_base_advance
           - c.c_agency_profit_share), 2)
    END AS true_pay_bonus,
    c.c_manager_bonus, c.c_agency_profit_share,
    jsonb_build_object(
      'role_level', c.role_level, 'role_category', c.role_category,
      'this_week_qtd_sp', c.this_week_qtd_sp, 'last_week_qtd_sp', c.last_week_qtd_sp,
      'wow_sp_increase', GREATEST(0, c.this_week_qtd_sp - c.last_week_qtd_sp),
      'team_total_sp', v_team_total_sp,
      'required_count_avg', v_required_count_avg,
      'weeks_elapsed', v_weeks_elapsed,
      'manager_baseline', v_manager_baseline,
      'cycle_start', v_cycle_start,
      'prior_qtr_end_anchor_date', v_prior_qtr_end,
      'this_week_payroll_ytd', c.this_week_payroll_ytd,
      'prior_qtr_end_payroll_ytd', c.prior_qtr_end_payroll_ytd,
      'qtd_paid', c.qtd_paid,
      'hsm_prior_total', c.hsm_prior_total,
      'prior_wp_total', c.prior_wp_total,
      'earned_pool', c.this_week_qtd_sp + c.hsm_prior_total
                   + CASE WHEN c.role_category = 'Retention' THEN c.prior_wp_total ELSE 0 END,
      'wp_subtracted',
        CASE WHEN c.role_category = 'Retention' THEN 0 ELSE c.c_weekly_pay END,
      'this_week_total_non_tpb',
        c.c_weekly_pay + c.c_base_advance + c.c_health_bonus
        + c.c_service_surge_share + c.c_manager_bonus + c.c_agency_profit_share,
      'paid_off_hours', c.paid_off_hours, 'unpaid_off_hours', c.unpaid_off_hours,
      'hours_for_surge', c.hours_for_surge, 'hourly_hours', c.hourly_hours,
      'salaried_paid_fraction', c.salaried_paid_fraction,
      'week_health_days', c.week_health_days,
      'surge_eligible', c.surge_eligible, 'weighted_hours', c.weighted_hours,
      'inputs', jsonb_build_object(
        'annual_retention_budget', v_annual_budget,
        'weekly_retention_budget', v_weekly_budget,
        'reception_wages_this_week', c.reception_wages_this_week,
        'surge_pool', c.surge_pool,
        'total_weighted_hours', c.total_weighted_hours,
        'scorecard_annual_projected', v_scorecard_annual)
    ) AS diagnostics
  FROM computed c;
END;
$function$;
