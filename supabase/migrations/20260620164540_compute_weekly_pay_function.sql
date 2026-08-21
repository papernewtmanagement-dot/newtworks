-- compute_weekly_pay(p_agency_id, p_week_ending_date)
-- Returns one row per team_member in this week's CPR snapshot with the
-- 7 payroll components plus a JSONB diagnostic. STABLE: no writes.
--
-- Component definitions (handbook 03 + locked op-rules as of 2026-06-20):
--   1. weekly_pay (Base Pay) — team.pay_rate × hours_worked for HOURLY,
--      else team.pay_rate as the fixed weekly amount for SALARY.
--      Note: rating-band $ table for AM/AA is not yet defined; falling
--      back to team.pay_rate until Peter ships the band table.
--   2. base_advance (the "Advance") — 10% of this week's sales_points.
--   3. health_bonus — $25 if 5 weekday hits in team_health_checkins.
--   4. service_surge_share — five-factor split of weekly retention budget
--      surge pool. Eligibility: is_active=true, category<>'admin',
--      role_level<>'Owner', hours_this_week>0. Pool members excluded if
--      any condition fails.
--   5. true_pay_bonus — max(0, QTD_SP − pay_paid_to_date_qtd − this_week_components).
--      NULL when pay_paid_to_date_qtd has not been entered yet.
--   6. manager_bonus — 0 until on-time Scorecard infra is built.
--   7. agency_profit_share — 0 (deferred until activated by Peter).

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
  v_week_start_date    date := p_week_ending_date - 6;  -- Sun
  v_quarter_start_date date;
  v_retention_jsonb    jsonb;
  v_annual_budget      numeric;
  v_weekly_budget      numeric;
  v_reception_wages    numeric := 0;
  v_surge_pool         numeric := 0;
  v_total_weighted     numeric := 0;
BEGIN
  -- Quarter start = settings.cycle_anchor_date for the cycle covering this week.
  SELECT (setting_value::date) INTO v_quarter_start_date
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'cycle_anchor_date';

  -- Retention budget (annual) → weekly = annual / 52  [Reading A, locked 2026-06-20]
  v_retention_jsonb := public.compute_retention_budget_weekly(p_agency_id, p_week_ending_date);
  v_annual_budget   := NULLIF(v_retention_jsonb->>'budget','')::numeric;
  v_weekly_budget   := v_annual_budget / 52.0;

  ---------------------------------------------------------------------------
  -- Stage 1: per-team-member working rows (in this week's CPR snapshot)
  ---------------------------------------------------------------------------
  CREATE TEMP TABLE IF NOT EXISTS _wp_rows ON COMMIT DROP AS
  SELECT
    wctd.team_member_id,
    wctd.id                                                                                     AS detail_id,
    COALESCE(wctd.sales_points, 0)                                                              AS this_week_sp,
    COALESCE(wctd.pay_paid_to_date_qtd, NULL)                                                   AS paid_qtd,
    t.role,
    t.role_level,
    t.role_category,
    t.category,
    t.pay_type,
    t.pay_rate,
    t.work_location,
    t.start_date,
    t.is_active,
    t.license_pc,
    t.license_lh,
    t.license_ips,
    -- Hours: Reception → time_clock_entries this week; AM → CPR form sum
    CASE
      WHEN t.role = 'Reception' THEN
        COALESCE((
          SELECT SUM(EXTRACT(EPOCH FROM (tce.clock_out_at - tce.clock_in_at))/3600.0)
          FROM public.time_clock_entries tce
          WHERE tce.agency_id = p_agency_id
            AND tce.team_member_id = t.id
            AND tce.clock_in_at  >= (v_week_start_date::timestamp AT TIME ZONE 'America/Chicago')
            AND tce.clock_in_at  <  ((p_week_ending_date + 1)::timestamp AT TIME ZONE 'America/Chicago')
            AND tce.clock_out_at IS NOT NULL
        ), 0)
      ELSE
        COALESCE(wctd.mon_hours,0)+COALESCE(wctd.tue_hours,0)+COALESCE(wctd.wed_hours,0)
        +COALESCE(wctd.thu_hours,0)+COALESCE(wctd.fri_hours,0)
    END                                                                                         AS hours_this_week,
    -- Health goal: 5/5 weekday hit_today=true
    COALESCE((
      SELECT COUNT(*)
      FROM public.team_health_checkins thc
      WHERE thc.agency_id  = p_agency_id
        AND thc.team_id    = t.id
        AND thc.log_date BETWEEN v_week_start_date AND p_week_ending_date
        AND thc.hit_today  = true
        AND EXTRACT(DOW FROM thc.log_date) BETWEEN 1 AND 5
    ), 0)                                                                                       AS weekday_hits,
    -- QTD sales points through this week
    COALESCE((
      SELECT SUM(wctd2.sales_points)
      FROM public.weekly_cpr_team_detail wctd2
      JOIN public.weekly_cpr_reports     r2 ON r2.id = wctd2.weekly_cpr_report_id
      WHERE r2.agency_id        = p_agency_id
        AND r2.week_ending_date BETWEEN v_quarter_start_date AND p_week_ending_date
        AND wctd2.team_member_id = t.id
    ), 0)                                                                                       AS qtd_sp
  FROM public.weekly_cpr_team_detail wctd
  JOIN public.weekly_cpr_reports     r ON r.id = wctd.weekly_cpr_report_id
  JOIN public.team                   t ON t.id = wctd.team_member_id
  WHERE r.agency_id        = p_agency_id
    AND r.week_ending_date = p_week_ending_date;

  ---------------------------------------------------------------------------
  -- Stage 2: Reception hourly wages this week (subtracted from weekly budget)
  ---------------------------------------------------------------------------
  SELECT COALESCE(SUM(
           CASE WHEN role = 'Reception' AND pay_type = 'HOURLY'
                THEN pay_rate * hours_this_week
                ELSE 0
           END
         ), 0)
    INTO v_reception_wages
  FROM _wp_rows;

  v_surge_pool := GREATEST(0, COALESCE(v_weekly_budget, 0) - v_reception_wages);

  ---------------------------------------------------------------------------
  -- Stage 3: weighted hours per pool-eligible team member
  --   weighted = hours × role_w × location_w × tenure_w × license_w
  ---------------------------------------------------------------------------
  CREATE TEMP TABLE IF NOT EXISTS _wp_weighted ON COMMIT DROP AS
  WITH base AS (
    SELECT
      team_member_id,
      hours_this_week,
      -- Role weight (per op-rule)
      CASE
        WHEN role = 'Reception'                                THEN 1.00
        WHEN role IN ('Acquisition','Inside Sales')            THEN 0.25
        ELSE 0
      END                                                                                AS role_w,
      -- Location weight (in_office 1.00 / remote 0.85; per-shift override not yet used)
      CASE
        WHEN work_location = 'in_office' THEN 1.00
        WHEN work_location = 'remote'    THEN 0.85
        ELSE 1.00
      END                                                                                AS location_w,
      -- Tenure weight: weekly linear ramp over 52 weeks from start_date, cap 1.0
      LEAST(1.00, GREATEST(0,
        FLOOR((p_week_ending_date - start_date)::numeric / 7.0) / 52.0
      ))                                                                                 AS tenure_w,
      -- License weight: floor 0.50 + P&C +0.35 + L&H +0.10 + IPS +0.05, cap 1.00
      LEAST(1.00,
        0.50
        + CASE WHEN license_pc  THEN 0.35 ELSE 0 END
        + CASE WHEN license_lh  THEN 0.10 ELSE 0 END
        + CASE WHEN license_ips THEN 0.05 ELSE 0 END
      )                                                                                  AS license_w,
      -- Eligibility flags
      (is_active = true
        AND category <> 'admin'
        AND COALESCE(role_level,'') <> 'Owner'
        AND hours_this_week > 0)                                                         AS eligible
    FROM _wp_rows
  )
  SELECT
    team_member_id,
    eligible,
    hours_this_week,
    role_w,
    location_w,
    tenure_w,
    license_w,
    CASE WHEN eligible THEN hours_this_week * role_w * location_w * tenure_w * license_w
         ELSE 0 END AS weighted_hours
  FROM base;

  SELECT COALESCE(SUM(weighted_hours), 0) INTO v_total_weighted FROM _wp_weighted;

  ---------------------------------------------------------------------------
  -- Stage 4: assemble the 7 components per team member
  ---------------------------------------------------------------------------
  RETURN QUERY
  WITH per_person AS (
    SELECT
      r.team_member_id,
      r.role,
      r.pay_type,
      r.pay_rate,
      r.hours_this_week,
      r.this_week_sp,
      r.paid_qtd,
      r.qtd_sp,
      r.weekday_hits,
      -- 1. Weekly Pay (Base Pay)
      CASE
        WHEN r.pay_type = 'HOURLY' THEN r.pay_rate * r.hours_this_week
        ELSE r.pay_rate
      END                                                                                AS c_weekly_pay,
      -- 2. Advance
      0.10 * r.this_week_sp                                                              AS c_base_advance,
      -- 3. Health Bonus
      CASE WHEN r.weekday_hits >= 5 THEN 25.00 ELSE 0 END                                AS c_health_bonus,
      -- 4. Service Surge Share
      CASE
        WHEN v_total_weighted > 0
          THEN (w.weighted_hours / v_total_weighted) * v_surge_pool
        ELSE 0
      END                                                                                AS c_service_surge_share,
      -- 6. Manager Bonus (Scorecard infra not yet built)
      0::numeric                                                                         AS c_manager_bonus,
      -- 7. Agency Profit Share (deferred)
      0::numeric                                                                         AS c_agency_profit_share,
      w.eligible                                                                         AS surge_eligible,
      w.weighted_hours
    FROM _wp_rows r
    LEFT JOIN _wp_weighted w ON w.team_member_id = r.team_member_id
  )
  SELECT
    pp.team_member_id,
    pp.c_weekly_pay,
    pp.c_base_advance,
    pp.c_health_bonus,
    pp.c_service_surge_share,
    -- 5. True Pay Bonus — requires pay_paid_to_date_qtd to be entered.
    CASE
      WHEN pp.paid_qtd IS NULL THEN NULL
      ELSE GREATEST(0,
        pp.qtd_sp - (
          pp.paid_qtd
          + pp.c_weekly_pay
          + pp.c_base_advance
          + pp.c_health_bonus
          + pp.c_service_surge_share
          + pp.c_manager_bonus
          + pp.c_agency_profit_share
        )
      )
    END                                                                                  AS true_pay_bonus,
    pp.c_manager_bonus,
    pp.c_agency_profit_share,
    jsonb_build_object(
      'week_start_date',       v_week_start_date,
      'quarter_start_date',    v_quarter_start_date,
      'hours_this_week',       pp.hours_this_week,
      'this_week_sp',          pp.this_week_sp,
      'qtd_sp',                pp.qtd_sp,
      'pay_paid_to_date_qtd',  pp.paid_qtd,
      'weekday_hits',          pp.weekday_hits,
      'surge_eligible',        pp.surge_eligible,
      'weighted_hours',        pp.weighted_hours,
      'inputs', jsonb_build_object(
        'annual_retention_budget', v_annual_budget,
        'weekly_retention_budget', v_weekly_budget,
        'reception_wages_this_week', v_reception_wages,
        'surge_pool', v_surge_pool,
        'total_weighted_hours', v_total_weighted
      ),
      'tpb_note', CASE WHEN pp.paid_qtd IS NULL
                       THEN 'NULL until pay_paid_to_date_qtd is entered for this team member this week'
                       ELSE NULL END,
      'manager_bonus_note',    'Scorecard infrastructure not yet built; column writes 0',
      'agency_profit_note',    'Deferred per Peter 2026-06-20; column writes 0'
    )                                                                                    AS diagnostics
  FROM per_person pp;

  -- Cleanup temp tables
  DROP TABLE IF EXISTS _wp_weighted;
  DROP TABLE IF EXISTS _wp_rows;
END;
$$;
