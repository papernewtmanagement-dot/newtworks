-- Compute weekly marketing bonus pool + per-person on-time earned
-- Marketing envelope = 10% × (on-time annual revenue − on-time Scorecard). AIPP not in basis.
-- Pool = 50% × YTD underspend. Split by share of marketing_points YTD.
-- Cadence mirrors residual comp pool: YTD-accumulating, weekly on-time settlement.
-- Envelope lookup by account_name '0003 MARKETING' (account_code in flux QBO->COA).
CREATE OR REPLACE FUNCTION public.compute_weekly_marketing_bonus(
  p_agency_id UUID,
  p_week_end_date DATE DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_week_end DATE;
  v_year INT;
  v_year_start DATE;
  v_weeks_elapsed NUMERIC;
  v_pool_basis JSONB;
  v_total_basis NUMERIC;
  v_scorecard_ontime NUMERIC;
  v_basis_ex_scorecard NUMERIC;
  v_envelope_annual NUMERIC;
  v_envelope_weekly NUMERIC;
  v_envelope_ytd NUMERIC;
  v_spend_ytd NUMERIC;
  v_underspend_ytd NUMERIC;
  v_pool_ytd NUMERIC;
  v_total_points_ytd NUMERIC;
  v_people JSONB;
  v_result JSONB;
  v_mktg_root_id UUID;
BEGIN
  v_week_end := COALESCE(
    p_week_end_date,
    (CURRENT_DATE + ((6 - EXTRACT(DOW FROM CURRENT_DATE)::int + 7) % 7))::date
  );
  v_year := EXTRACT(YEAR FROM v_week_end)::int;
  v_year_start := make_date(v_year, 1, 1);
  v_weeks_elapsed := CEIL(EXTRACT(DOY FROM v_week_end)::numeric / 7.0);

  v_pool_basis := public.compute_pool_basis_and_envelope(p_agency_id, v_week_end);
  v_total_basis := COALESCE((v_pool_basis->'basis'->>'total_basis_annual')::numeric, 0);
  v_scorecard_ontime := COALESCE((v_pool_basis->'basis'->>'on_time_scorecard_dollars')::numeric, 0);
  v_basis_ex_scorecard := v_total_basis - v_scorecard_ontime;

  v_envelope_annual := ROUND(v_basis_ex_scorecard * 0.10, 2);
  v_envelope_weekly := ROUND(v_envelope_annual / 52.0, 2);
  v_envelope_ytd    := ROUND(v_envelope_annual * v_weeks_elapsed / 52.0, 2);

  SELECT id INTO v_mktg_root_id
  FROM public.chart_of_accounts
  WHERE agency_id = p_agency_id
    AND account_name = '0003 MARKETING'
  LIMIT 1;

  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_spend_ytd
  FROM public.chart_of_accounts coa
  JOIN public.journal_lines   jl ON jl.account_id = coa.id
  JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  WHERE coa.agency_id = p_agency_id
    AND (coa.id = v_mktg_root_id OR coa.parent_account_id = v_mktg_root_id)
    AND je.agency_id = p_agency_id
    AND je.entry_date >= v_year_start
    AND je.entry_date <= v_week_end;

  v_spend_ytd := ROUND(COALESCE(v_spend_ytd, 0), 2);

  v_underspend_ytd := GREATEST(0, v_envelope_ytd - v_spend_ytd);
  v_pool_ytd       := ROUND(v_underspend_ytd * 0.50, 2);

  SELECT COALESCE(SUM(points), 0)
  INTO v_total_points_ytd
  FROM public.marketing_points
  WHERE agency_id = p_agency_id
    AND week_end_date >= v_year_start
    AND week_end_date <= v_week_end;

  WITH person_points AS (
    SELECT
      team_member_id,
      SUM(points)                  AS points_ytd,
      SUM(points_reviews)          AS reviews_ytd,
      SUM(points_referrals_quoted) AS quoted_ytd,
      SUM(points_referrals_sold)   AS sold_ytd
    FROM public.marketing_points
    WHERE agency_id = p_agency_id
      AND week_end_date >= v_year_start
      AND week_end_date <= v_week_end
    GROUP BY team_member_id
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'team_member_id', t.id,
      'name',           t.first_name || ' ' || COALESCE(t.last_name, ''),
      'points_ytd',     COALESCE(pp.points_ytd, 0),
      'reviews_ytd',    COALESCE(pp.reviews_ytd, 0),
      'quoted_ytd',     COALESCE(pp.quoted_ytd, 0),
      'sold_ytd',       COALESCE(pp.sold_ytd, 0),
      'share_pct',      CASE WHEN v_total_points_ytd > 0
                             THEN ROUND(COALESCE(pp.points_ytd, 0) / v_total_points_ytd * 100.0, 2)
                             ELSE 0 END,
      'earned_ytd',     CASE WHEN v_total_points_ytd > 0
                             THEN ROUND(COALESCE(pp.points_ytd, 0) / v_total_points_ytd * v_pool_ytd, 2)
                             ELSE 0 END
    )
    ORDER BY COALESCE(pp.points_ytd, 0) DESC, t.first_name
  )
  INTO v_people
  FROM public.team t
  LEFT JOIN person_points pp ON pp.team_member_id = t.id
  WHERE t.agency_id = p_agency_id
    AND t.is_active = true
    AND COALESCE(t.is_admin_backoffice, false) = false
    AND t.archived_at IS NULL
    AND COALESCE(t.is_test_user, false) = false
    AND (t.role_level IS NULL OR t.role_level != 'Owner')
    AND t.category = 'agency';

  v_result := jsonb_build_object(
    'agency_id',      p_agency_id,
    'week_end_date',  v_week_end,
    'year',           v_year,
    'weeks_elapsed',  v_weeks_elapsed,
    'basis', jsonb_build_object(
      'total_basis_annual',        v_total_basis,
      'scorecard_ontime_excluded', v_scorecard_ontime,
      'basis_ex_scorecard_annual', v_basis_ex_scorecard,
      'source', 'compute_pool_basis_and_envelope minus on_time_scorecard_dollars (AIPP not in basis)'
    ),
    'envelope', jsonb_build_object(
      'annual',       v_envelope_annual,
      'weekly',       v_envelope_weekly,
      'ytd_target',   v_envelope_ytd,
      'pct_of_basis', 0.10
    ),
    'spend', jsonb_build_object(
      'ytd',                v_spend_ytd,
      'root_account_id',    v_mktg_root_id,
      'source',             '0003 MARKETING envelope by account_name + descendants'
    ),
    'pool', jsonb_build_object(
      'underspend_ytd',   v_underspend_ytd,
      'team_share_pct',   0.50,
      'pool_ytd',         v_pool_ytd,
      'total_points_ytd', v_total_points_ytd
    ),
    'people',       COALESCE(v_people, '[]'::jsonb),
    'computed_at',  NOW()
  );

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.compute_weekly_marketing_bonus(UUID, DATE) TO anon, authenticated;

COMMENT ON FUNCTION public.compute_weekly_marketing_bonus(UUID, DATE) IS
  'Weekly on-time marketing bonus pool computation. '
  'Envelope = 10% of on-time annual revenue excluding Scorecard (AIPP is not in the basis to begin with). '
  'Underspend YTD × 50% = pool. Distributed by share of marketing_points YTD. '
  'Mirrors residual comp pool cadence: YTD-accumulating, weekly on-time delivery.';
