-- Replace step 4 placeholder in quarter_close_prize_cart_and_leaderboards
-- Now calls audit_weekly_leaderboard_crossings which handles quarter_sp + weekly

CREATE OR REPLACE FUNCTION public.quarter_close_prize_cart_and_leaderboards(
  p_agency_id uuid,
  p_quarter_ending_date date
) RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_next_q_end          date;
  v_carried             int := 0;
  v_scorecard_annual    numeric := 0;
  v_next_budget         numeric := 0;
  v_pool_result         jsonb;
  v_mvp_id              uuid;
  v_mvp_sp              numeric;
  v_mvp_row_exists      boolean;
  v_audit_result        jsonb;
  v_result              jsonb;
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
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_carried FROM carried;

  v_pool_result := public.compute_pool_basis_and_envelope(p_agency_id, v_next_q_end);
  v_scorecard_annual := COALESCE((v_pool_result->'basis'->>'on_time_scorecard_dollars')::numeric, 0);
  v_next_budget := ROUND(v_scorecard_annual * 0.01, 2);

  INSERT INTO public.quarter_prize_budgets (agency_id, quarter_ending_date, budget_dollars, formula_note)
  VALUES (p_agency_id, v_next_q_end, v_next_budget,
          '1% × on-time Scorecard ($' || v_scorecard_annual::text || ' → $' || v_next_budget::text || ')')
  ON CONFLICT (agency_id, quarter_ending_date) DO UPDATE
    SET budget_dollars = EXCLUDED.budget_dollars,
        formula_note   = EXCLUDED.formula_note;

  SELECT id INTO v_mvp_id FROM public.mvp_history
    WHERE agency_id = p_agency_id AND week_ending_date = p_quarter_ending_date;
  v_mvp_row_exists := v_mvp_id IS NOT NULL;

  IF NOT v_mvp_row_exists THEN
    SELECT d.team_member_id, MAX(d.sales_points) INTO v_mvp_id, v_mvp_sp
    FROM public.weekly_cpr_reports r
    JOIN public.weekly_cpr_team_detail d ON d.weekly_cpr_report_id = r.id
    WHERE r.agency_id = p_agency_id
      AND r.week_ending_date = p_quarter_ending_date
      AND r.won_the_week = true
    GROUP BY d.team_member_id
    ORDER BY MAX(d.sales_points) DESC NULLS LAST
    LIMIT 1;

    IF v_mvp_id IS NOT NULL AND COALESCE(v_mvp_sp, 0) > 0 THEN
      INSERT INTO public.mvp_history (agency_id, week_ending_date, team_member_id, sales_points_earned, prize_draws)
      VALUES (p_agency_id, p_quarter_ending_date, v_mvp_id, v_mvp_sp, 3);
    END IF;
  END IF;

  -- 4. Full leaderboard audit — quarter_sp + weekly categories
  BEGIN
    v_audit_result := public.audit_weekly_leaderboard_crossings(p_agency_id, p_quarter_ending_date);
  EXCEPTION WHEN OTHERS THEN
    v_audit_result := jsonb_build_object('error', SQLERRM, 'sqlstate', SQLSTATE);
  END;

  v_result := jsonb_build_object(
    'quarter_ending_date',        p_quarter_ending_date,
    'next_quarter_ending_date',   v_next_q_end,
    'prizes_carried',             v_carried,
    'next_quarter_budget_dollars', v_next_budget,
    'mvp_recorded',               (v_mvp_id IS NOT NULL AND NOT v_mvp_row_exists),
    'leaderboard_audit_result',   v_audit_result,
    'ran_at',                     now()
  );

  RETURN v_result;
END;
$function$;
