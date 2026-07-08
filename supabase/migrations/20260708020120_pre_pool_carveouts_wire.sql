-- Pre-pool carve-out SQL wire: Manager Bonus + MVP Prize Cart + WtQ Trip
-- Decision locked 2026-07-06, wired 2026-07-07
-- See operational_rule "Residual pool carve-outs — Manager Bonus, MVP prize cart, WtQ trip all pre-pool (locked 2026-07-06)"

-- New function: compute_pool_carveouts
CREATE OR REPLACE FUNCTION public.compute_pool_carveouts(p_agency_id uuid, p_week_end_date date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_pool_result         jsonb;
  v_annual_ot_smvc      numeric;
  v_annual_ot_scorecard numeric;
  v_annual_ot_basis     numeric;

  v_annual_manager_bonus numeric := 0;
  v_manager_detail      jsonb := '[]'::jsonb;

  v_curr_cycle          record;
  v_curr_cycle_start    date;
  v_curr_cycle_end      date;
  v_prior_cycle_start   date;
  v_prior_cycle_end     date;
  v_week_of_cycle       int;
  v_curr_qtr_wins       int := 0;
  v_prior_qtr_wins      int := 0;
  v_max_possible_wins   int;

  v_annual_mvp          numeric := 0;
  v_annual_wtq          numeric := 0;
  v_wtq_halted          boolean := false;
  v_wtq_halt_reason     text := NULL;

  v_total_carveouts     numeric;
BEGIN
  v_pool_result         := public.compute_pool_basis_and_envelope(p_agency_id, p_week_end_date);
  v_annual_ot_smvc      := COALESCE(NULLIF(v_pool_result->'basis'->>'on_time_smvc_dollars','')::numeric, 0);
  v_annual_ot_scorecard := COALESCE(NULLIF(v_pool_result->'basis'->>'on_time_scorecard_dollars','')::numeric, 0);
  v_annual_ot_basis     := v_annual_ot_smvc + v_annual_ot_scorecard;

  SELECT
    COALESCE(SUM(
      CASE t.role_level
        WHEN 'Unit Manager'    THEN 0.001
        WHEN 'Section Manager' THEN 0.002
        WHEN 'Office Manager'  THEN 0.003
        ELSE 0
      END * 52.0 * v_annual_ot_scorecard
    ), 0),
    COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id', t.id,
      'name', t.first_name || ' ' || t.last_name,
      'role_level', t.role_level,
      'weekly_rate_pct', CASE t.role_level
                          WHEN 'Unit Manager'    THEN 0.1
                          WHEN 'Section Manager' THEN 0.2
                          WHEN 'Office Manager'  THEN 0.3
                          ELSE 0 END,
      'weekly_bonus_dollars', ROUND(
        CASE t.role_level
          WHEN 'Unit Manager'    THEN 0.001
          WHEN 'Section Manager' THEN 0.002
          WHEN 'Office Manager'  THEN 0.003
          ELSE 0 END * v_annual_ot_scorecard, 2),
      'annual_bonus_dollars', ROUND(
        CASE t.role_level
          WHEN 'Unit Manager'    THEN 0.001
          WHEN 'Section Manager' THEN 0.002
          WHEN 'Office Manager'  THEN 0.003
          ELSE 0 END * v_annual_ot_scorecard * 52.0, 2)
    )), '[]'::jsonb)
  INTO v_annual_manager_bonus, v_manager_detail
  FROM public.team t
  WHERE t.agency_id = p_agency_id
    AND t.is_active = true
    AND t.archived_at IS NULL
    AND t.is_admin_backoffice = false
    AND t.role_level IN ('Unit Manager','Section Manager','Office Manager');

  SELECT * INTO v_curr_cycle FROM public.current_cycle_info(p_agency_id, p_week_end_date);
  v_curr_cycle_start  := v_curr_cycle.cycle_start;
  v_curr_cycle_end    := v_curr_cycle.cycle_end;
  v_week_of_cycle     := v_curr_cycle.week_of_cycle;
  v_prior_cycle_start := (v_curr_cycle_start - INTERVAL '91 days')::date;
  v_prior_cycle_end   := (v_curr_cycle_start - INTERVAL '1 day')::date;

  SELECT COUNT(*) INTO v_curr_qtr_wins
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id
    AND week_ending_date >= v_curr_cycle_start
    AND week_ending_date <= LEAST(v_curr_cycle_end, p_week_end_date)
    AND won_the_week = true;

  SELECT COUNT(*) INTO v_prior_qtr_wins
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id
    AND week_ending_date >= v_prior_cycle_start
    AND week_ending_date <= v_prior_cycle_end
    AND won_the_week = true;

  v_annual_mvp := 0.01 * v_annual_ot_basis * (v_prior_qtr_wins::numeric / 13.0);

  v_max_possible_wins := v_curr_qtr_wins + GREATEST(0, 13 - v_week_of_cycle);
  IF v_max_possible_wins < 9 THEN
    v_annual_wtq      := 0;
    v_wtq_halted      := true;
    v_wtq_halt_reason := format(
      'wins_to_date (%s) + weeks_remaining (%s) = %s < 9 floor',
      v_curr_qtr_wins, GREATEST(0, 13 - v_week_of_cycle), v_max_possible_wins
    );
  ELSE
    v_annual_wtq := 0.10 * v_annual_ot_basis * (v_curr_qtr_wins::numeric / 13.0);
  END IF;

  v_total_carveouts := v_annual_manager_bonus + v_annual_mvp + v_annual_wtq;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id,
    'week_end_date', p_week_end_date,
    'inputs', jsonb_build_object(
      'annual_ot_smvc',              ROUND(v_annual_ot_smvc, 2),
      'annual_ot_scorecard',         ROUND(v_annual_ot_scorecard, 2),
      'annual_ot_basis',             ROUND(v_annual_ot_basis, 2),
      'current_cycle_start',         v_curr_cycle_start,
      'current_cycle_end',           v_curr_cycle_end,
      'week_of_cycle',               v_week_of_cycle,
      'current_cycle_wins_to_date',  v_curr_qtr_wins,
      'max_possible_wins_this_cycle', v_max_possible_wins,
      'prior_cycle_start',           v_prior_cycle_start,
      'prior_cycle_end',             v_prior_cycle_end,
      'prior_cycle_wins',            v_prior_qtr_wins
    ),
    'manager_bonus', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_manager_bonus, 2),
      'weekly_dollars', ROUND(v_annual_manager_bonus / 52.0, 2),
      'detail',         v_manager_detail
    ),
    'mvp_prize_cart', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_mvp, 2),
      'weekly_dollars', ROUND(v_annual_mvp / 52.0, 2),
      'formula',        '1% × annual OT (SMVC+Scorecard) × prior_qtr_wins/13',
      'note',           'MVP prize cart restock funded from prior quarter wins'
    ),
    'wtq_trip', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_wtq, 2),
      'weekly_dollars', ROUND(v_annual_wtq / 52.0, 2),
      'formula',        '10% × annual OT (SMVC+Scorecard) × curr_qtr_wins/13',
      'floor_wins',     9,
      'halted',         v_wtq_halted,
      'halt_reason',    v_wtq_halt_reason,
      'note',           'Accrues weekly. Halts if math cannot reach 9-wins floor (dollars stay in pool).'
    ),
    'total_annual_carveouts', ROUND(v_total_carveouts, 2),
    'total_weekly_carveouts', ROUND(v_total_carveouts / 52.0, 2),
    'computed_at', now()
  );
END;
$function$;

-- Update compute_weekly_comp_residual_pool to subtract carveouts from bonus pool
CREATE OR REPLACE FUNCTION public.compute_weekly_comp_residual_pool(p_agency_id uuid, p_week_end_date date)
 RETURNS TABLE(team_member_id uuid, full_name text, role text, role_category text, role_level text, annual_base_salary numeric, weekly_base_salary numeric, annual_commission_projected numeric, weekly_commission_projected numeric, ytd_sales_points numeric, sales_points_share_pct numeric, weighted_hours_at_40 numeric, retention_hours_share_pct numeric, person_share_pct numeric, annual_bonus_gross numeric, annual_health_subtracted numeric, annual_bonus_net numeric, weekly_bonus_net numeric, annual_total_comp numeric, weekly_total_comp numeric, diagnostics jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_year               int := EXTRACT(YEAR FROM p_week_end_date)::int;
  v_pool_result        jsonb;
  v_carveouts_result   jsonb;
  v_annual_envelope    numeric;
  v_annual_carveouts   numeric;
  v_burden_multiplier  CONSTANT numeric := 0.08;
  v_wc_annual          CONSTANT numeric := 500.00;
BEGIN
  v_pool_result      := public.compute_pool_basis_and_envelope(p_agency_id, p_week_end_date);
  v_carveouts_result := public.compute_pool_carveouts(p_agency_id, p_week_end_date);
  v_annual_envelope  := COALESCE(NULLIF(v_pool_result->'envelope'->>'annual_dollars','')::numeric, 0);
  v_annual_carveouts := COALESCE(NULLIF(v_carveouts_result->>'total_annual_carveouts','')::numeric, 0);

  RETURN QUERY
  WITH roster AS (
    SELECT t.id, t.first_name, t.last_name, t.role, t.role_category, t.role_level,
           t.pay_type, t.pay_rate, t.work_location, t.start_date,
           t.license_pc, t.license_lh, t.license_ips,
           t.weekly_health_benefit_agency_paid
    FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND t.category = 'agency'
      AND t.is_admin_backoffice = false
      AND COALESCE(t.role_level, '') <> 'Owner'
      AND t.is_active = true
  ),
  base_calc AS (
    SELECT r.*,
      CASE
        WHEN r.pay_type = 'SALARY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 52
        WHEN r.pay_type = 'HOURLY' AND r.pay_rate IS NOT NULL THEN r.pay_rate * 40 * 52
        ELSE 0
      END AS c_annual_base,
      LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - r.start_date)::numeric / 7.0) / 52.0)) AS c_base_tenure_mult
    FROM roster r
  ),
  q_commissions AS (
    SELECT b.id AS tm_id, q,
      (public.compute_person_commissions_quarterly(p_agency_id, b.id, v_year, q)->'commission'->>'total_commission')::numeric AS q_comm
    FROM base_calc b
    CROSS JOIN generate_series(1, 4) AS q
  ),
  quarter_realized AS (
    SELECT
      ((period_month - 1) / 3) + 1 AS q,
      MAX(period_month) IS NOT NULL AS is_realized
    FROM public.producer_production
    WHERE agency_id = p_agency_id AND period_year = v_year
    GROUP BY ((period_month - 1) / 3) + 1
  ),
  q_annotated AS (
    SELECT qc.tm_id, qc.q, qc.q_comm,
      COALESCE(qr.is_realized, false) AS is_realized
    FROM q_commissions qc
    LEFT JOIN quarter_realized qr ON qr.q = qc.q
  ),
  comm_projection AS (
    SELECT tm_id,
      SUM(CASE WHEN is_realized THEN q_comm ELSE 0 END) AS realized_comm_sum,
      COUNT(*) FILTER (WHERE is_realized) AS realized_count,
      COUNT(*) FILTER (WHERE NOT is_realized) AS unrealized_count,
      CASE WHEN COUNT(*) FILTER (WHERE is_realized) > 0
        THEN SUM(CASE WHEN is_realized THEN q_comm ELSE 0 END) / COUNT(*) FILTER (WHERE is_realized)
        ELSE 0
      END AS avg_realized_comm
    FROM q_annotated
    GROUP BY tm_id
  ),
  comm_annualized AS (
    SELECT cp.tm_id,
      cp.realized_comm_sum + (cp.avg_realized_comm * cp.unrealized_count) AS c_annual_comm,
      cp.realized_comm_sum, cp.avg_realized_comm, cp.realized_count, cp.unrealized_count
    FROM comm_projection cp
  ),
  quarter_bounds AS (
    SELECT
      q,
      make_date(v_year, ((q - 1) * 3) + 1, 1)::date AS q_start,
      (make_date(v_year, q * 3, 1) + INTERVAL '1 month - 1 day')::date AS q_end
    FROM generate_series(1, 4) AS q
  ),
  q_sp AS (
    SELECT
      wctd.team_member_id AS tm_id,
      qb.q,
      MAX(COALESCE(wctd.sales_points, 0)) AS q_max_sp
    FROM base_calc b
    CROSS JOIN quarter_bounds qb
    LEFT JOIN public.weekly_cpr_reports wr
      ON wr.agency_id = p_agency_id
     AND wr.week_ending_date >= qb.q_start
     AND wr.week_ending_date <= qb.q_end
     AND wr.week_ending_date <= p_week_end_date
    LEFT JOIN public.weekly_cpr_team_detail wctd
      ON wctd.weekly_cpr_report_id = wr.id
     AND wctd.team_member_id = b.id
    GROUP BY wctd.team_member_id, qb.q
  ),
  sp_annotated AS (
    SELECT qs.tm_id, qs.q, qs.q_max_sp,
      COALESCE(qr.is_realized, false) AS is_realized
    FROM q_sp qs
    LEFT JOIN quarter_realized qr ON qr.q = qs.q
    WHERE qs.tm_id IS NOT NULL
  ),
  sp_projection AS (
    SELECT tm_id,
      SUM(CASE WHEN is_realized THEN q_max_sp ELSE 0 END) AS realized_sp_sum,
      COUNT(*) FILTER (WHERE is_realized) AS realized_count,
      COUNT(*) FILTER (WHERE NOT is_realized) AS unrealized_count,
      CASE WHEN COUNT(*) FILTER (WHERE is_realized) > 0
        THEN SUM(CASE WHEN is_realized THEN q_max_sp ELSE 0 END) / COUNT(*) FILTER (WHERE is_realized)
        ELSE 0
      END AS avg_realized_sp
    FROM sp_annotated
    GROUP BY tm_id
  ),
  sp_annualized AS (
    SELECT sp.tm_id,
      sp.realized_sp_sum + (sp.avg_realized_sp * sp.unrealized_count) AS c_annual_sp
    FROM sp_projection sp
  ),
  wh_calc AS (
    SELECT b.id AS tm_id,
      40.0 AS hours,
      CASE WHEN b.role = 'Reception' THEN 1.00
           WHEN b.role IN ('Acquisition', 'Inside Sales') THEN 0.25
           ELSE 0 END AS role_w,
      CASE WHEN b.work_location = 'in_office' THEN 1.00
           WHEN b.work_location = 'remote' THEN 0.75
           ELSE 1.00 END AS location_w,
      LEAST(1.00, GREATEST(0, FLOOR((p_week_end_date - b.start_date)::numeric / 7.0) / 52.0)) AS tenure_w,
      LEAST(1.00, 0.50
           + CASE WHEN b.license_pc  THEN 0.35 ELSE 0 END
           + CASE WHEN b.license_lh  THEN 0.10 ELSE 0 END
           + CASE WHEN b.license_ips THEN 0.05 ELSE 0 END) AS license_w
    FROM base_calc b
  ),
  wh_final AS (
    SELECT wh.tm_id,
      wh.hours * wh.role_w * wh.location_w * wh.tenure_w * wh.license_w AS weighted_hours,
      wh.role_w, wh.location_w, wh.tenure_w, wh.license_w
    FROM wh_calc wh
  ),
  combined AS (
    SELECT b.id AS tm_id, b.first_name, b.last_name, b.role, b.role_category, b.role_level,
      b.c_annual_base, b.c_base_tenure_mult, b.weekly_health_benefit_agency_paid,
      (b.c_annual_base * b.c_base_tenure_mult) AS c_annual_base_in_envelope,
      (b.c_annual_base * (1 + v_burden_multiplier) * (1 - b.c_base_tenure_mult)) AS c_annual_growth_budget,
      COALESCE(ca.c_annual_comm, 0) AS c_annual_comm,
      COALESCE(spa.c_annual_sp, 0) AS c_annual_sp,
      COALESCE(wf.weighted_hours, 0) AS weighted_hours,
      ca.realized_comm_sum, ca.avg_realized_comm, ca.realized_count AS comm_realized_q,
      ca.unrealized_count AS comm_unrealized_q,
      wf.role_w, wf.location_w, wf.tenure_w, wf.license_w
    FROM base_calc b
    LEFT JOIN comm_annualized ca ON ca.tm_id = b.id
    LEFT JOIN sp_annualized spa  ON spa.tm_id = b.id
    LEFT JOIN wh_final wf        ON wf.tm_id = b.id
  ),
  team_totals AS (
    SELECT
      SUM(c_annual_base) AS total_base,
      SUM(c_annual_base_in_envelope) AS total_base_in_envelope,
      SUM(c_annual_growth_budget) AS total_growth_budget,
      SUM(c_annual_comm) AS total_comm,
      SUM(c_annual_sp)   AS total_sp,
      SUM(weighted_hours) AS total_wh
    FROM combined
  ),
  bonus_pool_calc AS (
    SELECT
      tt.total_base, tt.total_base_in_envelope, tt.total_growth_budget,
      tt.total_comm, tt.total_sp, tt.total_wh,
      v_annual_envelope AS envelope,
      v_annual_carveouts AS carveouts,
      v_wc_annual AS wc,
      GREATEST(0,
        (v_annual_envelope - v_wc_annual) / (1 + v_burden_multiplier)
        - tt.total_base_in_envelope
        - tt.total_comm
      ) AS annual_bonus_pool_gross,
      GREATEST(0,
        (v_annual_envelope - v_wc_annual) / (1 + v_burden_multiplier)
        - tt.total_base_in_envelope
        - tt.total_comm
        - v_annual_carveouts
      ) AS annual_bonus_pool
    FROM team_totals tt
  ),
  bonus_pool AS (
    SELECT
      bpc.*,
      (bpc.total_base_in_envelope + bpc.total_comm + bpc.annual_bonus_pool + bpc.carveouts) * v_burden_multiplier AS burden
    FROM bonus_pool_calc bpc
  ),
  distributed AS (
    SELECT c.*,
      bp.annual_bonus_pool, bp.annual_bonus_pool_gross, bp.carveouts,
      bp.total_sp AS bp_total_sp, bp.total_wh AS bp_total_wh,
      bp.total_growth_budget AS bp_total_growth_budget,
      CASE WHEN bp.total_sp > 0 THEN c.c_annual_sp / bp.total_sp ELSE 0 END AS sp_share,
      CASE WHEN bp.total_wh > 0 THEN c.weighted_hours / bp.total_wh ELSE 0 END AS wh_share
    FROM combined c CROSS JOIN bonus_pool bp
  ),
  final AS (
    SELECT d.*,
      (0.65 * d.sp_share + 0.35 * d.wh_share) AS person_share,
      (0.65 * d.sp_share + 0.35 * d.wh_share) * d.annual_bonus_pool AS annual_bonus_gross,
      COALESCE(d.weekly_health_benefit_agency_paid, 0) * 52 AS annual_health_subtract,
      GREATEST(0,
        (0.65 * d.sp_share + 0.35 * d.wh_share) * d.annual_bonus_pool
        - (COALESCE(d.weekly_health_benefit_agency_paid, 0) * 52)
      ) AS annual_bonus_net
    FROM distributed d
  )
  SELECT
    f.tm_id,
    f.first_name || ' ' || f.last_name,
    f.role,
    f.role_category,
    f.role_level,
    ROUND(f.c_annual_base, 2),
    ROUND(f.c_annual_base / 52.0, 2),
    ROUND(f.c_annual_comm, 2),
    ROUND(f.c_annual_comm / 52.0, 2),
    ROUND(f.c_annual_sp, 2),
    ROUND(f.sp_share * 100, 4),
    ROUND(f.weighted_hours, 4),
    ROUND(f.wh_share * 100, 4),
    ROUND(f.person_share * 100, 4),
    ROUND(f.annual_bonus_gross, 2),
    ROUND(f.annual_health_subtract, 2),
    ROUND(f.annual_bonus_net, 2),
    ROUND(f.annual_bonus_net / 52.0, 2),
    ROUND(f.c_annual_base + f.c_annual_comm + f.annual_bonus_net, 2),
    ROUND((f.c_annual_base + f.c_annual_comm + f.annual_bonus_net) / 52.0, 2),
    jsonb_build_object(
      'realized_comm_sum',    f.realized_comm_sum,
      'avg_realized_comm',    f.avg_realized_comm,
      'comm_realized_q',      f.comm_realized_q,
      'comm_unrealized_q',    f.comm_unrealized_q,
      'weight_factors',       jsonb_build_object(
                                'hours_baseline', 40.0,
                                'role_w', f.role_w,
                                'location_w', f.location_w,
                                'tenure_w', f.tenure_w,
                                'license_w', f.license_w),
      'base_tenure_mult',     f.c_base_tenure_mult,
      'annual_base_in_envelope', ROUND(f.c_annual_base_in_envelope, 2),
      'annual_growth_budget', ROUND(f.c_annual_growth_budget, 2),
      'weekly_growth_budget', ROUND(f.c_annual_growth_budget / 52.0, 2),
      'annual_envelope',      v_annual_envelope,
      'annual_bonus_pool',    f.annual_bonus_pool,
      'annual_bonus_pool_gross', f.annual_bonus_pool_gross,
      'annual_carveouts',     f.carveouts,
      'team_total_base',      (SELECT total_base FROM team_totals),
      'team_total_base_in_envelope', (SELECT total_base_in_envelope FROM team_totals),
      'team_total_growth_budget',    (SELECT total_growth_budget FROM team_totals),
      'team_total_comm',      (SELECT total_comm FROM team_totals),
      'team_total_burden',    (SELECT burden FROM bonus_pool),
      'team_wc_annual',       v_wc_annual,
      'burden_note',          'burden = 8% of (base_in_envelope + comm + bonus_pool + carveouts). Pool now net of pre-pool carveouts.',
      'pool_basis',           v_pool_result->'basis',
      'schedule',             v_pool_result->'schedule',
      'carveouts_detail',     v_carveouts_result
    )
  FROM final f
  ORDER BY f.last_name;
END;
$function$;

-- Update get_current_bonus_pool to surface carveouts
CREATE OR REPLACE FUNCTION public.get_current_bonus_pool(p_agency_id uuid, p_week_end_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_target_date  date;
  v_diag         jsonb;
  v_schedule_pct numeric;
BEGIN
  IF p_week_end_date IS NULL THEN
    v_target_date := CURRENT_DATE + ((6 - EXTRACT(DOW FROM CURRENT_DATE)::int + 7) % 7);
    IF NOT EXISTS (
      SELECT 1 FROM public.team_comp_pool_schedule
      WHERE agency_id = p_agency_id AND week_end_date = v_target_date
    ) THEN
      SELECT MIN(week_end_date) INTO v_target_date
      FROM public.team_comp_pool_schedule
      WHERE agency_id = p_agency_id AND week_end_date >= CURRENT_DATE;
    END IF;
  ELSE
    v_target_date := p_week_end_date;
  END IF;

  SELECT pool_pct INTO v_schedule_pct
  FROM public.team_comp_pool_schedule
  WHERE agency_id = p_agency_id AND week_end_date = v_target_date;

  IF v_schedule_pct IS NULL THEN
    RETURN jsonb_build_object(
      'agency_id',     p_agency_id,
      'week_end_date', v_target_date,
      'error',         format('no team_comp_pool_schedule row for week ending %s', v_target_date),
      'computed_at',   now()
    );
  END IF;

  SELECT diagnostics INTO v_diag
  FROM public.compute_weekly_comp_residual_pool(p_agency_id, v_target_date)
  LIMIT 1;

  IF v_diag IS NULL THEN
    RETURN jsonb_build_object(
      'agency_id',     p_agency_id,
      'week_end_date', v_target_date,
      'error',         'no roster rows returned - check active team',
      'computed_at',   now()
    );
  END IF;

  RETURN jsonb_build_object(
    'agency_id',              p_agency_id,
    'week_end_date',          v_target_date,
    'annual_envelope',        (v_diag->>'annual_envelope')::numeric,
    'annual_bonus_pool_gross',(v_diag->>'annual_bonus_pool_gross')::numeric,
    'annual_carveouts',       (v_diag->>'annual_carveouts')::numeric,
    'annual_bonus_pool',      ROUND((v_diag->>'annual_bonus_pool')::numeric, 2),
    'weekly_bonus_pool',      ROUND((v_diag->>'annual_bonus_pool')::numeric / 52.0, 2),
    'team_total_base',        (v_diag->>'team_total_base')::numeric,
    'team_total_base_in_envelope', (v_diag->>'team_total_base_in_envelope')::numeric,
    'team_total_growth_budget',    (v_diag->>'team_total_growth_budget')::numeric,
    'team_total_comm',        ROUND((v_diag->>'team_total_comm')::numeric, 2),
    'team_total_burden',      ROUND((v_diag->>'team_total_burden')::numeric, 2),
    'pool_basis',             v_diag->'pool_basis',
    'schedule',               v_diag->'schedule',
    'carveouts_detail',       v_diag->'carveouts_detail',
    'computed_at',            now()
  );
END;
$function$;
