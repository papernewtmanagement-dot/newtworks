-- Bank service fees on the Premium Fund Account are the agent's own cost.
-- Peter confirmed 2026-08-04: the money leaves permanently, State Farm does not
-- reimburse it, and no personal money is deposited to restore the balance.
--
-- Therefore a month with a fee is NOT short of anything. The agent's own money
-- in the account is simply lower by exactly the fee. Expected funds this month
-- = last month's actual ending funds MINUS this month's fee, and the month
-- should reconcile to zero.
--
-- Two changes from the prior version:
--   1. Carry forward last month's ACTUAL ending funds (adjusted_statement_balance)
--      instead of re-deriving it as prior_personal_funds - prior fee. Those two
--      agree in any month that reconciled cleanly, but the direct read is honest
--      and does not drift if a month ever closes with a difference.
--   2. Subtract THIS month's fee when computing the difference. The prior version
--      omitted it, which reported a fee month as short by the fee amount -- a
--      false alarm that would block auto-send on a month that is actually fine.

CREATE OR REPLACE FUNCTION public.pfa_monthly_reconciliation(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_pfa_account_id uuid; v_statement record; v_prev_recon record;
  v_prior_personal_funds numeric; v_current_bank_service_fees numeric;
  v_outstanding_checks_total numeric; v_outstanding_sf_eft_total numeric;
  v_outstanding_deposits_total numeric; v_returned_checks_unreim numeric := 0;
  v_adjusted_statement_balance numeric; v_difference numeric; v_recon_id uuid;
  v_processed_count int := 0; v_peter_tg bigint; v_dm_text text;
  v_alert_title text; v_alert_message text; v_results jsonb := '[]'::jsonb;
  v_inserted_ids uuid[] := '{}'::uuid[];
  v_retry_recon record;
BEGIN
  SELECT id INTO v_pfa_account_id FROM public.pfa_accounts
  WHERE agency_id = p_agency_id AND is_active = true LIMIT 1;
  IF v_pfa_account_id IS NULL THEN
    RETURN jsonb_build_object('records_processed', 0, 'output_summary', 'No active PFA account.');
  END IF;

  SELECT t.telegram_user_id INTO v_peter_tg FROM public.team t
  WHERE t.first_name='Peter' AND t.last_name='Story' AND t.telegram_user_id IS NOT NULL LIMIT 1;
  v_peter_tg := COALESCE(v_peter_tg, 7778113542);

  FOR v_statement IN
    SELECT s.id, s.statement_period_start, s.statement_period_end, s.closing_balance
    FROM public.pfa_bank_statements s WHERE s.pfa_account_id = v_pfa_account_id
      AND NOT EXISTS (SELECT 1 FROM public.pfa_reconciliations r WHERE r.statement_id = s.id)
    ORDER BY s.statement_period_end
  LOOP
    v_processed_count := v_processed_count + 1;

    SELECT COALESCE(SUM(debit_amount), 0) INTO v_outstanding_sf_eft_total FROM public.pfa_transactions
    WHERE pfa_account_id = v_pfa_account_id AND transaction_type = 'State Farm EFT' AND voided_at IS NULL
      AND transaction_date <= v_statement.statement_period_end
      AND (cleared = false OR cleared_date > v_statement.statement_period_end);

    SELECT COALESCE(SUM(credit_amount), 0) INTO v_outstanding_deposits_total FROM public.pfa_transactions
    WHERE pfa_account_id = v_pfa_account_id AND credit_amount IS NOT NULL AND voided_at IS NULL
      AND transaction_date <= v_statement.statement_period_end
      AND (cleared = false OR cleared_date > v_statement.statement_period_end);

    SELECT COALESCE(SUM(debit_amount), 0) INTO v_outstanding_checks_total FROM public.pfa_transactions
    WHERE pfa_account_id = v_pfa_account_id AND debit_amount IS NOT NULL
      AND transaction_type <> 'State Farm EFT' AND voided_at IS NULL
      AND transaction_date <= v_statement.statement_period_end
      AND (cleared = false OR cleared_date > v_statement.statement_period_end);

    SELECT COALESCE(SUM(debit_amount), 0) INTO v_current_bank_service_fees FROM public.pfa_transactions
    WHERE pfa_account_id = v_pfa_account_id AND transaction_type = 'Bank Service Fee'
      AND voided_at IS NULL AND cleared = true
      AND cleared_date >= v_statement.statement_period_start
      AND cleared_date <= v_statement.statement_period_end;

    -- Last month's ACTUAL ending balance of the agent's own funds.
    SELECT r.adjusted_statement_balance INTO v_prev_recon
    FROM public.pfa_reconciliations r
    WHERE r.pfa_account_id = v_pfa_account_id
      AND r.statement_ending_date < v_statement.statement_period_end
    ORDER BY r.statement_ending_date DESC LIMIT 1;

    v_prior_personal_funds := COALESCE(v_prev_recon.adjusted_statement_balance, 0);

    v_adjusted_statement_balance := v_statement.closing_balance
                                    - v_outstanding_checks_total - v_outstanding_sf_eft_total
                                    + v_outstanding_deposits_total + v_returned_checks_unreim;

    -- The fee already left the bank balance above. It also permanently lowers
    -- what we EXPECT to be there, so it must come off the expected side too.
    v_difference := v_adjusted_statement_balance
                    - (v_prior_personal_funds - v_current_bank_service_fees);

    INSERT INTO public.pfa_reconciliations (
      pfa_account_id, statement_id, statement_ending_date, statement_ending_balance,
      outstanding_checks_total, outstanding_sf_eft_total, outstanding_deposits_total,
      returned_checks_unreimbursed, adjusted_statement_balance,
      prior_personal_funds, current_bank_service_fees, difference_to_reconcile,
      explanation, reconciled_at
    ) VALUES (
      v_pfa_account_id, v_statement.id, v_statement.statement_period_end, v_statement.closing_balance,
      v_outstanding_checks_total, v_outstanding_sf_eft_total, v_outstanding_deposits_total,
      v_returned_checks_unreim, v_adjusted_statement_balance,
      v_prior_personal_funds, v_current_bank_service_fees, v_difference,
      'Auto-computed by pfa_monthly_reconciliation.', now()
    ) RETURNING id INTO v_recon_id;

    v_inserted_ids := array_append(v_inserted_ids, v_recon_id);

    IF abs(v_difference) < 0.005 THEN
      v_dm_text := format(E'✅ PFA reconciliation computed clean\n\nStatement ending: %s\nDifference: $0.00\nSending to peter.story.yrru@statefarm.com now...',
        to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'));
    ELSE
      v_alert_title := '⚠️ PFA reconciliation DISCREPANCY — ' || to_char(v_statement.statement_period_end, 'FMMonth YYYY');
      v_alert_message := format('The reconciliation for the PFA statement ending %s has a difference of $%s. Do NOT send to SF until reviewed. Open Deposits → Reconciliations and expand the row to see the waterfall + outstanding items.',
        to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'),
        trim(to_char(v_difference, 'FM999,999,990.00')));
      INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference,
        is_read, is_resolved, related_id, created_at)
      VALUES (p_agency_id, 'pfa_reconciliation_ready', 'warning', v_alert_title, v_alert_message,
        'pfa_reconciliation:' || v_recon_id::text, false, false, v_recon_id, now());
      v_dm_text := format(E'⚠️ PFA reconciliation discrepancy\n\nStatement ending: %s\nClosing balance: $%s\nOutstanding SF EFTs: $%s\nOutstanding deposits: $%s\nAdjusted balance: $%s\nPrior personal funds: $%s\nBank service fees: $%s\n\nDifference: $%s ❌\n\nReview at https://newtworks.vercel.app/pfa before sending.',
        to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'),
        trim(to_char(v_statement.closing_balance, 'FM999,999,990.00')),
        trim(to_char(v_outstanding_sf_eft_total, 'FM999,999,990.00')),
        trim(to_char(v_outstanding_deposits_total, 'FM999,999,990.00')),
        trim(to_char(v_adjusted_statement_balance, 'FM999,999,990.00')),
        trim(to_char(v_prior_personal_funds, 'FM999,999,990.00')),
        trim(to_char(v_current_bank_service_fees, 'FM999,999,990.00')),
        trim(to_char(v_difference, 'FM999,999,990.00')));
    END IF;

    BEGIN PERFORM public.telegram_send_message_v2(v_peter_tg, v_dm_text, 'paper_newt');
    EXCEPTION WHEN OTHERS THEN RAISE WARNING 'PFA recon % Telegram DM failed: %', v_recon_id, SQLERRM; END;

    v_results := v_results || jsonb_build_object(
      'reconciliation_id', v_recon_id,
      'statement_period_end', v_statement.statement_period_end,
      'adjusted_balance', v_adjusted_statement_balance, 'difference', v_difference,
      'clean', (abs(v_difference) < 0.005),
      'auto_sent', false);
  END LOOP;

  -- Retry pass: pick up existing CLEAN reconciliations that were never
  -- successfully emailed. Excludes rows inserted in the loop above (already
  -- in v_results). Self-healing: costs nothing once everything is sent.
  FOR v_retry_recon IN
    SELECT r.id, r.statement_ending_date
    FROM public.pfa_reconciliations r
    WHERE r.pfa_account_id = v_pfa_account_id
      AND abs(r.difference_to_reconcile) < 0.005
      AND r.emailed_to_agent_at IS NULL
      AND r.id <> ALL(v_inserted_ids)
    ORDER BY r.statement_ending_date
  LOOP
    v_processed_count := v_processed_count + 1;
    v_results := v_results || jsonb_build_object(
      'reconciliation_id', v_retry_recon.id,
      'statement_period_end', v_retry_recon.statement_ending_date,
      'clean', true, 'auto_sent', false, 'retry', true);
  END LOOP;

  IF v_processed_count = 0 THEN
    RETURN jsonb_build_object('records_processed', 0, 'output_summary', 'No unreconciled statements.');
  END IF;
  RETURN jsonb_build_object('records_processed', v_processed_count,
    'output_summary', format('Auto-computed/retried %s reconciliation(s).', v_processed_count),
    'results', v_results);
END;
$function$;
