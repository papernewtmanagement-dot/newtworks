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
      COALESCE(wctd.sales_points, 0)              AS this_week_sp,
      wctd.pay_paid_to_date_qtd                   AS paid_qtd,
      t.role,
      t.role_level,
      t.category,
      t.pay_type,
      t.pay_rate,
      t.work_location,
      t.start_date,
      t.is_active,
      t.license_pc, t.license_lh, t.license_ips,
      -- Hours
      CASE
        WHEN t.role = 'Reception' THEN COALESCE((
            SELECT SUM(EXTRACT(EPOCH FROM (tce.clock_out_at - tce.clock_in_at))/3600.0)
            FROM public.time_clock_entries tce
            WHERE tce.agency_id      = p_agency_id
              AND tce.team_member_id = t.id
              AND tce.clock_in_at   >= (v_week_start_date::timestamp AT TIME ZONE 'America/Chicago')
              AND tce.clock_in_at   <  ((p_week_ending_date + 1)::timestamp AT TIME ZONE 'America/Chicago')
              AND tce.clock_out_at IS NOT NULL
          ), 0)
        ELSE
          COALESCE(wctd.mon_hours,0)+COALESCE(wctd.tue_hours,0)+COALESCE(wctd.wed_hours,0)
          +COALESCE(wctd.thu_hours,0)+COALESCE(wctd.fri_hours,0)
      END                                                                AS hours_this_week,
      -- Health hits
      COALESCE((
        SELECT COUNT(*)::int
        FROM public.team_health_checkins thc
        WHERE thc.agency_id = p_agency_id
          AND thc.team_id   = t.id
          AND thc.log_date BETWEEN v_week_start_date AND p_week_ending_date
          AND thc.hit_today = true
          AND EXTRACT(DOW FROM thc.log_date) BETWEEN 1 AND 5
      ), 0)                                                              AS weekday_hits,
      -- QTD SP
      COALESCE((
        SELECT SUM(wctd2.sales_points)
        FROM public.weekly_cpr_team_detail wctd2
        JOIN public.weekly_cpr_reports     r2 ON r2.id = wctd2.weekly_cpr_report_id
        WHERE r2.agency_id        = p_agency_id
          AND r2.week_ending_date BETWEEN v_quarter_start_date AND p_week_ending_date
          AND wctd2.team_member_id = t.id
      ), 0)                                                              AS qtd_sp
    FROM public.weekly_cpr_team_detail wctd
    JOIN public.weekly_cpr_reports     r ON r.id = wctd.weekly_cpr_report_id
    JOIN public.team                   t ON t.id = wctd.team_member_id
    WHERE r.agency_id        = p_agency_id
      AND r.week_ending_date = p_week_ending_date
  ),
  weighted AS (
    SELECT
      b.*,
      -- role weight
      CASE
        WHEN b.role = 'Reception'                       THEN 1.00
        WHEN b.role IN ('Acquisition','Inside Sales')   THEN 0.25
        ELSE 0
      END AS role_w,
      -- location weight
      CASE
        WHEN b.work_location = 'in_office' THEN 1.00
        WHEN b.work_location = 'remote'    THEN 0.85
        ELSE 1.00
      END AS location_w,
      -- tenure weight (52-week linear ramp, capped at 1.0)
      LEAST(1.00, GREATEST(0,
        FLOOR((p_week_ending_date - b.start_date)::numeric / 7.0) / 52.0
      ))    AS tenure_w,
      -- license weight (floor 0.50 + PC 0.35 + LH 0.10 + IPS 0.05, cap 1.00)
      LEAST(1.00,
        0.50
        + CASE WHEN b.license_pc  THEN 0.35 ELSE 0 END
        + CASE WHEN b.license_lh  THEN 0.10 ELSE 0 END
        + CASE WHEN b.license_ips THEN 0.05 ELSE 0 END
      )     AS license_w,
      -- eligibility
      (b.is_active = true
        AND b.category <> 'admin'
        AND COALESCE(b.role_level,'') <> 'Owner'
        AND b.hours_this_week > 0) AS surge_eligible
    FROM base b
  ),
  weighted2 AS (
    SELECT w.*,
      CASE WHEN w.surge_eligible
           THEN w.hours_this_week * w.role_w * w.location_w * w.tenure_w * w.license_w
           ELSE 0 END AS weighted_hours
    FROM weighted w
  ),
  totals AS (
    SELECT
      COALESCE(SUM(weighted_hours), 0) AS total_weighted_hours,
      COALESCE(SUM(
        CASE WHEN role = 'Reception' AND pay_type = 'HOURLY'
             THEN pay_rate * hours_this_week
             ELSE 0
        END), 0)                       AS reception_wages_this_week
    FROM weighted2
  ),
  pool AS (
    SELECT
      total_weighted_hours,
      reception_wages_this_week,
      GREATEST(0, COALESCE(v_weekly_budget,0) - reception_wages_this_week) AS surge_pool
    FROM totals
  ),
  computed AS (
    SELECT
      w.team_member_id,
      w.role, w.pay_type, w.pay_rate, w.hours_this_week, w.this_week_sp,
      w.paid_qtd, w.qtd_sp, w.weekday_hits, w.surge_eligible, w.weighted_hours,
      p.surge_pool, p.total_weighted_hours, p.reception_wages_this_week,
      -- Components
      CASE WHEN w.pay_type = 'HOURLY' THEN w.pay_rate * w.hours_this_week
           ELSE w.pay_rate END                                            AS c_weekly_pay,
      0.10 * w.this_week_sp                                               AS c_base_advance,
      CASE WHEN w.weekday_hits >= 5 THEN 25.00 ELSE 0 END                 AS c_health_bonus,
      CASE WHEN p.total_weighted_hours > 0
           THEN (w.weighted_hours / p.total_weighted_hours) * p.surge_pool
           ELSE 0 END                                                     AS c_service_surge_share,
      0::numeric                                                          AS c_manager_bonus,
      0::numeric                                                          AS c_agency_profit_share
    FROM weighted2 w CROSS JOIN pool p
  )
  SELECT
    c.team_member_id,
    c.c_weekly_pay                                                        AS weekly_pay,
    c.c_base_advance                                                      AS base_advance,
    c.c_health_bonus                                                      AS health_bonus,
    c.c_service_surge_share                                               AS service_surge_share,
    CASE
      WHEN c.paid_qtd IS NULL THEN NULL
      ELSE GREATEST(0,
        c.qtd_sp - (
          c.paid_qtd
          + c.c_weekly_pay
          + c.c_base_advance
          + c.c_health_bonus
          + c.c_service_surge_share
          + c.c_manager_bonus
          + c.c_agency_profit_share
        )
      )
    END                                                                   AS true_pay_bonus,
    c.c_manager_bonus                                                     AS manager_bonus,
    c.c_agency_profit_share                                               AS agency_profit_share,
    jsonb_build_object(
      'week_start_date',       v_week_start_date,
      'quarter_start_date',    v_quarter_start_date,
      'hours_this_week',       c.hours_this_week,
      'this_week_sp',          c.this_week_sp,
      'qtd_sp',                c.qtd_sp,
      'pay_paid_to_date_qtd',  c.paid_qtd,
      'weekday_hits',          c.weekday_hits,
      'surge_eligible',        c.surge_eligible,
      'weighted_hours',        c.weighted_hours,
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
    )                                                                     AS diagnostics
  FROM computed c;
END;
$$;
