-- compute_weekly_pay v3 — incorporates:
--   1. Base Advance = 1% × MAX(0, this_week_QTD_SP − last_week_QTD_SP)
--      Source: weekly_cpr_team_detail.sales_points (cumulative QTD at week-end).
--      Last week's row missing → treat as 0 (cold start; honest for week 1).
--   2. Salaried hours default to 40 minus ALL recorded time off (paid+unpaid)
--      for service-surge weighted-hours math.
--   3. Salaried Base Pay pro-rated by (40 − UNPAID time off) / 40.
--      Paid PTO does NOT reduce base pay; unpaid PTO does.
--   Time off source: time_off_requests, status='approved', overlapping the week.

CREATE OR REPLACE FUNCTION public.compute_weekly_pay(
  p_agency_id        uuid,
  p_week_ending_date date
)
RETURNS TABLE(
  team_member_id       uuid,
  weekly_pay           numeric,
  base_advance         numeric,
  health_bonus         numeric,
  service_surge_share  numeric,
  true_pay_bonus       numeric,
  manager_bonus        numeric,
  agency_profit_share  numeric,
  diagnostics          jsonb
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_week_start_date    date := p_week_ending_date - 6;
  v_quarter_start_date date;
  v_retention_jsonb    jsonb;
  v_annual_budget      numeric;
  v_weekly_budget      numeric;
BEGIN
  SELECT (setting_value::date) INTO v_quarter_start_date
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'cycle_anchor_date';

  v_retention_jsonb := public.compute_retention_budget_weekly(p_agency_id, p_week_ending_date);
  v_annual_budget   := NULLIF(v_retention_jsonb->>'budget','')::numeric;
  v_weekly_budget   := v_annual_budget / 52.0;

  RETURN QUERY
  WITH base AS (
    SELECT
      wctd.team_member_id,
      COALESCE(wctd.sales_points, 0)              AS this_week_qtd_sp,
      wctd.pay_paid_to_date_qtd                   AS paid_qtd,
      t.role, t.role_level, t.category,
      t.pay_type, t.pay_rate, t.work_location, t.start_date, t.is_active,
      t.license_pc, t.license_lh, t.license_ips,
      -- Reception actual hours from time-clock (HOURLY pay uses these)
      CASE WHEN t.role = 'Reception' THEN COALESCE((
          SELECT SUM(EXTRACT(EPOCH FROM (tce.clock_out_at - tce.clock_in_at))/3600.0)
          FROM public.time_clock_entries tce
          WHERE tce.agency_id      = p_agency_id
            AND tce.team_member_id = t.id
            AND tce.clock_in_at   >= (v_week_start_date::timestamp AT TIME ZONE 'America/Chicago')
            AND tce.clock_in_at   <  ((p_week_ending_date + 1)::timestamp AT TIME ZONE 'America/Chicago')
            AND tce.clock_out_at IS NOT NULL
        ), 0)
        ELSE NULL
      END                                                                AS reception_hours,
      -- Time off this week (paid vs unpaid)
      -- Hours/day: 4 for partial_day in (morning|afternoon), else 8
      -- Days: weekdays (Mon-Fri) in the intersection of request range and week.
      COALESCE((
        SELECT SUM(
          CASE WHEN tor.partial_day IN ('morning','afternoon') THEN 4 ELSE 8 END
          * (SELECT COUNT(*)::int
             FROM generate_series(
               GREATEST(tor.start_date, v_week_start_date),
               LEAST(tor.end_date, p_week_ending_date),
               '1 day'::interval
             ) d
             WHERE EXTRACT(DOW FROM d) BETWEEN 1 AND 5)
        )
        FROM public.time_off_requests tor
        WHERE tor.agency_id           = p_agency_id
          AND tor.requester_team_id   = t.id
          AND tor.status              = 'approved'
          AND tor.start_date         <= p_week_ending_date
          AND tor.end_date           >= v_week_start_date
          AND tor.is_paid             = true
      ), 0)                                                              AS paid_off_hours,
      COALESCE((
        SELECT SUM(
          CASE WHEN tor.partial_day IN ('morning','afternoon') THEN 4 ELSE 8 END
          * (SELECT COUNT(*)::int
             FROM generate_series(
               GREATEST(tor.start_date, v_week_start_date),
               LEAST(tor.end_date, p_week_ending_date),
               '1 day'::interval
             ) d
             WHERE EXTRACT(DOW FROM d) BETWEEN 1 AND 5)
        )
        FROM public.time_off_requests tor
        WHERE tor.agency_id           = p_agency_id
          AND tor.requester_team_id   = t.id
          AND tor.status              = 'approved'
          AND tor.start_date         <= p_week_ending_date
          AND tor.end_date           >= v_week_start_date
          AND tor.is_paid             = false
      ), 0)                                                              AS unpaid_off_hours,
      -- Health hits
      COALESCE((
        SELECT COUNT(*)::int
        FROM public.team_health_checkins thc
        WHERE thc.agency_id = p_agency_id AND thc.team_id = t.id
          AND thc.log_date BETWEEN v_week_start_date AND p_week_ending_date
          AND thc.hit_today = true
          AND EXTRACT(DOW FROM thc.log_date) BETWEEN 1 AND 5
      ), 0)                                                              AS weekday_hits,
      -- Last week's stored QTD SP (for WoW increase computing this week's Advance)
      COALESCE((
        SELECT wctd_last.sales_points
        FROM public.weekly_cpr_team_detail wctd_last
        JOIN public.weekly_cpr_reports     r_last ON r_last.id = wctd_last.weekly_cpr_report_id
        WHERE r_last.agency_id        = p_agency_id
          AND r_last.week_ending_date = p_week_ending_date - 7
          AND wctd_last.team_member_id = t.id
      ), 0)                                                              AS last_week_qtd_sp
    FROM public.weekly_cpr_team_detail wctd
    JOIN public.weekly_cpr_reports     r ON r.id = wctd.weekly_cpr_report_id
    JOIN public.team                   t ON t.id = wctd.team_member_id
    WHERE r.agency_id        = p_agency_id
      AND r.week_ending_date = p_week_ending_date
  ),
  hours AS (
    SELECT b.*,
      -- Hours used in surge weighting:
      --   Reception (hourly): actual time-clock hours
      --   Salaried: 40 default minus ALL time off (paid + unpaid)
      CASE
        WHEN b.role = 'Reception' THEN b.reception_hours
        ELSE GREATEST(0, 40.0 - b.paid_off_hours - b.unpaid_off_hours)
      END                                                                AS hours_for_surge,
      -- Hours for HOURLY base pay computation: actual hours worked
      b.reception_hours                                                  AS hourly_hours,
      -- Salaried base-pay multiplier: (40 − unpaid PTO) / 40, floor at 0
      GREATEST(0, (40.0 - b.unpaid_off_hours) / 40.0)                    AS salaried_paid_fraction
    FROM base b
  ),
  weighted AS (
    SELECT h.*,
      CASE
        WHEN h.role = 'Reception'                       THEN 1.00
        WHEN h.role IN ('Acquisition','Inside Sales')   THEN 0.25
        ELSE 0
      END                                                                AS role_w,
      CASE
        WHEN h.work_location = 'in_office' THEN 1.00
        WHEN h.work_location = 'remote'    THEN 0.85
        ELSE 1.00
      END                                                                AS location_w,
      LEAST(1.00, GREATEST(0,
        FLOOR((p_week_ending_date - h.start_date)::numeric / 7.0) / 52.0
      ))                                                                 AS tenure_w,
      LEAST(1.00,
        0.50
        + CASE WHEN h.license_pc  THEN 0.35 ELSE 0 END
        + CASE WHEN h.license_lh  THEN 0.10 ELSE 0 END
        + CASE WHEN h.license_ips THEN 0.05 ELSE 0 END
      )                                                                  AS license_w,
      (h.is_active = true
        AND h.category <> 'admin'
        AND COALESCE(h.role_level,'') <> 'Owner'
        AND h.hours_for_surge > 0)                                       AS surge_eligible
    FROM hours h
  ),
  weighted2 AS (
    SELECT w.*,
      CASE WHEN w.surge_eligible
           THEN w.hours_for_surge * w.role_w * w.location_w * w.tenure_w * w.license_w
           ELSE 0 END                                                    AS weighted_hours
    FROM weighted w
  ),
  totals AS (
    SELECT
      COALESCE(SUM(weighted_hours), 0)                                   AS total_weighted_hours,
      COALESCE(SUM(
        CASE WHEN role = 'Reception' AND pay_type = 'HOURLY'
             THEN pay_rate * hourly_hours
             ELSE 0
        END), 0)                                                         AS reception_wages_this_week
    FROM weighted2
  ),
  pool AS (
    SELECT
      total_weighted_hours, reception_wages_this_week,
      GREATEST(0, COALESCE(v_weekly_budget,0) - reception_wages_this_week) AS surge_pool
    FROM totals
  ),
  computed AS (
    SELECT
      w.team_member_id,
      w.role, w.pay_type, w.pay_rate,
      w.this_week_qtd_sp, w.last_week_qtd_sp,
      w.paid_qtd, w.weekday_hits, w.surge_eligible, w.weighted_hours,
      w.hours_for_surge, w.hourly_hours, w.salaried_paid_fraction,
      w.paid_off_hours, w.unpaid_off_hours,
      p.surge_pool, p.total_weighted_hours, p.reception_wages_this_week,
      -- 1. Weekly Pay (Base Pay)
      CASE
        WHEN w.pay_type = 'HOURLY' THEN w.pay_rate * w.hourly_hours
        ELSE w.pay_rate * w.salaried_paid_fraction
      END                                                                AS c_weekly_pay,
      -- 2. Advance = 1% × MAX(0, WoW QTD-SP increase)
      0.01 * GREATEST(0, w.this_week_qtd_sp - w.last_week_qtd_sp)        AS c_base_advance,
      -- 3. Health Bonus
      CASE WHEN w.weekday_hits >= 5 THEN 25.00 ELSE 0 END                AS c_health_bonus,
      -- 4. Service Surge Share
      CASE WHEN p.total_weighted_hours > 0
           THEN (w.weighted_hours / p.total_weighted_hours) * p.surge_pool
           ELSE 0
      END                                                                AS c_service_surge_share,
      0::numeric                                                         AS c_manager_bonus,
      0::numeric                                                         AS c_agency_profit_share
    FROM weighted2 w CROSS JOIN pool p
  )
  SELECT
    c.team_member_id,
    c.c_weekly_pay,
    c.c_base_advance,
    c.c_health_bonus,
    c.c_service_surge_share,
    -- 5. True Pay Bonus
    CASE
      WHEN c.paid_qtd IS NULL THEN NULL
      ELSE GREATEST(0,
        c.this_week_qtd_sp - (
          c.paid_qtd
          + c.c_weekly_pay
          + c.c_base_advance
          + c.c_health_bonus
          + c.c_service_surge_share
          + c.c_manager_bonus
          + c.c_agency_profit_share
        )
      )
    END                                                                  AS true_pay_bonus,
    c.c_manager_bonus,
    c.c_agency_profit_share,
    jsonb_build_object(
      'week_start_date',         v_week_start_date,
      'quarter_start_date',      v_quarter_start_date,
      'this_week_qtd_sp',        c.this_week_qtd_sp,
      'last_week_qtd_sp',        c.last_week_qtd_sp,
      'wow_sp_increase',         GREATEST(0, c.this_week_qtd_sp - c.last_week_qtd_sp),
      'paid_off_hours',          c.paid_off_hours,
      'unpaid_off_hours',        c.unpaid_off_hours,
      'hours_for_surge',         c.hours_for_surge,
      'hourly_hours',            c.hourly_hours,
      'salaried_paid_fraction',  c.salaried_paid_fraction,
      'pay_paid_to_date_qtd',    c.paid_qtd,
      'weekday_hits',            c.weekday_hits,
      'surge_eligible',          c.surge_eligible,
      'weighted_hours',          c.weighted_hours,
      'inputs', jsonb_build_object(
        'annual_retention_budget',    v_annual_budget,
        'weekly_retention_budget',    v_weekly_budget,
        'reception_wages_this_week',  c.reception_wages_this_week,
        'surge_pool',                 c.surge_pool,
        'total_weighted_hours',       c.total_weighted_hours
      ),
      'tpb_note',           CASE WHEN c.paid_qtd IS NULL
                                 THEN 'NULL until pay_paid_to_date_qtd is entered for this team member this week'
                                 ELSE NULL END,
      'manager_bonus_note', 'Scorecard infra not yet built; column writes 0',
      'agency_profit_note', 'Deferred per Peter 2026-06-20; column writes 0'
    )                                                                    AS diagnostics
  FROM computed c;
END;
$$;
