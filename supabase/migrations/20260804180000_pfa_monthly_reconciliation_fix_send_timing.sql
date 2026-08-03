-- 20260804180000_pfa_monthly_reconciliation_fix_send_timing.sql
--
-- Fixes a transaction-visibility bug: pfa_monthly_reconciliation() used to
-- call pfa-reconciliation-send synchronously via extensions.http_post from
-- inside its own still-open transaction. The reconciliation row it had just
-- inserted was not yet committed, so the edge function's own connection
-- could never see it -- every auto-send failed with a swallowed
-- "reconciliation lookup failed: undefined" (a zero-rows case misreported
-- as an error). This function no longer attempts the send at all; it only
-- computes reconciliations and returns results[] with clean/auto_sent
-- flags. The actual send now happens in automation-runner's
-- afterPfaReconciliation() hook, which fires AFTER this RPC call returns --
-- i.e. after the transaction has committed -- mirroring the existing
-- afterCrmAnalyticsIngest() post-write hook pattern.
--
-- Also adds a retry pass: on every run, after processing any brand-new
-- statements, it re-scans for existing CLEAN reconciliations that were
-- never successfully emailed (emailed_to_agent_at IS NULL) and adds them
-- to results[] too. This catches both the July 2026 reconciliation stuck
-- by the old bug, and any future transient Composio/Gmail send failure --
-- self-healing on the next daily run, no manual retry needed. Newly
-- inserted rows from THIS run are excluded from the retry pass via
-- v_inserted_ids so they aren't double-counted/double-sent.

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

    SELECT r.prior_personal_funds, r.current_bank_service_fees INTO v_prev_recon
    FROM public.pfa_reconciliations r
    WHERE r.pfa_account_id = v_pfa_account_id
      AND r.statement_ending_date < v_statement.statement_period_end
    ORDER BY r.statement_ending_date DESC LIMIT 1;

    v_prior_personal_funds := COALESCE(v_prev_recon.prior_personal_funds, 0)
                              - COALESCE(v_prev_recon.current_bank_service_fees, 0);

    v_adjusted_statement_balance := v_statement.closing_balance
                                    - v_outstanding_checks_total - v_outstanding_sf_eft_total
                                    + v_outstanding_deposits_total + v_returned_checks_unreim;
    v_difference := v_adjusted_statement_balance - v_prior_personal_funds;

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
      v_dm_text := format(E'⚠️ PFA reconciliation discrepancy\n\nStatement ending: %s\nClosing balance: $%s\nOutstanding SF EFTs: $%s\nOutstanding deposits: $%s\nAdjusted balance: $%s\nPrior personal funds: $%s\n\nDifference: $%s ❌\n\nReview at https://newtworks.vercel.app/pfa before sending.',
        to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'),
        trim(to_char(v_statement.closing_balance, 'FM999,999,990.00')),
        trim(to_char(v_outstanding_sf_eft_total, 'FM999,999,990.00')),
        trim(to_char(v_outstanding_deposits_total, 'FM999,999,990.00')),
        trim(to_char(v_adjusted_statement_balance, 'FM999,999,990.00')),
        trim(to_char(v_prior_personal_funds, 'FM999,999,990.00')),
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
