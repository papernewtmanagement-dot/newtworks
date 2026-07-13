-- Fix: quarter_close_prize_cart_and_leaderboards INSERTs into alerts using
-- `description` but the actual column is `message` — same class of bug as
-- send_mvp_prize_win_telegram (fixed in 20260713143000). Would silent-throw
-- at quarter close (~2026-10-03) blocking the prize-cart-refresh alert.
--
-- Also upgrades the silent `EXCEPTION WHEN OTHERS THEN NULL` on Peter's
-- Telegram nudge to a logged alert row (same failure-visibility pattern
-- as send_mvp_prize_win_telegram).

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
  v_pace                numeric := 0;
  v_rate                CONSTANT numeric := 0.01;
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

  v_pool_result       := public.compute_pool_basis_and_envelope(p_agency_id, p_quarter_ending_date);
  v_smvc_annual       := COALESCE((v_pool_result->'basis'->>'on_time_smvc_dollars')::numeric, 0);
  v_scorecard_annual  := COALESCE((v_pool_result->'basis'->>'on_time_scorecard_dollars')::numeric, 0);
  v_ot_basis_annual   := v_smvc_annual + v_scorecard_annual;

  SELECT COUNT(*) INTO v_closing_qtr_wins
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id
    AND week_ending_date > (p_quarter_ending_date - INTERVAL '13 weeks')
    AND week_ending_date <= p_quarter_ending_date
    AND won_the_week = true;

  -- At quarter close: pace = actual wins / 13 (no projection needed — quarter is done)
  v_pace        := LEAST(1.0, v_closing_qtr_wins::numeric / 13.0);
  v_next_budget := ROUND(v_rate * v_ot_basis_annual * v_pace, 2);

  INSERT INTO public.quarter_prize_budgets (agency_id, quarter_ending_date, budget_dollars, formula_note)
  VALUES (p_agency_id, v_next_q_end, v_next_budget,
          format('1%% × on-time (SMVC $%s + Scorecard $%s) × %s/13 weeks won = $%s',
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
    format('Quarter closed %s. %s prizes carried ($%s total). Budget $%s (1%% × OT basis × %s/13 wins). Available for new prizes: $%s.',
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

  INSERT INTO public.alerts (agency_id, alert_type, module_reference, severity, title, message, related_id, is_resolved)
  VALUES (
    p_agency_id, 'system', 'prize_cart_refresh', 'medium',
    format('Prize cart refresh — $%s available (Q ending %s)',
           v_available_budget::text, to_char(v_next_q_end, 'YYYY-MM-DD')),
    format('Quarter closed. %s prizes carried ($%s). Budget $%s (%s/13 wins). Available for new prizes: $%s. '
           'Run Claude session with op-rule "Newtworks quarter-end prize cart research" to research + verify links + propose new items.',
           v_carried, v_carried_value_total::text, v_next_budget::text, v_closing_qtr_wins::text, v_available_budget::text),
    v_pending_id,
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
      '• Closing quarter wins: ' || v_closing_qtr_wins::text || '/13 (pace ' || ROUND(v_pace, 4)::text || ')' || chr(10) ||
      '• Next quarter budget: $' || v_next_budget::text || chr(10) ||
      '• Available for new prizes: $' || v_available_budget::text || chr(10) || chr(10) ||
      'Start a Claude session and say "run prize cart research" — Claude will use the ' ||
      '"Newtworks quarter-end prize cart research" operational rule to verify all links ' ||
      'and propose new prizes within budget.';

    BEGIN
      PERFORM public.paper_newt_send_message(v_peter_chat_id, v_telegram_text, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO public.alerts (agency_id, alert_type, module_reference, severity, title, message, related_id, is_resolved)
      VALUES (p_agency_id, 'system', 'prize_cart_refresh', 'medium',
              'Quarter-close nudge to Peter failed',
              format('Quarter=%s Error=%s', p_quarter_ending_date::text, SQLERRM),
              v_pending_id,
              false);
    END;
  ELSE
    INSERT INTO public.alerts (agency_id, alert_type, module_reference, severity, title, message, related_id, is_resolved)
    VALUES (p_agency_id, 'system', 'prize_cart_refresh', 'medium',
            'Quarter-close nudge to Peter: no telegram mapping',
            format('No team_telegram_map row found for Peter Story in agency %s. Quarter=%s.',
                   p_agency_id::text, p_quarter_ending_date::text),
            v_pending_id,
            false);
  END IF;

  v_result := jsonb_build_object(
    'quarter_ending_date',        p_quarter_ending_date,
    'next_quarter_ending_date',   v_next_q_end,
    'prizes_carried',             v_carried,
    'carried_value_total',        v_carried_value_total,
    'closing_qtr_wins',           v_closing_qtr_wins,
    'pace',                       ROUND(v_pace, 4),
    'rate_pct',                   v_rate,
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
