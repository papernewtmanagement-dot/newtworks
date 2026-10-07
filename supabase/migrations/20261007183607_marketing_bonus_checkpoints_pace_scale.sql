CREATE OR REPLACE FUNCTION public.compute_weekly_marketing_bonus(p_agency_id uuid, p_week_end_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c_full_leftover_from CONSTANT date := '2026-10-10';
  c_checkpoint_from    CONSTANT date := '2026-10-10';
  v_week_end DATE; v_quarter_start DATE; v_quarter_end DATE; v_weeks_in_qtd INT;
  v_pool_basis JSONB; v_total_basis NUMERIC; v_scorecard_ontime NUMERIC; v_basis_ex_scorecard NUMERIC;
  v_envelope_annual NUMERIC; v_envelope_quarterly NUMERIC; v_envelope_qtd NUMERIC;
  v_spend_qtd NUMERIC; v_underspend_qtd NUMERIC; v_total_bare_min_qtd NUMERIC;
  v_adjusted_underspend_qtd NUMERIC; v_team_share NUMERIC; v_pool_qtd NUMERIC; v_total_points_qtd NUMERIC;
  v_people JSONB; v_kept NUMERIC; v_result JSONB;
  v_use_cp BOOLEAN; v_cp_week INT := 0; v_cp_end DATE; v_env_cp NUMERIC := 0; v_spend_cp NUMERIC := 0; v_points_cp NUMERIC := 0;
  v_prior_pts NUMERIC := 0; v_ref_weekly NUMERIC := 0; v_pace NUMERIC := 1; v_pool_before_pace NUMERIC := 0; v_next_cp INT;
BEGIN
  PERFORM public.require_login('staff');
  v_week_end := COALESCE(p_week_end_date, (CURRENT_DATE + ((6 - EXTRACT(DOW FROM CURRENT_DATE)::int + 7) % 7))::date);
  v_quarter_start := (SELECT cci.cycle_start FROM public.current_cycle_info(p_agency_id, v_week_end) cci);
  v_quarter_end   := (v_quarter_start + INTERVAL '3 months - 1 day')::date;
  v_weeks_in_qtd  := LEAST(13, CEIL(((v_week_end - v_quarter_start) + 1)::numeric / 7.0)::int);
  v_team_share    := CASE WHEN v_week_end >= c_full_leftover_from THEN 1.00 ELSE 0.50 END;
  v_use_cp        := v_week_end >= c_checkpoint_from;

  v_pool_basis         := public.compute_pool_basis_and_envelope(p_agency_id, v_week_end);
  v_total_basis        := COALESCE((v_pool_basis->'basis'->>'total_basis_annual')::numeric, 0);
  v_scorecard_ontime   := COALESCE((v_pool_basis->'basis'->>'on_time_scorecard_dollars')::numeric, 0);
  v_basis_ex_scorecard := v_total_basis - v_scorecard_ontime;

  v_envelope_annual    := ROUND(v_total_basis * 0.10, 2);
  v_envelope_quarterly := ROUND(v_envelope_annual / 4.0, 2);
  v_envelope_qtd       := ROUND(v_envelope_quarterly * v_weeks_in_qtd / 13.0, 2);

  SELECT COALESCE(SUM(l.debit - l.credit), 0) INTO v_spend_qtd
  FROM public.chart_of_accounts coa
  JOIN public.ledger l ON l.account_id = coa.id
  WHERE coa.agency_id = p_agency_id
    AND coa.account_type = 'expense'
    AND coa.account_subtype IN ('marketing','advertising')
    AND coa.is_active = TRUE
    AND l.agency_id = p_agency_id
    AND l.entry_date >= v_quarter_start
    AND l.entry_date <= v_week_end;
  v_spend_qtd := ROUND(COALESCE(v_spend_qtd, 0), 2);

  SELECT COALESCE(SUM(w.points), 0) INTO v_total_points_qtd
  FROM public.marketing_points_weekly(p_agency_id, v_week_end) w;

  IF v_use_cp THEN
    v_cp_week := CASE WHEN v_weeks_in_qtd >= 13 THEN 13 WHEN v_weeks_in_qtd >= 8 THEN 8 WHEN v_weeks_in_qtd >= 4 THEN 4 ELSE 0 END;
    v_next_cp := CASE WHEN v_weeks_in_qtd < 4 THEN 4 WHEN v_weeks_in_qtd < 8 THEN 8 WHEN v_weeks_in_qtd < 13 THEN 13 ELSE NULL END;
    IF v_cp_week > 0 THEN
      v_cp_end := v_quarter_start + (v_cp_week * 7 - 1);
      v_env_cp := ROUND(v_envelope_quarterly * v_cp_week / 13.0, 2);
      SELECT ROUND(COALESCE(SUM(l.debit - l.credit), 0), 2) INTO v_spend_cp
      FROM public.chart_of_accounts coa
      JOIN public.ledger l ON l.account_id = coa.id
      WHERE coa.agency_id = p_agency_id
        AND coa.account_type = 'expense'
        AND coa.account_subtype IN ('marketing','advertising')
        AND coa.is_active = TRUE
        AND l.agency_id = p_agency_id
        AND l.entry_date >= v_quarter_start
        AND l.entry_date <= v_cp_end;
      SELECT COALESCE(SUM(w.points), 0) INTO v_points_cp
      FROM public.marketing_points_weekly(p_agency_id, v_cp_end) w;
    END IF;
    SELECT COALESCE(SUM(w.points), 0) INTO v_prior_pts
    FROM public.marketing_points_weekly(p_agency_id, v_quarter_start - 1) w;
    v_ref_weekly := v_prior_pts / 13.0;
    v_pace := CASE WHEN v_cp_week = 0 THEN 0
                   WHEN v_ref_weekly <= 0 THEN 1
                   ELSE LEAST(1, (v_points_cp / 13.0) / v_ref_weekly) END;
    v_underspend_qtd          := GREATEST(0, v_env_cp - v_spend_cp);
    v_total_bare_min_qtd      := v_points_cp;
    v_adjusted_underspend_qtd := GREATEST(0, v_underspend_qtd - v_points_cp);
    v_pool_before_pace        := ROUND(v_adjusted_underspend_qtd * v_team_share, 2);
    v_pool_qtd                := ROUND(v_adjusted_underspend_qtd * v_pace * v_team_share, 2);
  ELSE
    v_underspend_qtd          := GREATEST(0, v_envelope_qtd - v_spend_qtd);
    v_total_bare_min_qtd      := v_total_points_qtd;
    v_adjusted_underspend_qtd := GREATEST(0, v_underspend_qtd - v_total_bare_min_qtd);
    v_pool_qtd                := ROUND(v_adjusted_underspend_qtd * v_team_share, 2);
    v_pool_before_pace        := v_pool_qtd;
  END IF;

  WITH person_points AS (
    SELECT w.team_member_id, SUM(w.points) AS points_qtd,
           COALESCE(SUM(CASE WHEN w.week_end_date = v_week_end THEN w.points END), 0) AS points_this_week
    FROM public.marketing_points_weekly(p_agency_id, v_week_end) w
    GROUP BY w.team_member_id
  ),
  person_cp AS (
    SELECT w.team_member_id, SUM(w.points) AS pts
    FROM public.marketing_points_weekly(p_agency_id, COALESCE(v_cp_end, v_week_end)) w
    WHERE v_use_cp AND v_cp_week > 0
    GROUP BY w.team_member_id
  ),
  prior_bonus AS (
    SELECT d.team_member_id, SUM(d.marketing_pool_bonus_weekly) AS paid
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
    WHERE r.agency_id = p_agency_id AND r.week_ending_date >= v_quarter_start AND r.week_ending_date < v_week_end
    GROUP BY d.team_member_id
  ),
  ppl AS (
    SELECT t.id, t.first_name, t.last_name, t.end_date,
           (t.end_date IS NOT NULL AND t.end_date <= v_week_end) AS has_left,
           COALESCE(pp.points_qtd, 0) AS points_qtd, COALESCE(pp.points_this_week, 0) AS points_this_week,
           COALESCE(pc.pts, 0) AS points_cp,
           COALESCE(pb.paid, 0) AS bonus_paid_prior,
           CASE WHEN v_use_cp THEN (CASE WHEN v_points_cp > 0 THEN COALESCE(pc.pts, 0) / v_points_cp ELSE 0 END)
                ELSE (CASE WHEN v_total_points_qtd > 0 THEN COALESCE(pp.points_qtd, 0) / v_total_points_qtd ELSE 0 END) END AS ratio
    FROM public.team t
    LEFT JOIN person_points pp ON pp.team_member_id = t.id
    LEFT JOIN person_cp pc ON pc.team_member_id = t.id
    LEFT JOIN prior_bonus pb ON pb.team_member_id = t.id
    WHERE t.agency_id = p_agency_id
      AND COALESCE(t.is_admin_backoffice, false) = false
      AND COALESCE(t.is_test_user, false) = false
      AND (t.role_level IS NULL OR t.role_level != 'Owner') AND t.category = 'agency'
      AND (t.is_active = true OR pp.team_member_id IS NOT NULL)
  ),
  calc AS (
    SELECT p.*,
           ROUND(p.ratio * v_pool_qtd, 2) AS share_of_pool,
           CASE WHEN p.has_left THEN 0 ELSE ROUND(p.ratio * v_pool_qtd, 2) END AS bonus_share_qtd
    FROM ppl p
  )
  SELECT jsonb_agg(jsonb_build_object(
    'team_member_id',      c.id,
    'name',                c.first_name || ' ' || COALESCE(c.last_name, ''),
    'points_qtd',          c.points_qtd,
    'points_this_week',    c.points_this_week,
    'points_at_checkpoint', c.points_cp,
    'left_mid_quarter',    c.has_left,
    'reviews_qtd',         0,
    'quoted_qtd',          0,
    'sold_qtd',            0,
    'bare_min_qtd',        c.points_qtd,
    'share_pct',           ROUND(c.ratio * 100.0, 2),
    'bonus_share_qtd',     c.bonus_share_qtd,
    'agency_kept_qtd',     CASE WHEN c.has_left THEN c.share_of_pool ELSE 0 END,
    'bonus_paid_prior_qtd', ROUND(c.bonus_paid_prior, 2),
    'bonus_this_week',     ROUND(GREATEST(0, c.bonus_share_qtd - c.bonus_paid_prior), 2),
    'total_marketing_qtd', c.points_qtd + c.bonus_share_qtd
  ) ORDER BY c.points_qtd DESC, c.first_name),
  COALESCE(SUM(CASE WHEN c.has_left THEN c.share_of_pool ELSE 0 END), 0)
  INTO v_people, v_kept
  FROM calc c;

  v_result := jsonb_build_object(
    'agency_id', p_agency_id, 'week_end_date', v_week_end,
    'quarter_start', v_quarter_start, 'quarter_end', v_quarter_end, 'weeks_in_qtd', v_weeks_in_qtd,
    'basis', jsonb_build_object(
      'total_basis_annual', v_total_basis, 'scorecard_ontime_included', v_scorecard_ontime,
      'basis_ex_scorecard_annual', v_basis_ex_scorecard,
      'source', 'compute_pool_basis_and_envelope total_basis_annual (team bonus pool basis)'
    ),
    'envelope', jsonb_build_object(
      'annual', v_envelope_annual, 'quarterly', v_envelope_quarterly,
      'qtd_target', v_envelope_qtd, 'pct_of_basis', 0.10
    ),
    'spend', jsonb_build_object(
      'qtd', v_spend_qtd, 'scope', 'account_subtype IN (marketing, advertising)',
      'source', 'sum(debit - credit) on active expense COAs with marketing/advertising subtype (QTD), from ledger'
    ),
    'checkpoint', jsonb_build_object(
      'active', v_use_cp, 'week', v_cp_week, 'next_week', v_next_cp, 'ends', v_cp_end,
      'envelope_to_date', v_env_cp, 'spend_to_date', v_spend_cp, 'points_to_date', v_points_cp,
      'surplus_after_points', v_adjusted_underspend_qtd,
      'pace_pct', ROUND(v_pace * 100.0, 2), 'pace_reference_weekly', ROUND(v_ref_weekly, 2),
      'pool_before_pace', v_pool_before_pace
    ),
    'pool', jsonb_build_object(
      'underspend_qtd', v_underspend_qtd, 'total_bare_min_qtd', v_total_bare_min_qtd,
      'adjusted_underspend_qtd', v_adjusted_underspend_qtd, 'team_share_pct', v_team_share,
      'pool_qtd', v_pool_qtd, 'agency_kept_qtd', ROUND(v_kept, 2), 'total_points_qtd', v_total_points_qtd
    ),
    'people', COALESCE(v_people, '[]'::jsonb), 'computed_at', NOW()
  );
  RETURN v_result;
END;
$function$;
