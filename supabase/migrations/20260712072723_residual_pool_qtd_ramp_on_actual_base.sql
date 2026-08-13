-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-12 07:27:23 UTC (ledger name: residual_pool_qtd_ramp_on_actual_base) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260712072723.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
CREATE OR REPLACE FUNCTION public.compute_weekly_comp_residual_pool(
  p_agency_id uuid,
  p_week_end_date date
)
RETURNS TABLE(
  team_member_id uuid, full_name text, role text, role_category text, role_level text,
  annual_base_salary numeric, weekly_base_salary numeric,
  annual_commission_projected numeric, weekly_commission_projected numeric,
  ytd_sales_points numeric, sales_points_share_pct numeric,
  weighted_hours_at_40 numeric, retention_hours_share_pct numeric,
  person_share_pct numeric,
  annual_bonus numeric, weekly_bonus numeric,
  weekly_sales_pool_share numeric, weekly_retention_pool_share numeric,
  annual_total_comp numeric, weekly_total_comp numeric,
  diagnostics jsonb
)
LANGUAGE plpgsql
AS $function$
DECLARE
  v_year               int  := EXTRACT(YEAR    FROM p_week_end_date)::int;
  v_quarter            int  := EXTRACT(QUARTER FROM p_week_end_date)::int;
  v_calendar_q_start   date := make_date(v_year, ((v_quarter - 1) * 3) + 1, 1);
  v_calendar_q_end     date := (make_date(v_year, v_quarter * 3, 1) + INTERVAL '1 month - 1 day')::date;
  v_pool_start         date;
  v_pool_end           date;
  v_weeks_elapsed_qtd  int;
  v_weeks_in_quarter   int;
  v_pool_result        jsonb;
  v_carveouts_result   jsonb;
  v_annual_basis       numeric;
  v_current_pool_pct   numeric;
  v_qtd_envelope       numeric;
  v_quarterly_envelope numeric;
  v_weekly_envelope    numeric;
  v_annual_carveouts    numeric;
  v_quarterly_carveouts numeric;
  v_burden_multiplier  CONSTANT numeric := 0.08;
  v_wc_annual          CONSTANT numeric := 500.00;
  v_sales_weight       CONSTANT numeric := 0.65;
  v_retention_weight   CONSTANT numeric := 0.35;
BEGIN
  SELECT MIN(week_end_date), MAX(week_end_date), COUNT(*)
  INTO   v_pool_start, v_pool_end, v_weeks_in_quarter
  FROM   public.team_comp_pool_schedule
  WHERE  agency_id = p_agency_id
    AND  week_end_date >= v_calendar_q_start
    AND  week_end_date <= v_calendar_q_end;

  IF v_pool_start IS NULL OR p_week_end_date < v_pool_start THEN
    RETURN;
  END IF;

  SELECT COUNT(*)
  INTO   v_weeks_elapsed_qtd
  FROM   public.team_comp_pool_schedule
  WHERE  agency_id = p_agency_id
    AND  week_end_date >= v_pool_start
    AND  week_end_date <= p_week_end_date;

  v_pool_result       := public.compute_pool_basis_and_envelope(p_agency_id, p_week_end_date);
  v_carveouts_result  := public.compute_pool_carveouts(p_agency_id, p_week_end_date);
  v_annual_basis      := COALESCE(NULLIF(v_pool_result->'basis'->>'total_basis_annual','')::numeric, 0);
  v_current_pool_pct  := COALESCE(NULLIF(v_pool_result->'schedule'->>'pool_pct','')::numeric, 0);
  v_annual_carveouts  := COALESCE(NULLIF(v_carveouts_result->>'total_annual_carveouts','')::numeric, 0);
  v_quarterly_carveouts := v_annual_carveouts / 4.0;

  SELECT COALESCE(SUM((v_annual_basis * pool_pct / 100.0) / 52.0), 0)
  INTO   v_qtd_envelope
  FROM   public.team_comp_pool_schedule
  WHERE  agency_id = p_agency_id
    AND  week_end_date >= v_pool_start
    AND  week_end_date <= p_week_end_date;

  SELECT COALESCE(SUM((v_annual_basis * pool_pct / 100.0) / 52.0), 0)
  INTO   v_quarterly_envelope
  FROM   public.team_comp_pool_schedule
  WHERE  agency_id = p_agency_id
    AND  week_end_date >= v_pool_start
    AND  week_end_date <= v_pool_end;

  v_weekly_envelope := (v_annual_basis * v_current_pool_pct / 100.0) / 52.0;

  RETURN QUERY
  WITH roster AS (
    SELECT et.team_id AS id, et.first_name, et.last_name,
           et.role          AS r_role,
           et.role_category AS r_role_category,
           et.role_level    AS r_role_level,
           t.pay_type, t.pay_rate, t.work_location, et.start_date,
           t.license_pc, t.license_lh, t.license_ips,
           t.weekly_health_benefit_agency_paid
    FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
    JOIN public.team t ON t.id = et.team_id
  ),
  pool_weeks AS (
    SELECT week_end_date FROM public.team_comp_pool_schedule
    WHERE agency_id = p_agency_id
      AND week_end_date >= v_pool_start
      AND week_end_date <= p_week_end_date
  ),
  -- Per-person, per-pool-week base pay AND that week's tenure_mult
  per_person_week_base AS (
    SELECT r.id AS tm_id, pw.week_end_date,
      COALESCE(
        (SELECT COALESCE((pd.raw_earnings->'items'->'SALARY' ->>'period')::numeric, 0)
              + COALESCE((pd.raw_earnings->'items'->'REGULAR'->>'period')::numeric, 0)
         FROM public.payroll_detail pd
         JOIN public.payroll_runs   pr ON pr.id = pd.payroll_run_id
         WHERE pd.agency_id      = p_agency_id
           AND pd.team_member_id = r.id
           AND pr.pay_period_end = pw.week_end_date
         LIMIT 1),
        CASE
          WHEN r.pay_type = 'SALARY' AND r.pay_rate IS NOT NULL THEN r.pay_rate
          WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 40
          ELSE 0
        END
      ) AS week_base_paid,
      LEAST(1.00, GREATEST(0,
        FLOOR((pw.week_end_date - r.start_date)::numeric / 7.0) / 52.0
      )) AS week_tenure_mult
    FROM roster r CROSS JOIN pool_weeks pw
  ),
  per_person_qtd_base AS (
    SELECT tm_id,
      SUM(week_base_paid) AS qtd_base_paid,
      SUM(week_base_paid * week_tenure_mult) AS qtd_base_in_pool,
      SUM(week_base_paid * (1 - week_tenure_mult)) AS qtd_growth_budget
    FROM per_person_week_base
    GROUP BY tm_id
  ),
  per_person_qtd_health AS (
    SELECT r.id AS tm_id,
      COALESCE(r.weekly_health_benefit_agency_paid, 0) * v_weeks_elapsed_qtd AS qtd_health_paid
    FROM roster r
  ),
  curr_sp AS (
    SELECT b.id AS tm_id,
      COALESCE((
        SELECT wctd_c.sales_points
        FROM public.weekly_cpr_reports wr_c
        JOIN public.weekly_cpr_team_detail wctd_c ON wctd_c.weekly_cpr_report_id = wr_c.id
        WHERE wr_c.agency_id        = p_agency_id
          AND wr_c.week_ending_date = p_week_end_date
          AND wctd_c.team_member_id = b.id
        LIMIT 1
      ), 0) AS qtd_sp
    FROM roster b
  ),
  prior_sp AS (
    SELECT b.id AS tm_id,
      COALESCE((
        SELECT wctd_p.sales_points
        FROM public.weekly_cpr_reports wr_p
        JOIN public.weekly_cpr_team_detail wctd_p ON wctd_p.weekly_cpr_report_id = wr_p.id
        WHERE wr_p.agency_id        = p_agency_id
          AND wr_p.week_ending_date <  p_week_end_date
          AND wr_p.week_ending_date >= v_pool_start
          AND wctd_p.team_member_id = b.id
        ORDER BY wr_p.week_ending_date DESC
        LIMIT 1
      ), 0) AS prior_qtd_sp
    FROM roster b
  ),
  prior_qtd_paid AS (
    SELECT b.id AS tm_id,
      COALESCE(SUM(wctd_p.bonus),                0) AS prior_qtd_bonus_paid,
      COALESCE(SUM(wctd_p.sales_pool_share),     0) AS prior_qtd_sales_paid,
      COALESCE(SUM(wctd_p.retention_pool_share), 0) AS prior_qtd_retention_paid
    FROM roster b
    LEFT JOIN public.weekly_cpr_reports wr_p
      ON wr_p.agency_id        = p_agency_id
     AND wr_p.week_ending_date >= v_pool_start
     AND wr_p.week_ending_date <  p_week_end_date
    LEFT JOIN public.weekly_cpr_team_detail wctd_p
      ON wctd_p.weekly_cpr_report_id = wr_p.id
     AND wctd_p.team_member_id       = b.id
    GROUP BY b.id
  ),
  wh_calc AS (
    SELECT b.id AS tm_id, 40.0 AS hours,
      CASE WHEN b.r_role = 'Reception'                        THEN 1.00
           WHEN b.r_role IN ('Acquisition', 'Inside Sales')   THEN 0.25
           ELSE 0 END AS role_w,
      CASE WHEN b.work_location = 'in_office' THEN 1.00
           WHEN b.work_location = 'remote'    THEN 0.50
           ELSE 1.00 END AS location_w,
      LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - b.start_date)::numeric / 7.0) / 52.0)) AS tenure_w,
      LEAST(1.00, 0.50
           + CASE WHEN b.license_pc  THEN 0.35 ELSE 0 END
           + CASE WHEN b.license_lh  THEN 0.10 ELSE 0 END
           + CASE WHEN b.license_ips THEN 0.05 ELSE 0 END) AS license_w
    FROM roster b
  ),
  wh_final AS (
    SELECT wh.tm_id, wh.hours * wh.role_w * wh.location_w * wh.tenure_w * wh.license_w AS weighted_hours,
      wh.role_w, wh.location_w, wh.tenure_w, wh.license_w
    FROM wh_calc wh
  ),
  combined AS (
    SELECT b.id AS tm_id, b.first_name, b.last_name,
      b.r_role          AS c_role,
      b.r_role_category AS c_role_category,
      b.r_role_level    AS c_role_level,
      b.pay_type, b.pay_rate, b.weekly_health_benefit_agency_paid,
      COALESCE(ppb.qtd_base_paid,     0) AS c_qtd_base_paid,
      COALESCE(ppb.qtd_base_in_pool,  0) AS c_qtd_base_in_pool,
      COALESCE(ppb.qtd_growth_budget, 0) AS c_qtd_growth_budget,
      COALESCE(pph.qtd_health_paid,   0) AS c_qtd_health,
      COALESCE(cs.qtd_sp,             0) AS c_qtd_sp,
      COALESCE(ps.prior_qtd_sp,       0) AS c_prior_qtd_sp,
      COALESCE(wf.weighted_hours,     0) AS weighted_hours,
      COALESCE(pqp.prior_qtd_bonus_paid,      0) AS c_prior_qtd_bonus,
      COALESCE(pqp.prior_qtd_sales_paid,      0) AS c_prior_qtd_sales,
      COALESCE(pqp.prior_qtd_retention_paid,  0) AS c_prior_qtd_retention,
      wf.role_w, wf.location_w, wf.tenure_w, wf.license_w
    FROM roster b
    LEFT JOIN per_person_qtd_base   ppb ON ppb.tm_id = b.id
    LEFT JOIN per_person_qtd_health pph ON pph.tm_id = b.id
    LEFT JOIN curr_sp               cs  ON cs.tm_id  = b.id
    LEFT JOIN prior_sp              ps  ON ps.tm_id  = b.id
    LEFT JOIN prior_qtd_paid        pqp ON pqp.tm_id = b.id
    LEFT JOIN wh_final              wf  ON wf.tm_id  = b.id
  ),
  team_totals AS (
    SELECT
      SUM(c.c_qtd_base_paid)     AS qtd_base_paid_total,
      SUM(c.c_qtd_base_in_pool)  AS qtd_base_in_pool_total,
      SUM(c.c_qtd_growth_budget) AS qtd_growth_budget_total,
      SUM(c.c_qtd_health)        AS qtd_health_total,
      SUM(c.c_qtd_sp)            AS qtd_sp_total,
      SUM(CASE WHEN c.c_role_category = 'Sales' THEN c.c_qtd_sp ELSE 0 END) AS qtd_sp_sales_only,
      SUM(c.weighted_hours)      AS wh_total
    FROM combined c
  ),
  -- Bonus pool math (all QTD; carveouts NOT subtracted here per new Peter directive).
  -- Base subtracted = qtd_base_paid × tenure_mult (per-week). Growth budget (the (1-tenure_mult)
  -- portion of paid base) is agency-funded OUTSIDE the pool — same conceptual bucket as carveouts.
  -- envelope = base_in_pool + commission + health + burden + bonus
  -- burden   = 0.08 × (base_in_pool + commission + bonus)
  -- =>  bonus = (envelope − health − wc)/1.08 − base_in_pool
  --   [commissions preserved: NOT subtracted at envelope; they eat sales share only, 2026-07-11 lock]
  pool_calc AS (
    SELECT
      tt.*,
      v_qtd_envelope                                  AS qtd_envelope,
      (v_wc_annual * v_weeks_elapsed_qtd / 52.0)      AS qtd_wc,
      tt.qtd_sp_total                                 AS qtd_actual_commission,
      GREATEST(0,
        (v_qtd_envelope - (v_wc_annual * v_weeks_elapsed_qtd / 52.0) - tt.qtd_health_total)
        / (1 + v_burden_multiplier)
        - tt.qtd_base_in_pool_total
      ) AS qtd_bonus_pool
    FROM team_totals tt
  ),
  pool_split AS (
    SELECT pc.*,
      pc.qtd_bonus_pool * v_sales_weight                                    AS qtd_sales_pool_pre_comm,
      GREATEST(0, pc.qtd_bonus_pool * v_sales_weight - pc.qtd_actual_commission) AS qtd_sales_pool,
      pc.qtd_bonus_pool * v_retention_weight                                AS qtd_retention_pool,
      (pc.qtd_base_in_pool_total + pc.qtd_actual_commission + pc.qtd_bonus_pool) * v_burden_multiplier
                                                                             AS qtd_burden
    FROM pool_calc pc
  ),
  distributed AS (
    SELECT c.*, ps.*,
      CASE WHEN ps.qtd_sp_sales_only > 0 AND c.c_role_category = 'Sales'
           THEN c.c_qtd_sp / ps.qtd_sp_sales_only
           ELSE 0 END AS sp_share_ratio,
      CASE WHEN ps.wh_total > 0 THEN c.weighted_hours / ps.wh_total ELSE 0 END AS wh_share_ratio
    FROM combined c CROSS JOIN pool_split ps
  ),
  final AS (
    SELECT d.*,
      d.sp_share_ratio * d.qtd_sales_pool         AS qtd_sales_share,
      d.wh_share_ratio * d.qtd_retention_pool     AS qtd_retention_share,
      (d.sp_share_ratio * d.qtd_sales_pool + d.wh_share_ratio * d.qtd_retention_pool) AS qtd_bonus_earned
    FROM distributed d
  ),
  settled AS (
    SELECT f.*,
      GREATEST(0, f.qtd_bonus_earned    - f.c_prior_qtd_bonus)       AS this_week_bonus,
      GREATEST(0, f.qtd_sales_share     - f.c_prior_qtd_sales)       AS this_week_sales_share,
      GREATEST(0, f.qtd_retention_share - f.c_prior_qtd_retention)   AS this_week_retention_share
    FROM final f
  ),
  weekly_pool_totals AS (
    SELECT
      SUM(this_week_sales_share)     AS weekly_sales_pool_sum,
      SUM(this_week_retention_share) AS weekly_retention_pool_sum,
      SUM(this_week_bonus)           AS weekly_bonus_pool_sum
    FROM settled
  )
  SELECT
    s.tm_id,
    (s.first_name || ' ' || s.last_name)::text,
    s.c_role::text, s.c_role_category::text, s.c_role_level::text,
    ROUND(CASE
      WHEN s.pay_type = 'SALARY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 52
      WHEN s.pay_type = 'HOURLY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 40 * 52
      ELSE 0
    END, 2) AS annual_base_salary,
    ROUND(CASE
      WHEN s.pay_type = 'SALARY' AND s.pay_rate IS NOT NULL THEN s.pay_rate
      WHEN s.pay_type = 'HOURLY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 40
      ELSE 0
    END, 2) AS weekly_base_salary,
    ROUND(s.c_qtd_sp * 4, 2) AS annual_commission_projected,
    ROUND(GREATEST(0, s.c_qtd_sp - s.c_prior_qtd_sp), 2) AS weekly_commission_projected,
    ROUND(s.c_qtd_sp, 2)                         AS ytd_sales_points,
    ROUND(s.sp_share_ratio * 100, 4)             AS sales_points_share_pct,
    ROUND(s.weighted_hours, 4)                   AS weighted_hours_at_40,
    ROUND(s.wh_share_ratio * 100, 4)             AS retention_hours_share_pct,
    ROUND(CASE WHEN s.qtd_bonus_pool > 0
               THEN s.qtd_bonus_earned / s.qtd_bonus_pool
               ELSE 0 END * 100, 4)              AS person_share_pct,
    ROUND(s.qtd_bonus_earned * 4, 2)             AS annual_bonus,
    ROUND(s.this_week_bonus, 2)                  AS weekly_bonus,
    ROUND(s.this_week_sales_share, 2)            AS weekly_sales_pool_share,
    ROUND(s.this_week_retention_share, 2)        AS weekly_retention_pool_share,
    ROUND(
      CASE
        WHEN s.pay_type = 'SALARY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 52
        WHEN s.pay_type = 'HOURLY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 40 * 52
        ELSE 0
      END + s.c_qtd_sp * 4 + s.qtd_bonus_earned * 4
    , 2) AS annual_total_comp,
    ROUND(
      CASE
        WHEN s.pay_type = 'SALARY' AND s.pay_rate IS NOT NULL THEN s.pay_rate
        WHEN s.pay_type = 'HOURLY' AND s.pay_rate IS NOT NULL THEN s.pay_rate * 40
        ELSE 0
      END + GREATEST(0, s.c_qtd_sp - s.c_prior_qtd_sp) + s.this_week_bonus
    , 2) AS weekly_total_comp,
    jsonb_build_object(
      'commission_semantic', 'sp_delta_this_week_via_qtd_settlement',
      'design_note',
        'Quarterly envelope accreted from pool schedule ramp. Base subtracted = QTD actual paid × '
        || 'per-week tenure_mult (ramp preserved). Growth budget = paid × (1 - tenure_mult) '
        || 'funded OUTSIDE the pool. Carveouts also outside the pool.',
      'person_pay_type',     s.pay_type,
      'person_pay_rate',     s.pay_rate,
      'weight_factors',      jsonb_build_object(
        'hours_baseline', 40.0,
        'role_w',    s.role_w,
        'location_w', s.location_w,
        'tenure_w',  s.tenure_w,
        'license_w', s.license_w
      ),
      'quarter', jsonb_build_object(
        'year',              v_year,
        'quarter',           v_quarter,
        'calendar_q_start',  v_calendar_q_start,
        'calendar_q_end',    v_calendar_q_end,
        'pool_start',        v_pool_start,
        'pool_end',          v_pool_end,
        'weeks_elapsed_qtd', v_weeks_elapsed_qtd,
        'weeks_in_quarter',  v_weeks_in_quarter
      ),
      'envelope', jsonb_build_object(
        'annual_basis',        ROUND(v_annual_basis, 2),
        'current_pool_pct',    v_current_pool_pct,
        'weekly_envelope',     ROUND(v_weekly_envelope, 2),
        'qtd_envelope',        ROUND(s.qtd_envelope, 2),
        'quarterly_envelope',  ROUND(v_quarterly_envelope, 2)
      ),
      'qtd_subtractions', jsonb_build_object(
        'qtd_base_in_pool',             ROUND(s.qtd_base_in_pool_total, 2),
        'qtd_base_in_pool_source',      'actual paid × per-week tenure_mult; subtracted from envelope',
        'qtd_actual_base_paid',         ROUND(s.qtd_base_paid_total, 2),
        'qtd_actual_base_paid_source',
          'payroll_detail SALARY+REGULAR per pool-week; configured rate fallback if row missing',
        'qtd_growth_budget',            ROUND(s.qtd_growth_budget_total, 2),
        'qtd_growth_budget_note',       'paid × (1 - tenure_mult); agency-funded OUTSIDE pool during ramp',
        'qtd_actual_health',            ROUND(s.qtd_health_total, 2),
        'qtd_actual_health_source',     'team.weekly_health_benefit_agency_paid × weeks_elapsed',
        'qtd_actual_commission',        ROUND(s.qtd_actual_commission, 2),
        'qtd_actual_commission_source', 'team QTD SP (1 SP = $1); eats sales share only',
        'qtd_wc',                       ROUND(s.qtd_wc, 2),
        'qtd_burden',                   ROUND(s.qtd_burden, 2),
        'qtd_burden_note',              '0.08 × (base_in_pool + commission + bonus); implicit in envelope math'
      ),
      'qtd_pools', jsonb_build_object(
        'qtd_bonus_pool',           ROUND(s.qtd_bonus_pool, 2),
        'qtd_sales_pool_pre_comm',  ROUND(s.qtd_sales_pool_pre_comm, 2),
        'qtd_sales_pool',           ROUND(s.qtd_sales_pool, 2),
        'qtd_retention_pool',       ROUND(s.qtd_retention_pool, 2)
      ),
      'weekly_settlement', jsonb_build_object(
        'weekly_sales_pool',     ROUND((SELECT weekly_sales_pool_sum     FROM weekly_pool_totals), 2),
        'weekly_retention_pool', ROUND((SELECT weekly_retention_pool_sum FROM weekly_pool_totals), 2),
        'weekly_bonus_pool',     ROUND((SELECT weekly_bonus_pool_sum     FROM weekly_pool_totals), 2)
      ),
      'weekly_sales_pool',
        ROUND((SELECT weekly_sales_pool_sum     FROM weekly_pool_totals), 2),
      'weekly_retention_pool',
        ROUND((SELECT weekly_retention_pool_sum FROM weekly_pool_totals), 2),
      'carveouts_outside_pool', jsonb_build_object(
        'annual_dollars',    ROUND(v_annual_carveouts, 2),
        'quarterly_dollars', ROUND(v_quarterly_carveouts, 2),
        'weekly_dollars',    ROUND(v_annual_carveouts / 52.0, 2),
        'note',              'Agency-funded team benefits; NOT subtracted from residual bonus pool.',
        'detail',            v_carveouts_result
      ),
      'team_totals', jsonb_build_object(
        'qtd_actual_base_paid',   ROUND(s.qtd_base_paid_total, 2),
        'qtd_base_in_pool',       ROUND(s.qtd_base_in_pool_total, 2),
        'qtd_growth_budget',      ROUND(s.qtd_growth_budget_total, 2),
        'qtd_actual_health',      ROUND(s.qtd_health_total, 2),
        'qtd_actual_commission',  ROUND(s.qtd_actual_commission, 2),
        'qtd_sp_total',           ROUND(s.qtd_sp_total, 2),
        'qtd_sp_sales_only',      ROUND(s.qtd_sp_sales_only, 2),
        'wh_total',               ROUND(s.wh_total, 4)
      ),
      'person_qtd', jsonb_build_object(
        'qtd_actual_base_paid',           ROUND(s.c_qtd_base_paid, 2),
        'qtd_base_in_pool',               ROUND(s.c_qtd_base_in_pool, 2),
        'qtd_growth_budget',              ROUND(s.c_qtd_growth_budget, 2),
        'qtd_actual_health',              ROUND(s.c_qtd_health, 2),
        'qtd_sp',                         ROUND(s.c_qtd_sp, 2),
        'qtd_sales_share',                ROUND(s.qtd_sales_share, 2),
        'qtd_retention_share',            ROUND(s.qtd_retention_share, 2),
        'qtd_bonus_earned',               ROUND(s.qtd_bonus_earned, 2),
        'prior_qtd_bonus_paid',           ROUND(s.c_prior_qtd_bonus, 2),
        'prior_qtd_sales_paid',           ROUND(s.c_prior_qtd_sales, 2),
        'prior_qtd_retention_paid',       ROUND(s.c_prior_qtd_retention, 2),
        'this_week_bonus_settlement',     ROUND(s.this_week_bonus, 2),
        'this_week_sales_settlement',     ROUND(s.this_week_sales_share, 2),
        'this_week_retention_settlement', ROUND(s.this_week_retention_share, 2)
      ),
      'constants', jsonb_build_object(
        'sales_weight',      v_sales_weight,
        'retention_weight',  v_retention_weight,
        'burden_multiplier', v_burden_multiplier,
        'wc_annual',         v_wc_annual
      ),
      'pool_basis',       v_pool_result->'basis',
      'schedule',         v_pool_result->'schedule',
      'carveouts_detail', v_carveouts_result
    )
  FROM settled s
  ORDER BY s.last_name;
END;
$function$;
