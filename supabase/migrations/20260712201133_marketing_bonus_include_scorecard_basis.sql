-- Envelope basis now includes on-time Scorecard (Peter 2026-07-12: don't remove scorecard).
-- basis_ex_scorecard_annual kept for reference but not used to size envelope.
CREATE OR REPLACE FUNCTION public.compute_weekly_marketing_bonus(
  p_agency_id uuid,
  p_week_end_date date DEFAULT NULL::date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_week_end DATE;
  v_quarter_start DATE;
  v_quarter_end DATE;
  v_weeks_in_qtd INT;
  v_pool_basis JSONB;
  v_total_basis NUMERIC;
  v_scorecard_ontime NUMERIC;
  v_basis_ex_scorecard NUMERIC;
  v_envelope_annual NUMERIC;
  v_envelope_quarterly NUMERIC;
  v_envelope_qtd NUMERIC;
  v_spend_qtd NUMERIC;
  v_underspend_qtd NUMERIC;
  v_total_bare_min_qtd NUMERIC;
  v_adjusted_underspend_qtd NUMERIC;
  v_pool_qtd NUMERIC;
  v_total_points_qtd NUMERIC;
  v_people JSONB;
  v_result JSONB;
  v_mktg_root_id UUID;
BEGIN
  v_week_end := COALESCE(
    p_week_end_date,
    (CURRENT_DATE + ((6 - EXTRACT(DOW FROM CURRENT_DATE)::int + 7) % 7))::date
  );

  v_quarter_start := date_trunc('quarter', v_week_end::timestamp)::date;
  v_quarter_end   := (v_quarter_start + INTERVAL '3 months - 1 day')::date;
  v_weeks_in_qtd := LEAST(13, CEIL(((v_week_end - v_quarter_start) + 1)::numeric / 7.0)::int);

  v_pool_basis         := public.compute_pool_basis_and_envelope(p_agency_id, v_week_end);
  v_total_basis        := COALESCE((v_pool_basis->'basis'->>'total_basis_annual')::numeric, 0);
  v_scorecard_ontime   := COALESCE((v_pool_basis->'basis'->>'on_time_scorecard_dollars')::numeric, 0);
  v_basis_ex_scorecard := v_total_basis - v_scorecard_ontime;

  -- Envelope now uses FULL basis (includes Scorecard) — Peter directive 2026-07-12
  v_envelope_annual    := ROUND(v_total_basis * 0.10, 2);
  v_envelope_quarterly := ROUND(v_envelope_annual / 4.0, 2);
  v_envelope_qtd       := ROUND(v_envelope_quarterly * v_weeks_in_qtd / 13.0, 2);

  SELECT id INTO v_mktg_root_id
  FROM public.chart_of_accounts
  WHERE agency_id = p_agency_id AND account_name = '0003 MARKETING'
  LIMIT 1;

  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_spend_qtd
  FROM public.chart_of_accounts coa
  JOIN public.journal_lines   jl ON jl.account_id = coa.id
  JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  WHERE coa.agency_id = p_agency_id
    AND (coa.id = v_mktg_root_id OR coa.parent_account_id = v_mktg_root_id)
    AND je.agency_id = p_agency_id
    AND je.entry_date >= v_quarter_start
    AND je.entry_date <= v_week_end;

  v_spend_qtd := ROUND(COALESCE(v_spend_qtd, 0), 2);
  v_underspend_qtd := GREATEST(0, v_envelope_qtd - v_spend_qtd);

  SELECT COALESCE(SUM(points), 0)
  INTO v_total_points_qtd
  FROM public.marketing_points
  WHERE agency_id = p_agency_id
    AND week_end_date >= v_quarter_start
    AND week_end_date <= v_week_end;

  v_total_bare_min_qtd := v_total_points_qtd;

  v_adjusted_underspend_qtd := GREATEST(0, v_underspend_qtd - v_total_bare_min_qtd);
  v_pool_qtd := ROUND(v_adjusted_underspend_qtd * 0.50, 2);

  WITH person_points AS (
    SELECT
      team_member_id,
      SUM(points)                  AS points_qtd,
      SUM(points_reviews)          AS reviews_qtd,
      SUM(points_referrals_quoted) AS quoted_qtd,
      SUM(points_referrals_sold)   AS sold_qtd,
      -- This-week points only (for payroll line item — Peter 2026-07-12)
      COALESCE(SUM(CASE WHEN week_end_date = v_week_end THEN points END), 0) AS points_this_week
    FROM public.marketing_points
    WHERE agency_id = p_agency_id
      AND week_end_date >= v_quarter_start
      AND week_end_date <= v_week_end
    GROUP BY team_member_id
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'team_member_id',      t.id,
      'name',                t.first_name || ' ' || COALESCE(t.last_name, ''),
      'points_qtd',          COALESCE(pp.points_qtd, 0),
      'points_this_week',    COALESCE(pp.points_this_week, 0),
      'reviews_qtd',         COALESCE(pp.reviews_qtd, 0),
      'quoted_qtd',          COALESCE(pp.quoted_qtd, 0),
      'sold_qtd',            COALESCE(pp.sold_qtd, 0),
      'bare_min_qtd',        COALESCE(pp.points_qtd, 0),
      'share_pct',           CASE WHEN v_total_points_qtd > 0
                                  THEN ROUND(COALESCE(pp.points_qtd, 0) / v_total_points_qtd * 100.0, 2)
                                  ELSE 0 END,
      'bonus_share_qtd',     CASE WHEN v_total_points_qtd > 0
                                  THEN ROUND(COALESCE(pp.points_qtd, 0) / v_total_points_qtd * v_pool_qtd, 2)
                                  ELSE 0 END,
      'total_marketing_qtd', CASE WHEN v_total_points_qtd > 0
                                  THEN COALESCE(pp.points_qtd, 0)
                                       + ROUND(COALESCE(pp.points_qtd, 0) / v_total_points_qtd * v_pool_qtd, 2)
                                  ELSE COALESCE(pp.points_qtd, 0) END
    )
    ORDER BY COALESCE(pp.points_qtd, 0) DESC, t.first_name
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
    'quarter_start',  v_quarter_start,
    'quarter_end',    v_quarter_end,
    'weeks_in_qtd',   v_weeks_in_qtd,
    'basis', jsonb_build_object(
      'total_basis_annual',        v_total_basis,
      'scorecard_ontime_included', v_scorecard_ontime,
      'basis_ex_scorecard_annual', v_basis_ex_scorecard,
      'source', 'compute_pool_basis_and_envelope total_basis_annual (Scorecard included per 2026-07-12 directive; AIPP not in basis)'
    ),
    'envelope', jsonb_build_object(
      'annual',       v_envelope_annual,
      'quarterly',    v_envelope_quarterly,
      'qtd_target',   v_envelope_qtd,
      'pct_of_basis', 0.10
    ),
    'spend', jsonb_build_object(
      'qtd',              v_spend_qtd,
      'root_account_id',  v_mktg_root_id,
      'source',           '0003 MARKETING envelope by account_name + descendants (QTD)'
    ),
    'pool', jsonb_build_object(
      'underspend_qtd',          v_underspend_qtd,
      'total_bare_min_qtd',      v_total_bare_min_qtd,
      'adjusted_underspend_qtd', v_adjusted_underspend_qtd,
      'team_share_pct',          0.50,
      'pool_qtd',                v_pool_qtd,
      'total_points_qtd',        v_total_points_qtd
    ),
    'people',       COALESCE(v_people, '[]'::jsonb),
    'computed_at',  NOW()
  );

  RETURN v_result;
END;
$function$;
