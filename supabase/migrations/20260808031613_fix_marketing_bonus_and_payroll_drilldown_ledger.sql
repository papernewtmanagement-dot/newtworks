-- 2026-08-08: journal_entries + journal_lines were dropped and merged into public.ledger
-- by the finrebuild (20260808001345..20260808022601). compute_weekly_marketing_bonus was
-- still written against the old two-table shape and errored every time it ran, silently
-- freezing the CPR page's marketing bonus numbers. Re-pointed at ledger.
CREATE OR REPLACE FUNCTION public.compute_weekly_marketing_bonus(p_agency_id uuid, p_week_end_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_week_end DATE; v_quarter_start DATE; v_quarter_end DATE; v_weeks_in_qtd INT;
  v_pool_basis JSONB; v_total_basis NUMERIC; v_scorecard_ontime NUMERIC; v_basis_ex_scorecard NUMERIC;
  v_envelope_annual NUMERIC; v_envelope_quarterly NUMERIC; v_envelope_qtd NUMERIC;
  v_spend_qtd NUMERIC; v_underspend_qtd NUMERIC; v_total_bare_min_qtd NUMERIC;
  v_adjusted_underspend_qtd NUMERIC; v_pool_qtd NUMERIC; v_total_points_qtd NUMERIC;
  v_people JSONB; v_result JSONB;
BEGIN
  v_week_end := COALESCE(p_week_end_date, (CURRENT_DATE + ((6 - EXTRACT(DOW FROM CURRENT_DATE)::int + 7) % 7))::date);
  v_quarter_start := date_trunc('quarter', v_week_end::timestamp)::date;
  v_quarter_end   := (v_quarter_start + INTERVAL '3 months - 1 day')::date;
  v_weeks_in_qtd  := LEAST(13, CEIL(((v_week_end - v_quarter_start) + 1)::numeric / 7.0)::int);

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
  v_underspend_qtd := GREATEST(0, v_envelope_qtd - v_spend_qtd);

  SELECT COALESCE(SUM(points), 0) INTO v_total_points_qtd
  FROM public.marketing_points
  WHERE agency_id = p_agency_id
    AND week_end_date >= v_quarter_start AND week_end_date <= v_week_end;

  v_total_bare_min_qtd := v_total_points_qtd;
  v_adjusted_underspend_qtd := GREATEST(0, v_underspend_qtd - v_total_bare_min_qtd);
  v_pool_qtd := ROUND(v_adjusted_underspend_qtd * 0.50, 2);

  WITH person_points AS (
    SELECT team_member_id, SUM(points) AS points_qtd, SUM(points_reviews) AS reviews_qtd,
           SUM(points_referrals_quoted) AS quoted_qtd, SUM(points_referrals_sold) AS sold_qtd,
           COALESCE(SUM(CASE WHEN week_end_date = v_week_end THEN points END), 0) AS points_this_week
    FROM public.marketing_points
    WHERE agency_id = p_agency_id AND week_end_date >= v_quarter_start AND week_end_date <= v_week_end
    GROUP BY team_member_id
  )
  SELECT jsonb_agg(jsonb_build_object(
    'team_member_id',      t.id,
    'name',                t.first_name || ' ' || COALESCE(t.last_name, ''),
    'points_qtd',          COALESCE(pp.points_qtd, 0),
    'points_this_week',    COALESCE(pp.points_this_week, 0),
    'reviews_qtd',         COALESCE(pp.reviews_qtd, 0),
    'quoted_qtd',          COALESCE(pp.quoted_qtd, 0),
    'sold_qtd',            COALESCE(pp.sold_qtd, 0),
    'bare_min_qtd',        COALESCE(pp.points_qtd, 0),
    'share_pct',           CASE WHEN v_total_points_qtd > 0
                                THEN ROUND(COALESCE(pp.points_qtd, 0) / v_total_points_qtd * 100.0, 2) ELSE 0 END,
    'bonus_share_qtd',     CASE WHEN v_total_points_qtd > 0
                                THEN ROUND(COALESCE(pp.points_qtd, 0) / v_total_points_qtd * v_pool_qtd, 2) ELSE 0 END,
    'total_marketing_qtd', CASE WHEN v_total_points_qtd > 0
                                THEN COALESCE(pp.points_qtd, 0) + ROUND(COALESCE(pp.points_qtd, 0) / v_total_points_qtd * v_pool_qtd, 2)
                                ELSE COALESCE(pp.points_qtd, 0) END
  ) ORDER BY COALESCE(pp.points_qtd, 0) DESC, t.first_name) INTO v_people
  FROM public.team t
  LEFT JOIN person_points pp ON pp.team_member_id = t.id
  WHERE t.agency_id = p_agency_id AND t.is_active = true
    AND COALESCE(t.is_admin_backoffice, false) = false AND t.archived_at IS NULL
    AND COALESCE(t.is_test_user, false) = false
    AND (t.role_level IS NULL OR t.role_level != 'Owner') AND t.category = 'agency';

  v_result := jsonb_build_object(
    'agency_id', p_agency_id, 'week_end_date', v_week_end,
    'quarter_start', v_quarter_start, 'quarter_end', v_quarter_end, 'weeks_in_qtd', v_weeks_in_qtd,
    'basis', jsonb_build_object(
      'total_basis_annual', v_total_basis, 'scorecard_ontime_included', v_scorecard_ontime,
      'basis_ex_scorecard_annual', v_basis_ex_scorecard,
      'source', 'compute_pool_basis_and_envelope total_basis_annual (Scorecard included per 2026-07-12 directive; AIPP not in basis)'
    ),
    'envelope', jsonb_build_object(
      'annual', v_envelope_annual, 'quarterly', v_envelope_quarterly,
      'qtd_target', v_envelope_qtd, 'pct_of_basis', 0.10
    ),
    'spend', jsonb_build_object(
      'qtd', v_spend_qtd, 'scope', 'account_subtype IN (marketing, advertising)',
      'source', 'sum(debit - credit) on active expense COAs with marketing/advertising subtype (QTD), from ledger'
    ),
    'pool', jsonb_build_object(
      'underspend_qtd', v_underspend_qtd, 'total_bare_min_qtd', v_total_bare_min_qtd,
      'adjusted_underspend_qtd', v_adjusted_underspend_qtd, 'team_share_pct', 0.50,
      'pool_qtd', v_pool_qtd, 'total_points_qtd', v_total_points_qtd
    ),
    'people', COALESCE(v_people, '[]'::jsonb), 'computed_at', NOW()
  );

  RETURN v_result;
END;
$function$;


-- payroll_runs.journal_entry_id was also dropped in the finrebuild with no replacement
-- column; GL legs for a payroll run are now found by reference_number pattern against ledger.
CREATE OR REPLACE FUNCTION public.get_payroll_run_drilldown(p_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_papernewt_entity uuid := 'b1111111-1111-1111-1111-111111111111';
  v_agency_id uuid;
  v_pay_period_start date;
  v_pay_period_end date;
  v_pay_date date;
  v_gross numeric;
  v_er_taxes numeric;
  v_net numeric;
  v_provider text;
  v_status text;
  v_run_entity uuid;

  v_pd_id uuid;
  v_tm_id uuid;
  v_tm_first text;
  v_tm_last text;
  v_tm_entity uuid;
  v_tm_entity_name text;
  v_tm_start date;
  v_tm_role_level text;
  v_tm_admin_bo boolean;
  v_p_gross numeric;
  v_p_er_taxes numeric;
  v_p_net numeric;
  v_earnings jsonb;
  v_items jsonb;
  v_salary numeric;
  v_hourly numeric;
  v_ot numeric;
  v_bonus numeric;
  v_commission numeric;
  v_other numeric;
  v_reimb numeric;
  v_fixed numeric;
  v_variable numeric;
  v_recognized numeric;
  v_gap numeric;
  v_weeks_in int;
  v_ramp numeric;
  v_grow_share numeric;
  v_team_share numeric;
  v_route_papernewt boolean;
  v_route_reason text;
  v_key text;
  v_val numeric;

  v_people jsonb := '[]'::jsonb;
  v_jes jsonb := '[]'::jsonb;
BEGIN
  SELECT agency_id, pay_period_start, pay_period_end, pay_date,
         gross_payroll, employer_taxes, net_payroll, payroll_provider, status,
         business_entity_id
    INTO v_agency_id, v_pay_period_start, v_pay_period_end, v_pay_date,
         v_gross, v_er_taxes, v_net, v_provider, v_status, v_run_entity
    FROM payroll_runs
   WHERE id = p_run_id;

  IF v_agency_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'run_not_found', 'run_id', p_run_id);
  END IF;

  FOR v_pd_id, v_tm_id, v_p_gross, v_p_er_taxes, v_p_net, v_earnings IN
    SELECT id, team_member_id, gross_pay, employer_taxes, net_pay, raw_earnings
      FROM payroll_detail
     WHERE payroll_run_id = p_run_id
     ORDER BY team_member_id
  LOOP
    IF v_tm_id IS NULL THEN
      CONTINUE;
    END IF;

    SELECT first_name, last_name, business_entity_id, start_date, role_level, is_admin_backoffice
      INTO v_tm_first, v_tm_last, v_tm_entity, v_tm_start, v_tm_role_level, v_tm_admin_bo
      FROM team WHERE id = v_tm_id;

    SELECT name INTO v_tm_entity_name
      FROM business_entities WHERE id = v_tm_entity;

    v_items := COALESCE(v_earnings->'items', '{}'::jsonb);
    v_salary := 0; v_hourly := 0; v_ot := 0; v_bonus := 0;
    v_commission := 0; v_other := 0; v_reimb := 0;

    FOR v_key IN SELECT jsonb_object_keys(v_items) LOOP
      v_val := COALESCE((v_items->v_key->>'period')::numeric, 0);
      IF v_val = 0 THEN CONTINUE; END IF;

      CASE v_key
        WHEN 'SALARY' THEN v_salary := v_salary + v_val;
        WHEN 'HOURLY' THEN v_hourly := v_hourly + v_val;
        WHEN 'REGULAR' THEN v_hourly := v_hourly + v_val;
        WHEN 'PTO' THEN v_hourly := v_hourly + v_val;
        WHEN 'OT' THEN v_ot := v_ot + v_val;
        WHEN '- O/TIME' THEN v_ot := v_ot + v_val;
        WHEN '1Health' THEN v_hourly := v_hourly + v_val;
        WHEN '5Goals' THEN v_hourly := v_hourly + v_val;
        WHEN 'LIFE *' THEN v_hourly := v_hourly + v_val;
        WHEN 'BONUS' THEN v_bonus := v_bonus + v_val;
        WHEN 'COMMISSION' THEN v_commission := v_commission + v_val;
        WHEN 'OTHER' THEN v_other := v_other + v_val;
        WHEN '0Advnce' THEN v_other := v_other + v_val;
        WHEN '2Serve' THEN v_other := v_other + v_val;
        WHEN '3True' THEN v_other := v_other + v_val;
        WHEN '4Manage' THEN v_other := v_other + v_val;
        WHEN 'REIMBURSEMENTS' THEN v_reimb := v_reimb + v_val;
        WHEN 'REIMB.' THEN v_reimb := v_reimb + v_val;
        WHEN 'blank3' THEN NULL;
        ELSE NULL;
      END CASE;
    END LOOP;

    v_route_papernewt := (v_tm_role_level = 'Owner')
                      OR (v_tm_admin_bo = true)
                      OR (v_tm_entity = v_papernewt_entity);
    v_route_reason := CASE
      WHEN v_tm_role_level = 'Owner' THEN 'role_level=Owner'
      WHEN v_tm_admin_bo = true THEN 'is_admin_backoffice=true'
      WHEN v_tm_entity = v_papernewt_entity THEN 'team.business_entity_id=PaperNewt'
      ELSE 'agency_split'
    END;

    IF v_route_papernewt THEN
      v_people := v_people || jsonb_build_object(
        'team_member_id', v_tm_id,
        'name', COALESCE(v_tm_first || ' ' || v_tm_last, '(unknown)'),
        'role_level', v_tm_role_level,
        'is_admin_backoffice', v_tm_admin_bo,
        'team_entity_id', v_tm_entity,
        'team_entity_name', v_tm_entity_name,
        'route', 'papernewt_direct',
        'reason', v_route_reason,
        'gross_pay', v_p_gross,
        'employer_taxes', v_p_er_taxes,
        'net_pay', v_p_net,
        'pn_expense', v_p_gross + COALESCE(v_p_er_taxes, 0)
      );
    ELSE
      v_fixed := v_salary + v_hourly + v_ot;
      v_variable := v_bonus + v_commission + v_other;
      v_recognized := v_fixed + v_variable + v_reimb;
      v_gap := GREATEST(0, v_p_gross - v_recognized);

      IF v_tm_start IS NULL THEN
        v_ramp := 0;
        v_weeks_in := NULL;
      ELSE
        v_weeks_in := GREATEST(0, FLOOR((v_pay_period_end - v_tm_start) / 7.0)::int);
        v_ramp := 1.0 - LEAST(1.0, GREATEST(0::numeric, v_weeks_in / 52.0));
      END IF;
      v_grow_share := ROUND(v_fixed * v_ramp, 2);
      v_team_share := ROUND((v_fixed - v_grow_share) + v_variable + v_gap, 2);

      v_people := v_people || jsonb_build_object(
        'team_member_id', v_tm_id,
        'name', COALESCE(v_tm_first || ' ' || v_tm_last, '(unknown)'),
        'role_level', v_tm_role_level,
        'is_admin_backoffice', v_tm_admin_bo,
        'team_entity_id', v_tm_entity,
        'team_entity_name', v_tm_entity_name,
        'route', 'agency_split',
        'reason', v_route_reason,
        'gross_pay', v_p_gross,
        'employer_taxes', v_p_er_taxes,
        'net_pay', v_p_net,
        'start_date', v_tm_start,
        'weeks_in', v_weeks_in,
        'ramp_frac', ROUND(v_ramp, 4),
        'fixed_bundle', v_fixed,
        'variable', v_variable,
        'reimb', v_reimb,
        'unrecognized_gap', v_gap,
        'growth_share', v_grow_share,
        'team_share', v_team_share
      );
    END IF;
  END LOOP;

  SELECT COALESCE(jsonb_agg(
           jsonb_build_object(
             'id', sub.ref_id,
             'reference_number', sub.reference_number,
             'description', sub.description,
             'business_entity_id', sub.business_entity_id,
             'entry_date', sub.entry_date,
             'leg', CASE
                      WHEN sub.reference_number = 'PAYROLL-' || p_run_id::text || '-AGENCY' THEN 'AGENCY'
                      WHEN sub.reference_number = 'PAYROLL-' || p_run_id::text || '-PAPERNEWT' THEN 'PAPERNEWT'
                      WHEN sub.reference_number = 'PAYROLL-' || p_run_id::text || '-PAPERNEWT-IC-RECON' THEN 'PAPERNEWT-IC-RECON'
                      ELSE 'OTHER'
                    END
           )
           ORDER BY sub.reference_number
         ), '[]'::jsonb)
    INTO v_jes
    FROM (
      SELECT
        (array_agg(l.id))[1] AS ref_id,
        l.reference_number,
        MIN(l.description) AS description,
        MIN(l.entry_date) AS entry_date,
        CASE WHEN COUNT(DISTINCT coa.business_entity_id) = 1
             THEN (array_agg(DISTINCT coa.business_entity_id))[1]
             ELSE NULL::uuid
        END AS business_entity_id
      FROM public.ledger l
      JOIN public.chart_of_accounts coa ON coa.id = l.account_id
      WHERE l.reference_number IN (
              'PAYROLL-' || p_run_id::text || '-AGENCY',
              'PAYROLL-' || p_run_id::text || '-PAPERNEWT',
              'PAYROLL-' || p_run_id::text || '-PAPERNEWT-IC-RECON'
            )
      GROUP BY l.reference_number
    ) sub;

  RETURN jsonb_build_object(
    'ok', true,
    'run', jsonb_build_object(
      'id', p_run_id,
      'pay_period_start', v_pay_period_start,
      'pay_period_end', v_pay_period_end,
      'pay_date', v_pay_date,
      'gross', v_gross,
      'employer_taxes', v_er_taxes,
      'net', v_net,
      'provider', v_provider,
      'status', v_status,
      'business_entity_id', v_run_entity
    ),
    'people', v_people,
    'jes', v_jes
  );
END;
$function$;
