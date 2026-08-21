-- Restore prize cart pool formula to match WtQ Trip pot at 1/10 rate + prior-qtr wins (per handbook).
-- 2026-07-11 simplification (1% × Scorecard only, no SMVC, no wins ratio) reverted 2026-07-12 per Peter.
-- Also solidifies "rest of team = non-MVP" language in SQL comments.

CREATE OR REPLACE FUNCTION public.compute_pool_carveouts(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_pool_result         jsonb;
  v_annual_ot_smvc      numeric;
  v_annual_ot_scorecard numeric;
  v_annual_ot_basis     numeric;

  v_annual_manager_bonus numeric := 0;
  v_manager_detail      jsonb := '[]'::jsonb;

  v_annual_life_ins     numeric := 0;
  v_life_ins_detail     jsonb := '[]'::jsonb;

  v_annual_apparel      numeric := 0;
  v_apparel_detail      jsonb := '[]'::jsonb;

  v_annual_hdb          numeric := 0;
  v_hdb_detail          jsonb := '[]'::jsonb;

  v_annual_cc           numeric := 0;
  v_cc_pct              CONSTANT numeric := 0.03;

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

  -- WtQ Trip split constants (locked 2026-07-12).
  -- MVP gets 30% (own share). REST OF TEAM = every teammate EXCEPT the MVP; they alone split the 70% pool, evenly per head.
  -- The MVP does NOT receive any portion of the 70% pool — that would be double-dipping.
  v_mvp_share_pct       CONSTANT numeric := 0.30;
  v_rest_share_pct      CONSTANT numeric := 0.70;
  v_team_count          int := 0;
  v_rest_count          int := 0;
  v_mvp_dollars         numeric := 0;
  v_rest_pool_dollars   numeric := 0;
  v_rest_per_person     numeric := 0;

  v_total_carveouts     numeric;
BEGIN
  v_pool_result         := public.compute_pool_basis_and_envelope(p_agency_id, p_week_end_date);
  v_annual_ot_smvc      := COALESCE(NULLIF(v_pool_result->'basis'->>'on_time_smvc_dollars','')::numeric, 0);
  v_annual_ot_scorecard := COALESCE(NULLIF(v_pool_result->'basis'->>'on_time_scorecard_dollars','')::numeric, 0);
  v_annual_ot_basis     := v_annual_ot_smvc + v_annual_ot_scorecard;

  -- MANAGER BONUS
  SELECT
    COALESCE(SUM(
      CASE et.role_level
        WHEN 'Unit Manager'    THEN 0.001
        WHEN 'Section Manager' THEN 0.002
        WHEN 'Office Manager'  THEN 0.003
        ELSE 0
      END * 52.0 * v_annual_ot_scorecard
    ), 0),
    COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id', et.team_id,
      'name', et.first_name || ' ' || et.last_name,
      'role_level', et.role_level,
      'weekly_rate_pct', CASE et.role_level
                          WHEN 'Unit Manager'    THEN 0.1
                          WHEN 'Section Manager' THEN 0.2
                          WHEN 'Office Manager'  THEN 0.3
                          ELSE 0 END,
      'weekly_bonus_dollars', ROUND(
        CASE et.role_level
          WHEN 'Unit Manager'    THEN 0.001
          WHEN 'Section Manager' THEN 0.002
          WHEN 'Office Manager'  THEN 0.003
          ELSE 0 END * v_annual_ot_scorecard, 2),
      'annual_bonus_dollars', ROUND(
        CASE et.role_level
          WHEN 'Unit Manager'    THEN 0.001
          WHEN 'Section Manager' THEN 0.002
          WHEN 'Office Manager'  THEN 0.003
          ELSE 0 END * v_annual_ot_scorecard * 52.0, 2)
    )), '[]'::jsonb)
  INTO v_annual_manager_bonus, v_manager_detail
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
  WHERE et.role_level IN ('Unit Manager','Section Manager','Office Manager');

  -- LIFE INSURANCE STIPEND
  SELECT
    COALESCE(SUM(m.monthly_cap * 12.0), 0),
    COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id',   et.team_id,
      'name',             et.first_name || ' ' || et.last_name,
      'start_date',       et.start_date,
      'year_of_employment', m.yoe,
      'monthly_cap_dollars', m.monthly_cap,
      'annual_dollars',    ROUND(m.monthly_cap * 12.0, 2)
    )), '[]'::jsonb)
  INTO v_annual_life_ins, v_life_ins_detail
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
  CROSS JOIN LATERAL (
    SELECT GREATEST(1, FLOOR((p_week_end_date - et.start_date)::numeric / 365.25)::int + 1) AS yoe
  ) yc
  CROSS JOIN LATERAL (
    SELECT
      yc.yoe,
      CASE
        WHEN yc.yoe = 1  THEN 50   WHEN yc.yoe = 2  THEN 100
        WHEN yc.yoe = 3  THEN 150  WHEN yc.yoe = 4  THEN 200
        WHEN yc.yoe = 5  THEN 250  WHEN yc.yoe = 6  THEN 300
        WHEN yc.yoe = 7  THEN 350  WHEN yc.yoe = 8  THEN 400
        WHEN yc.yoe = 9  THEN 450  WHEN yc.yoe = 10 THEN 475
        ELSE 500
      END AS monthly_cap
  ) m
  WHERE et.start_date IS NOT NULL;

  -- APPAREL
  SELECT
    COALESCE(SUM(m.annual_apparel), 0),
    COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id',   et.team_id,
      'name',             et.first_name || ' ' || et.last_name,
      'start_date',       et.start_date,
      'year_of_employment', m.yoe,
      'annual_dollars',    ROUND(m.annual_apparel, 2)
    )), '[]'::jsonb)
  INTO v_annual_apparel, v_apparel_detail
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et
  CROSS JOIN LATERAL (
    SELECT GREATEST(1, FLOOR((p_week_end_date - et.start_date)::numeric / 365.25)::int + 1) AS yoe
  ) yc
  CROSS JOIN LATERAL (
    SELECT yc.yoe, CASE WHEN yc.yoe = 1 THEN 200 ELSE 100 END AS annual_apparel
  ) m
  WHERE et.start_date IS NOT NULL;

  -- HEALTH DEVELOPMENT BONUS
  SELECT
    COALESCE(SUM(25 * 52.0), 0),
    COALESCE(jsonb_agg(jsonb_build_object(
      'team_member_id',     et.team_id,
      'name',               et.first_name || ' ' || et.last_name,
      'weekly_max_dollars', 25,
      'annual_max_dollars', 1300
    )), '[]'::jsonb)
  INTO v_annual_hdb, v_hdb_detail
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date) et;

  -- CHAMPIONS CIRCLE RESERVE (3% × OT basis, carve-and-forget)
  v_annual_cc := v_cc_pct * v_annual_ot_basis;

  -- Cycle bounds
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

  -- MVP PRIZE CART: 1% × on-time (SMVC + Scorecard) annual × prior_qtr_wins/13.
  -- Same formula as WtQ Trip at 1/10 the rate, uses PRIOR quarter wins, no floor.
  -- Handbook "Winning & Learning" > Prize Cart section is the authoritative spec.
  -- Was briefly simplified 2026-07-11 to 1% × Scorecard only; reverted 2026-07-12 per Peter.
  v_annual_mvp := 0.01 * v_annual_ot_basis * (v_prior_qtr_wins::numeric / 13.0);

  -- WtQ Trip: 10% × on-time (SMVC + Scorecard) annual × curr_qtr_wins/13 with 9-win floor
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

  -- WtQ split: 30% Quarter MVP, 70% pooled among the REST OF THE TEAM (non-MVP teammates only), split evenly per head.
  -- MVP does NOT receive a share of the 70% pool. team_count = full active roster; rest_count = team_count - 1 (MVP excluded).
  SELECT COUNT(*) INTO v_team_count
  FROM public.get_expected_teammates(p_agency_id, 'time_off_participant', p_week_end_date);
  v_rest_count        := GREATEST(0, v_team_count - 1);
  v_mvp_dollars       := v_annual_wtq * v_mvp_share_pct;
  v_rest_pool_dollars := v_annual_wtq * v_rest_share_pct;
  v_rest_per_person   := CASE
    WHEN v_rest_count > 0 THEN v_rest_pool_dollars / v_rest_count::numeric
    ELSE 0
  END;

  v_total_carveouts := v_annual_manager_bonus
                    + v_annual_life_ins
                    + v_annual_apparel
                    + v_annual_hdb
                    + v_annual_cc
                    + v_annual_mvp
                    + v_annual_wtq;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id,
    'week_end_date', p_week_end_date,
    'design_note', 'Carve-and-forget: unearned carveouts stay with agency (do NOT reconcile back to pool).',
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
      'formula',        'sum(role_level_pct × on-time Scorecard annual): UM=0.1%, SectM=0.2%, OM=0.3%',
      'detail',         v_manager_detail
    ),
    'life_insurance_stipend', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_life_ins, 2),
      'weekly_dollars', ROUND(v_annual_life_ins / 52.0, 2),
      'formula',        'sum(monthly_cap_by_year_of_employment × 12) across active non-owner roster',
      'detail',         v_life_ins_detail
    ),
    'apparel', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_apparel, 2),
      'weekly_dollars', ROUND(v_annual_apparel / 52.0, 2),
      'formula',        'Y1 = $200 (13-week + first anniversary), Y2+ = $100 (annual anniversary)',
      'detail',         v_apparel_detail
    ),
    'health_development_bonus', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_hdb, 2),
      'weekly_dollars', ROUND(v_annual_hdb / 52.0, 2),
      'formula',        '$25/week × 52 weeks per active non-owner team member (structural max)',
      'detail',         v_hdb_detail
    ),
    'champions_circle', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_cc, 2),
      'weekly_dollars', ROUND(v_annual_cc / 52.0, 2),
      'pct_of_basis',   v_cc_pct,
      'formula',        '3% × on-time (SMVC + Scorecard) annual basis, flat accrual'
    ),
    'mvp_prize_cart', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_mvp, 2),
      'weekly_dollars', ROUND(v_annual_mvp / 52.0, 2),
      'formula',        '1% × on-time (SMVC + Scorecard) annual × prior_qtr_wins/13',
      'note',           'Same formula as WtQ Trip at 1/10 rate, uses PRIOR quarter wins, no floor. Handbook is source of truth.'
    ),
    'wtq_trip', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_wtq, 2),
      'weekly_dollars', ROUND(v_annual_wtq / 52.0, 2),
      'formula',        '10% × on-time (SMVC + Scorecard) annual × current_qtr_wins/13',
      'floor_wins',     9,
      'halted',         v_wtq_halted,
      'halt_reason',    v_wtq_halt_reason,
      'note',           'Accrues weekly. Halts if math cannot reach 9-wins floor.',
      'mvp_share_pct',           v_mvp_share_pct,
      'rest_share_pct',          v_rest_share_pct,
      'rest_split_rule',         'evenly per non-MVP teammate (MVP does NOT receive share of the 70% pool)',
      'team_count',              v_team_count,
      'rest_of_team_count',      v_rest_count,
      'mvp_dollars',             ROUND(v_mvp_dollars, 2),
      'rest_pool_dollars',       ROUND(v_rest_pool_dollars, 2),
      'rest_per_person_dollars', ROUND(v_rest_per_person, 2)
    ),
    'total_annual_carveouts', ROUND(v_total_carveouts, 2),
    'total_weekly_carveouts', ROUND(v_total_carveouts / 52.0, 2),
    'computed_at', now()
  );
END;
$function$;


-- Restore quarter_close_prize_cart_and_leaderboards budget formula to match handbook.
CREATE OR REPLACE FUNCTION public.quarter_close_prize_cart_and_leaderboards(p_agency_id uuid, p_quarter_ending_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_next_q_end          date;
  v_carried             int := 0;
  v_carried_value_total numeric := 0;
  v_smvc_annual         numeric := 0;
  v_scorecard_annual    numeric := 0;
  v_ot_basis_annual     numeric := 0;
  v_closing_qtr_wins    int := 0;
  v_wins_ratio          numeric := 0;
  v_next_budget         numeric := 0;
  v_available_budget    numeric := 0;
  v_pool_result         jsonb;
  v_audit_result        jsonb;
  v_result              jsonb;
  v_pending_id          uuid;
  v_peter_chat_id       bigint;
  v_telegram_text       text;
BEGIN
  v_next_q_end := p_quarter_ending_date + INTERVAL '13 weeks';

  WITH carried AS (
    INSERT INTO public.prize_cart (
      agency_id, quarter_ending_date, display_order,
      prize_description, prize_url, prize_value
    )
    SELECT agency_id, v_next_q_end, display_order,
           prize_description, prize_url, prize_value
    FROM public.prize_cart
    WHERE agency_id = p_agency_id
      AND quarter_ending_date = p_quarter_ending_date
      AND winner_team_member_id IS NULL
    RETURNING prize_value
  )
  SELECT COUNT(*), COALESCE(SUM(prize_value), 0)
  INTO v_carried, v_carried_value_total
  FROM carried;

  -- Snapshot the pool basis + wins from the CLOSING quarter (which becomes the "previous quarter" for the next).
  v_pool_result       := public.compute_pool_basis_and_envelope(p_agency_id, p_quarter_ending_date);
  v_smvc_annual       := COALESCE((v_pool_result->'basis'->>'on_time_smvc_dollars')::numeric, 0);
  v_scorecard_annual  := COALESCE((v_pool_result->'basis'->>'on_time_scorecard_dollars')::numeric, 0);
  v_ot_basis_annual   := v_smvc_annual + v_scorecard_annual;

  -- Count wins in the closing quarter (13 weeks ending on p_quarter_ending_date).
  SELECT COUNT(*) INTO v_closing_qtr_wins
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id
    AND week_ending_date > (p_quarter_ending_date - INTERVAL '13 weeks')
    AND week_ending_date <= p_quarter_ending_date
    AND won_the_week = true;

  v_wins_ratio  := v_closing_qtr_wins::numeric / 13.0;
  -- Prize cart budget: 1% × on-time (SMVC + Scorecard) × (closing quarter wins / 13). No floor.
  -- Same formula as WtQ Trip at 1/10 rate (per handbook "Winning & Learning" > Prize Cart).
  v_next_budget := ROUND(0.01 * v_ot_basis_annual * v_wins_ratio, 2);

  INSERT INTO public.quarter_prize_budgets (agency_id, quarter_ending_date, budget_dollars, formula_note)
  VALUES (p_agency_id, v_next_q_end, v_next_budget,
          format('1%% × on-time (SMVC $%s + Scorecard $%s) × prior_wins %s/13 = $%s',
                 v_smvc_annual::text, v_scorecard_annual::text, v_closing_qtr_wins::text, v_next_budget::text))
  ON CONFLICT (agency_id, quarter_ending_date) DO UPDATE
    SET budget_dollars = EXCLUDED.budget_dollars,
        formula_note   = EXCLUDED.formula_note;

  v_available_budget := ROUND(v_next_budget - v_carried_value_total, 2);

  INSERT INTO public.pending_prize_research (
    agency_id, quarter_ending_date, available_budget_dollars,
    carried_prize_count, carried_prize_value_total, status, notes
  )
  VALUES (
    p_agency_id, v_next_q_end, v_available_budget,
    v_carried, v_carried_value_total, 'pending',
    format('Quarter closed %s. %s prizes carried ($%s total). Budget $%s (1%% × OT basis × %s wins/13). Available for new prizes: $%s.',
           p_quarter_ending_date::text, v_carried, v_carried_value_total::text,
           v_next_budget::text, v_closing_qtr_wins::text, v_available_budget::text)
  )
  ON CONFLICT (agency_id, quarter_ending_date) DO UPDATE
    SET available_budget_dollars = EXCLUDED.available_budget_dollars,
        carried_prize_count      = EXCLUDED.carried_prize_count,
        carried_prize_value_total= EXCLUDED.carried_prize_value_total,
        status                   = 'pending',
        updated_at               = now()
  RETURNING id INTO v_pending_id;

  BEGIN
    v_audit_result := public.audit_weekly_leaderboard_crossings(p_agency_id, p_quarter_ending_date);
  EXCEPTION WHEN OTHERS THEN
    v_audit_result := jsonb_build_object('error', SQLERRM, 'sqlstate', SQLSTATE);
  END;

  INSERT INTO public.alerts (agency_id, module_reference, severity, title, description, is_resolved)
  VALUES (
    p_agency_id, 'prize_cart_refresh', 'medium',
    format('Prize cart refresh — $%s available (Q ending %s)',
           v_available_budget::text, to_char(v_next_q_end, 'YYYY-MM-DD')),
    format('Quarter closed. %s prizes carried ($%s). Budget $%s. Available for new prizes: $%s. '
           'Run Claude session with op-rule "Newtworks quarter-end prize cart research" to research + verify links + propose new items.',
           v_carried, v_carried_value_total::text, v_next_budget::text, v_available_budget::text),
    false
  );

  SELECT telegram_user_id INTO v_peter_chat_id
  FROM public.team_telegram_map
  WHERE agency_id = p_agency_id
    AND telegram_first_name = 'Peter'
    AND telegram_last_name = 'Story'
  LIMIT 1;

  IF v_peter_chat_id IS NOT NULL THEN
    v_telegram_text :=
      '🏆 Prize cart refresh ready' || chr(10) || chr(10) ||
      'Quarter closed: ' || p_quarter_ending_date::text || ' -> next quarter ends ' || v_next_q_end::text || chr(10) ||
      '• ' || v_carried::text || ' prizes carried ($' || v_carried_value_total::text || ' total value)' || chr(10) ||
      '• Closing quarter wins: ' || v_closing_qtr_wins::text || '/13' || chr(10) ||
      '• Next quarter budget: $' || v_next_budget::text || chr(10) ||
      '• Available for new prizes: $' || v_available_budget::text || chr(10) || chr(10) ||
      'Start a Claude session and say "run prize cart research" — Claude will use the ' ||
      '"Newtworks quarter-end prize cart research" operational rule to verify all links ' ||
      'and propose new prizes within budget.';

    BEGIN
      PERFORM public.paper_newt_send_message(v_peter_chat_id, v_telegram_text, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END IF;

  v_result := jsonb_build_object(
    'quarter_ending_date',        p_quarter_ending_date,
    'next_quarter_ending_date',   v_next_q_end,
    'prizes_carried',             v_carried,
    'carried_value_total',        v_carried_value_total,
    'closing_qtr_wins',           v_closing_qtr_wins,
    'wins_ratio',                 v_wins_ratio,
    'ot_basis_annual',            v_ot_basis_annual,
    'next_quarter_budget_dollars',v_next_budget,
    'available_budget_dollars',   v_available_budget,
    'pending_prize_research_id',  v_pending_id,
    'leaderboard_audit_result',   v_audit_result,
    'ran_at',                     now()
  );

  RETURN v_result;
END;
$function$;
