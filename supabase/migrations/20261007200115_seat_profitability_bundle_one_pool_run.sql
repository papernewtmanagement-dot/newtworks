DO $g$ BEGIN
  IF md5(pg_get_functiondef('public.compute_seat_projection(uuid,uuid,date,integer,numeric)'::regprocedure)) <> 'c0a270f5d9e891d313e88624646201b0'
     OR md5(pg_get_functiondef('public.compute_seat_projections_for_agency(uuid,date,integer,numeric)'::regprocedure)) <> '5cd6f479c54573028c07b83efe090a07' THEN
    RAISE EXCEPTION 'seat projection functions changed since read';
  END IF;
END $g$;
DROP FUNCTION public.compute_seat_projections_for_agency(uuid,date,integer,numeric);
DROP FUNCTION public.compute_seat_projection(uuid,uuid,date,integer,numeric);
CREATE OR REPLACE FUNCTION public.compute_seat_projection(p_agency_id uuid, p_team_member_id uuid, p_baseline_date date DEFAULT CURRENT_DATE, p_max_months integer DEFAULT 60, p_override_lapse numeric DEFAULT NULL::numeric, p_retention_hours jsonb DEFAULT NULL::jsonb)
 RETURNS TABLE(team_member_id uuid, baseline_date date, fully_loaded_annual numeric, coverage_bar numeric, profitability_bar numeric, current_attributed_annual numeric, current_coverage_pct numeric, current_profitability_pct numeric, coverage_green_est_date date, coverage_green_est_months integer, profitability_green_est_date date, profitability_green_est_months integer, assumptions jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_fully_loaded         numeric;
  v_coverage_bar         numeric;
  v_profitability_bar    numeric;
  v_own_new_annual       numeric;
  v_retention_pool_share numeric;
  v_current_attributed   numeric;
  v_blended_lapse        numeric;
  v_pc_prem_annual       numeric;
  v_lh_prem_annual       numeric;
  v_role_category        text;
  v_lh_rate              numeric;
  v_pc_rate              CONSTANT numeric := 0.08;
  v_stack_producer_pct   CONSTANT numeric := 0.65;
  v_L                    numeric;
  v_ln_L                 numeric;
  m                      int;
  v_future_date          date;
  v_years_out            numeric;
  v_existing_stack       numeric;
  v_future_stack_factor  numeric;
  v_future_stack         numeric;
  v_attributed           numeric;
  v_coverage_hit         int;
  v_profit_hit           int;
BEGIN
  SELECT
    wt.fully_loaded_annual, wt.coverage_bar, wt.profitability_bar,
    wt.own_new_business_annualized, wt.retention_pool_share_annual,
    wt.attributed_revenue_annual, wt.lapse_rate_used,
    wt.trailing_q_pc_premium * 4, wt.trailing_q_lh_premium * 4,
    wt.role_category
  INTO
    v_fully_loaded, v_coverage_bar, v_profitability_bar,
    v_own_new_annual, v_retention_pool_share, v_current_attributed,
    v_blended_lapse,
    v_pc_prem_annual, v_lh_prem_annual, v_role_category
  FROM public.compute_warning_trigger(p_agency_id, p_baseline_date, p_override_lapse, p_retention_hours) wt
  WHERE wt.team_member_id = p_team_member_id;

  IF v_fully_loaded IS NULL THEN RETURN; END IF;

  SELECT COALESCE(blended_rate_other, 0.09) INTO v_lh_rate
  FROM public.agency WHERE id = p_agency_id;

  v_L := GREATEST(0.01, 1 - v_blended_lapse);
  v_ln_L := LN(v_L);

  IF v_current_attributed >= v_coverage_bar THEN v_coverage_hit := 0; END IF;
  IF v_current_attributed >= v_profitability_bar THEN v_profit_hit := 0; END IF;

  IF v_coverage_hit IS NULL OR v_profit_hit IS NULL THEN
    FOR m IN 1..p_max_months LOOP
      v_future_date := (p_baseline_date + (m || ' months')::interval)::date;
      v_years_out := m::numeric / 12.0;

      SELECT COALESCE(SUM(
        pp.premium_issued *
        CASE WHEN pp.line_of_business IN ('Auto','Fire') THEN v_pc_rate ELSE v_lh_rate END *
        POWER(v_L, ((v_future_date - make_date(pp.period_year, pp.period_month, 15))::numeric / 365.25))
      ), 0)
      INTO v_existing_stack
      FROM public.producer_production pp
      WHERE pp.team_member_id = p_team_member_id
        AND pp.premium_issued > 0
        AND COALESCE(pp.premium_type, 'new_business') = 'new_business'
        AND make_date(pp.period_year, pp.period_month, 15) < v_future_date
        AND ((v_future_date - make_date(pp.period_year, pp.period_month, 15))::numeric / 365.25) >= 1.0;

      IF v_years_out >= 1.0 THEN
        v_future_stack_factor := (POWER(v_L, v_years_out) - v_L) / v_ln_L;
        v_future_stack := v_pc_prem_annual * v_pc_rate * v_future_stack_factor
                        + v_lh_prem_annual * v_lh_rate * v_future_stack_factor;
      ELSE
        v_future_stack := 0;
      END IF;

      v_attributed := v_own_new_annual
                    + (v_existing_stack + v_future_stack) * v_stack_producer_pct
                    + v_retention_pool_share;

      IF v_coverage_hit IS NULL AND v_attributed >= v_coverage_bar THEN v_coverage_hit := m; END IF;
      IF v_profit_hit IS NULL AND v_attributed >= v_profitability_bar THEN v_profit_hit := m; END IF;
      EXIT WHEN v_coverage_hit IS NOT NULL AND v_profit_hit IS NOT NULL;
    END LOOP;
  END IF;

  RETURN QUERY SELECT
    p_team_member_id, p_baseline_date,
    ROUND(v_fully_loaded, 2), ROUND(v_coverage_bar, 2), ROUND(v_profitability_bar, 2),
    ROUND(v_current_attributed, 2),
    CASE WHEN v_coverage_bar > 0 THEN ROUND((v_current_attributed / v_coverage_bar) * 100, 2) ELSE NULL END,
    CASE WHEN v_profitability_bar > 0 THEN ROUND((v_current_attributed / v_profitability_bar) * 100, 2) ELSE NULL END,
    CASE WHEN v_coverage_hit IS NOT NULL THEN (p_baseline_date + (v_coverage_hit || ' months')::interval)::date ELSE NULL END,
    v_coverage_hit,
    CASE WHEN v_profit_hit IS NOT NULL THEN (p_baseline_date + (v_profit_hit || ' months')::interval)::date ELSE NULL END,
    v_profit_hit,
    jsonb_build_object(
      'baseline_date', p_baseline_date,
      'max_months_horizon', p_max_months,
      'role_category', v_role_category,
      'lapse_source', CASE WHEN p_override_lapse IS NOT NULL THEN 'override' ELSE 'actual' END,
      'assumed_lapse_rate', ROUND(v_blended_lapse, 6),
      'survival_rate_L', ROUND(v_L, 6),
      'assumed_new_business_pace_pc_annual', ROUND(v_pc_prem_annual, 2),
      'assumed_new_business_pace_lh_annual', ROUND(v_lh_prem_annual, 2),
      'assumed_retention_pool_share_annual', ROUND(v_retention_pool_share, 2)
    );
END;
$function$;
CREATE OR REPLACE FUNCTION public.compute_seat_projections_for_agency(p_agency_id uuid, p_baseline_date date DEFAULT CURRENT_DATE, p_max_months integer DEFAULT 60, p_override_lapse numeric DEFAULT NULL::numeric, p_retention_hours jsonb DEFAULT NULL::jsonb)
 RETURNS TABLE(team_member_id uuid, full_name text, role text, role_category text, baseline_date date, fully_loaded_annual numeric, coverage_bar numeric, profitability_bar numeric, current_attributed_annual numeric, current_coverage_pct numeric, current_profitability_pct numeric, coverage_green_est_date date, coverage_green_est_months integer, profitability_green_est_date date, profitability_green_est_months integer, assumptions jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
  RETURN QUERY
  SELECT
    wt.team_member_id, wt.full_name, wt.role, wt.role_category,
    sp.baseline_date,
    sp.fully_loaded_annual, sp.coverage_bar, sp.profitability_bar,
    sp.current_attributed_annual, sp.current_coverage_pct, sp.current_profitability_pct,
    sp.coverage_green_est_date, sp.coverage_green_est_months,
    sp.profitability_green_est_date, sp.profitability_green_est_months,
    sp.assumptions
  FROM public.compute_warning_trigger(p_agency_id, p_baseline_date, p_override_lapse, p_retention_hours) wt
  CROSS JOIN LATERAL public.compute_seat_projection(p_agency_id, wt.team_member_id, p_baseline_date, p_max_months, p_override_lapse, p_retention_hours) sp
  ORDER BY wt.full_name;
END;
$function$;
CREATE OR REPLACE FUNCTION public.get_seat_profitability_bundle(p_agency_id uuid, p_week_end_date date, p_lapse_a numeric, p_lapse_b numeric, p_max_months integer DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
-- Team page seat profitability in one call (2026-10-07). Runs the bonus pool ONCE and hands its
-- retention hours to every warning-trigger and seat-projection call. The page used to fire six
-- calls that each re-ran the pool and all hit the 8 s timeout. Pure wrapper: no math lives here.
DECLARE
  v_hours jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(jsonb_build_object('team_member_id', x.team_member_id, 'role_category', x.role_category,
                                               'weighted_hours_at_40', x.weighted_hours_at_40)), '[]'::jsonb)
    INTO v_hours
  FROM public.compute_weekly_comp_residual_pool(p_agency_id, p_week_end_date) x;

  RETURN jsonb_build_object(
    'rows',          (SELECT COALESCE(jsonb_agg(to_jsonb(w)), '[]'::jsonb) FROM public.compute_warning_trigger(p_agency_id, p_week_end_date, NULL, v_hours) w),
    'projections',   (SELECT COALESCE(jsonb_agg(to_jsonb(s)), '[]'::jsonb) FROM public.compute_seat_projections_for_agency(p_agency_id, p_week_end_date, p_max_months, NULL, v_hours) s),
    'rows_a',        (SELECT COALESCE(jsonb_agg(to_jsonb(w)), '[]'::jsonb) FROM public.compute_warning_trigger(p_agency_id, p_week_end_date, p_lapse_a, v_hours) w),
    'projections_a', (SELECT COALESCE(jsonb_agg(to_jsonb(s)), '[]'::jsonb) FROM public.compute_seat_projections_for_agency(p_agency_id, p_week_end_date, p_max_months, p_lapse_a, v_hours) s),
    'rows_b',        (SELECT COALESCE(jsonb_agg(to_jsonb(w)), '[]'::jsonb) FROM public.compute_warning_trigger(p_agency_id, p_week_end_date, p_lapse_b, v_hours) w),
    'projections_b', (SELECT COALESCE(jsonb_agg(to_jsonb(s)), '[]'::jsonb) FROM public.compute_seat_projections_for_agency(p_agency_id, p_week_end_date, p_max_months, p_lapse_b, v_hours) s)
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.get_seat_profitability_bundle(uuid,date,numeric,numeric,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_seat_profitability_bundle(uuid,date,numeric,numeric,integer) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.compute_seat_projection(uuid,uuid,date,integer,numeric,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.compute_seat_projection(uuid,uuid,date,integer,numeric,jsonb) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.compute_seat_projections_for_agency(uuid,date,integer,numeric,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.compute_seat_projections_for_agency(uuid,date,integer,numeric,jsonb) TO authenticated, service_role;

