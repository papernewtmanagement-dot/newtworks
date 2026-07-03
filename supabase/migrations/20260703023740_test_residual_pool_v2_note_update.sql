CREATE OR REPLACE FUNCTION public.test_residual_pool_v2(
  p_week_end_date date DEFAULT '2026-07-11'::date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_agency_id uuid := '126794dd-25ff-47d2-a436-724499733365'::uuid;
  v_envelope_full jsonb;
  v_envelope_annual numeric;
  v_envelope_weekly numeric;
  v_pool_pct numeric;
  v_phase text;
  v_basis_total numeric;
  v_pc_stripped numeric;
  v_lh_annualized numeric;
  v_smvc_dollars numeric;
  v_scorecard_dollars numeric;
  v_smvc_rate_applied numeric;
  v_strip_factor numeric;
  v_people jsonb;
  v_sum_base numeric;
  v_sum_comm numeric;
  v_sum_bonus_gross numeric;
  v_sum_bonus_net numeric;
  v_sum_health numeric;
  v_sum_sp_pct numeric;
  v_sum_rh_pct numeric;
  v_sum_person_pct numeric;
  v_implied_burden_wc numeric;
BEGIN
  v_envelope_full := compute_pool_basis_and_envelope(v_agency_id, p_week_end_date);
  v_envelope_annual := (v_envelope_full->'envelope'->>'annual_dollars')::numeric;
  v_envelope_weekly := (v_envelope_full->'envelope'->>'weekly_dollars')::numeric;
  v_pool_pct         := (v_envelope_full->'schedule'->>'pool_pct')::numeric;
  v_phase            := (v_envelope_full->'schedule'->>'phase')::text;
  v_basis_total      := (v_envelope_full->'basis'->>'total_basis_annual')::numeric;
  v_pc_stripped      := (v_envelope_full->'basis'->>'pc_stripped_annualized')::numeric;
  v_lh_annualized    := (v_envelope_full->'basis'->>'lh_annualized')::numeric;
  v_smvc_dollars     := (v_envelope_full->'basis'->>'on_time_smvc_dollars')::numeric;
  v_scorecard_dollars := (v_envelope_full->'basis'->>'on_time_scorecard_dollars')::numeric;
  v_smvc_rate_applied := (v_envelope_full->'basis'->>'smvc_rate_pc_applied')::numeric;
  v_strip_factor     := (v_envelope_full->'basis'->>'strip_factor')::numeric;

  SELECT jsonb_agg(row_data ORDER BY total_comp_annual DESC)
  INTO v_people
  FROM (
    SELECT
      jsonb_build_object(
        'name',                     full_name,
        'role',                     role || COALESCE(' / ' || role_level, ''),
        'annual_base',              ROUND(annual_base_salary, 0),
        'annual_commission',        ROUND(annual_commission_projected, 0),
        'sales_points_share_pct',   ROUND(sales_points_share_pct, 2),
        'retention_hours_share_pct', ROUND(retention_hours_share_pct, 2),
        'person_share_pct',         ROUND(person_share_pct, 2),
        'annual_bonus_gross',       ROUND(annual_bonus_gross, 0),
        'annual_health_subtracted', ROUND(annual_health_subtracted, 0),
        'annual_bonus_net',         ROUND(annual_bonus_net, 0),
        'weekly_bonus_net',         ROUND(weekly_bonus_net, 2),
        'annual_total_comp',        ROUND(annual_total_comp, 0),
        'weekly_total_comp',        ROUND(weekly_total_comp, 2)
      ) AS row_data,
      annual_total_comp AS total_comp_annual
    FROM compute_weekly_comp_residual_pool(v_agency_id, p_week_end_date)
  ) sub;

  SELECT
    SUM(annual_base_salary),
    SUM(annual_commission_projected),
    SUM(annual_bonus_gross),
    SUM(annual_bonus_net),
    SUM(annual_health_subtracted),
    SUM(sales_points_share_pct),
    SUM(retention_hours_share_pct),
    SUM(person_share_pct)
  INTO
    v_sum_base, v_sum_comm, v_sum_bonus_gross, v_sum_bonus_net,
    v_sum_health, v_sum_sp_pct, v_sum_rh_pct, v_sum_person_pct
  FROM compute_weekly_comp_residual_pool(v_agency_id, p_week_end_date);

  -- After the 2026-07-02 burden-includes-bonus rebuild:
  -- envelope = (base + comm + bonus_gross) * 1.08 + WC
  -- So envelope − (base + comm + bonus_gross) = burden (on all wages) + WC
  v_implied_burden_wc := v_envelope_annual - (v_sum_base + v_sum_comm + v_sum_bonus_gross);

  RETURN jsonb_build_object(
    'week_end_date', p_week_end_date,
    'envelope_summary', jsonb_build_object(
      'phase',                   v_phase,
      'pool_pct',                v_pool_pct,
      'basis_annual',            ROUND(v_basis_total, 0),
      'envelope_annual',         ROUND(v_envelope_annual, 0),
      'envelope_weekly',         ROUND(v_envelope_weekly, 2),
      'basis_lines', jsonb_build_object(
        'pc_stripped_annualized',  ROUND(v_pc_stripped, 0),
        'lh_annualized',           ROUND(v_lh_annualized, 0),
        'on_time_smvc_dollars',    ROUND(v_smvc_dollars, 0),
        'on_time_scorecard_dollars', ROUND(v_scorecard_dollars, 0),
        'smvc_rate_applied',       v_smvc_rate_applied,
        'strip_factor',            v_strip_factor
      )
    ),
    'per_person', v_people,
    'reconciliation', jsonb_build_object(
      'envelope_annual',           ROUND(v_envelope_annual, 0),
      'sum_base_annual',           ROUND(v_sum_base, 0),
      'sum_commission_annual',     ROUND(v_sum_comm, 0),
      'sum_bonus_gross_annual',    ROUND(v_sum_bonus_gross, 0),
      'sum_health_subtracted',     ROUND(v_sum_health, 0),
      'sum_bonus_net_annual',      ROUND(v_sum_bonus_net, 0),
      'sum_total_paid_annual',     ROUND(v_sum_base + v_sum_comm + v_sum_bonus_net, 0),
      'implied_burden_and_wc',     ROUND(v_implied_burden_wc, 0),
      'expected_burden_and_wc',    ROUND((v_sum_base + v_sum_comm + v_sum_bonus_gross) * 0.08 + 500, 0),
      'sales_points_share_pct_sum', ROUND(v_sum_sp_pct, 2),
      'retention_hours_share_pct_sum', ROUND(v_sum_rh_pct, 2),
      'person_share_pct_sum',      ROUND(v_sum_person_pct, 2),
      'note', 'share sums should each land at 100.00. implied_burden_and_wc = envelope − (base + comm + bonus_gross); should match expected_burden_and_wc = 8% × (base + comm + bonus_gross) + $500 WC.'
    ),
    'computed_at', now()
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.test_residual_pool_v2(date) TO authenticated, service_role;

COMMENT ON FUNCTION public.test_residual_pool_v2(date) IS
'Wrapper test function that runs compute_pool_basis_and_envelope + compute_weekly_comp_residual_pool for the given week and returns everything in one jsonb for eyeball validation. Default week_end_date = 2026-07-11 (residual-pool rollout week). Reconciliation includes expected vs implied burden+WC check after 2026-07-02 burden-includes-bonus rebuild.';