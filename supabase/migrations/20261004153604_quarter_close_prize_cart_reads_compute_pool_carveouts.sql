CREATE OR REPLACE FUNCTION public.quarter_close_prize_cart_and_leaderboards(p_agency_id uuid, p_quarter_ending_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_next_q_end date; v_carried int := 0; v_carried_value_total numeric := 0;
  v_carve jsonb; v_cart jsonb; v_rate numeric := 0; v_pace numeric := 0;
  v_ot_basis_annual numeric := 0; v_closing_qtr_wins int := 0;
  v_next_budget numeric := 0; v_available_budget numeric := 0;
  v_audit_result jsonb; v_result jsonb;
  v_peter_chat_id bigint; v_telegram_text text;
BEGIN
  v_next_q_end := p_quarter_ending_date + INTERVAL '13 weeks';

  WITH carried AS (
    INSERT INTO public.prize_cart (agency_id, quarter_ending_date, display_order,
      prize_description, prize_url, prize_value)
    SELECT agency_id, v_next_q_end, display_order, prize_description, prize_url, prize_value
    FROM public.prize_cart
    WHERE agency_id = p_agency_id AND quarter_ending_date = p_quarter_ending_date
      AND winner_team_member_id IS NULL
    RETURNING prize_value
  )
  SELECT COUNT(*), COALESCE(SUM(prize_value), 0) INTO v_carried, v_carried_value_total FROM carried;

  -- Peter 2026-10-04: the prize cart and the trip pot are always linked. The next quarter's
  -- budget is the closing quarter's prize cart pot from compute_pool_carveouts, the same
  -- formula and rate as the trip pot. No second copy of the rate lives here.
  v_carve := public.compute_pool_carveouts(p_agency_id, p_quarter_ending_date);
  v_cart := v_carve->'mvp_prize_cart';
  v_next_budget := ROUND(COALESCE(NULLIF(v_cart->>'quarterly_dollars','')::numeric, 0), 2);
  v_rate := COALESCE(NULLIF(v_cart->>'rate_pct','')::numeric, 0);
  v_pace := COALESCE(NULLIF(v_cart->>'pace','')::numeric, 0);
  v_ot_basis_annual := COALESCE(NULLIF(v_carve->'inputs'->>'annual_ot_basis','')::numeric, 0);
  v_closing_qtr_wins := COALESCE(NULLIF(v_carve->'inputs'->>'current_cycle_wins_to_date','')::int, 0);

  INSERT INTO public.quarter_prize_budgets (agency_id, quarter_ending_date, budget_dollars, formula_note)
  VALUES (p_agency_id, v_next_q_end, v_next_budget,
          format('%s%% x on-time (variable commission + Scorecard $%s) x %s/13 weeks won = $%s',
                 (v_rate * 100)::text, ROUND(v_ot_basis_annual, 2)::text, v_closing_qtr_wins::text, v_next_budget::text))
  ON CONFLICT (agency_id, quarter_ending_date) DO UPDATE
    SET budget_dollars = EXCLUDED.budget_dollars, formula_note = EXCLUDED.formula_note;

  v_available_budget := ROUND(v_next_budget - v_carried_value_total, 2);

  BEGIN v_audit_result := public.audit_weekly_leaderboard_crossings(p_agency_id, p_quarter_ending_date);
  EXCEPTION WHEN OTHERS THEN v_audit_result := jsonb_build_object('error', SQLERRM, 'sqlstate', SQLSTATE); END;

  SELECT telegram_user_id INTO v_peter_chat_id FROM public.team
  WHERE agency_id = p_agency_id AND first_name = 'Peter' AND last_name = 'Story'
    AND telegram_user_id IS NOT NULL LIMIT 1;

  IF v_peter_chat_id IS NOT NULL THEN
    v_telegram_text := '🏆 Prize cart refresh ready' || chr(10) || chr(10) ||
      'Quarter closed: ' || p_quarter_ending_date::text || ' -> next quarter ends ' || v_next_q_end::text || chr(10) ||
      '• ' || v_carried::text || ' prizes carried ($' || v_carried_value_total::text || ' total value)' || chr(10) ||
      '• Closing quarter wins: ' || v_closing_qtr_wins::text || '/13' || chr(10) ||
      '• Next quarter budget: $' || v_next_budget::text || chr(10) ||
      '• Available for new prizes: $' || v_available_budget::text;
    BEGIN PERFORM public.paper_newt_send_message(v_peter_chat_id, v_telegram_text, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END IF;

  v_result := jsonb_build_object('quarter_ending_date', p_quarter_ending_date,
    'next_quarter_ending_date', v_next_q_end, 'prizes_carried', v_carried,
    'carried_value_total', v_carried_value_total, 'closing_qtr_wins', v_closing_qtr_wins,
    'pace', ROUND(v_pace, 4), 'rate_pct', v_rate, 'ot_basis_annual', v_ot_basis_annual,
    'next_quarter_budget_dollars', v_next_budget, 'available_budget_dollars', v_available_budget,
    'leaderboard_audit_result', v_audit_result, 'ran_at', now());
  RETURN v_result;
END;
$function$

