-- ============================================================================
-- pfa_send_reconciliation RPC + recipe auto-send wiring
--
-- The heavy lifting (PDF gen + Gmail send + recon row update) lives in the
-- pfa-reconciliation-send edge function. This RPC is the SECURITY DEFINER
-- entry point from the UI button; the recipe calls the edge function directly.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.pfa_send_reconciliation(
  p_reconciliation_id uuid,
  p_force             boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_auth_uid       uuid;
  v_role           text;
  v_agency_id      uuid;
  v_shared_secret  text;
  v_recon_agency   uuid;
  v_resp           jsonb;
BEGIN
  v_auth_uid := auth.uid();
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT u.agency_id, u.role INTO v_agency_id, v_role
  FROM public.users u WHERE u.auth_user_id = v_auth_uid;
  IF v_role NOT IN ('owner','manager') THEN
    RAISE EXCEPTION 'only owner or manager can send reconciliations' USING ERRCODE = '42501';
  END IF;

  -- Verify recon exists and belongs to caller's agency
  SELECT a.agency_id INTO v_recon_agency
  FROM public.pfa_reconciliations r
  JOIN public.pfa_accounts a ON a.id = r.pfa_account_id
  WHERE r.id = p_reconciliation_id;
  IF v_recon_agency IS NULL THEN
    RAISE EXCEPTION 'reconciliation not found' USING ERRCODE = 'P0001';
  END IF;
  IF v_recon_agency <> v_agency_id THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  SELECT setting_value INTO v_shared_secret
  FROM public.settings
  WHERE agency_id = v_agency_id AND setting_key = 'automation_runner_cron_secret';
  IF v_shared_secret IS NULL THEN
    RAISE EXCEPTION 'automation_runner_cron_secret not configured';
  END IF;

  PERFORM extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '10000');
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '60000');

  SELECT (extensions.http_post(
    'https://vulhdujhbwvibbojiimi.supabase.co/functions/v1/pfa-reconciliation-send',
    jsonb_build_object(
      'agency_id',         v_agency_id,
      'shared_secret',     v_shared_secret,
      'reconciliation_id', p_reconciliation_id,
      'force',             p_force
    )::text,
    'application/json'
  )).content::jsonb INTO v_resp;

  RETURN COALESCE(v_resp, jsonb_build_object('ok', false, 'error', 'no response from edge function'));
END;
$$;

REVOKE ALL ON FUNCTION public.pfa_send_reconciliation(uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pfa_send_reconciliation(uuid, boolean) TO authenticated;


-- ============================================================================
-- Update pfa_monthly_reconciliation: auto-send clean recons via edge function.
-- Discrepancy recons still fire alert + Telegram DM for manual review.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.pfa_monthly_reconciliation(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_pfa_account_id             uuid;
  v_statement                  record;
  v_prev_recon                 record;
  v_prior_personal_funds       numeric;
  v_current_bank_service_fees  numeric;
  v_outstanding_checks_total   numeric;
  v_outstanding_sf_eft_total   numeric;
  v_outstanding_deposits_total numeric;
  v_returned_checks_unreim     numeric := 0;
  v_adjusted_statement_balance numeric;
  v_difference                 numeric;
  v_recon_id                   uuid;
  v_processed_count            int := 0;
  v_peter_tg                   bigint;
  v_dm_text                    text;
  v_alert_title                text;
  v_alert_message              text;
  v_results                    jsonb := '[]'::jsonb;
  v_shared_secret              text;
  v_send_resp                  jsonb;
  v_send_ok                    boolean;
  v_send_status                text;
BEGIN
  SELECT id INTO v_pfa_account_id
  FROM public.pfa_accounts
  WHERE agency_id = p_agency_id AND is_active = true LIMIT 1;

  IF v_pfa_account_id IS NULL THEN
    RETURN jsonb_build_object('records_processed', 0, 'output_summary', 'No active PFA account.');
  END IF;

  SELECT ttm.telegram_user_id INTO v_peter_tg
  FROM public.team_telegram_map ttm
  JOIN public.team t ON t.id = ttm.team_id
  WHERE t.first_name='Peter' AND t.last_name='Story' LIMIT 1;
  v_peter_tg := COALESCE(v_peter_tg, 7778113542);

  SELECT setting_value INTO v_shared_secret
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'automation_runner_cron_secret';

  FOR v_statement IN
    SELECT s.id, s.statement_period_start, s.statement_period_end, s.closing_balance
    FROM public.pfa_bank_statements s
    WHERE s.pfa_account_id = v_pfa_account_id
      AND NOT EXISTS (
        SELECT 1 FROM public.pfa_reconciliations r WHERE r.statement_id = s.id
      )
    ORDER BY s.statement_period_end
  LOOP
    v_processed_count := v_processed_count + 1;

    SELECT COALESCE(SUM(debit_amount), 0) INTO v_outstanding_sf_eft_total
    FROM public.pfa_transactions
    WHERE pfa_account_id = v_pfa_account_id
      AND transaction_type = 'State Farm EFT'
      AND voided_at IS NULL
      AND transaction_date <= v_statement.statement_period_end
      AND (cleared = false OR cleared_date > v_statement.statement_period_end);

    SELECT COALESCE(SUM(credit_amount), 0) INTO v_outstanding_deposits_total
    FROM public.pfa_transactions
    WHERE pfa_account_id = v_pfa_account_id
      AND credit_amount IS NOT NULL
      AND voided_at IS NULL
      AND transaction_date <= v_statement.statement_period_end
      AND (cleared = false OR cleared_date > v_statement.statement_period_end);

    SELECT COALESCE(SUM(debit_amount), 0) INTO v_outstanding_checks_total
    FROM public.pfa_transactions
    WHERE pfa_account_id = v_pfa_account_id
      AND debit_amount IS NOT NULL
      AND transaction_type <> 'State Farm EFT'
      AND voided_at IS NULL
      AND transaction_date <= v_statement.statement_period_end
      AND (cleared = false OR cleared_date > v_statement.statement_period_end);

    SELECT COALESCE(SUM(debit_amount), 0) INTO v_current_bank_service_fees
    FROM public.pfa_transactions
    WHERE pfa_account_id = v_pfa_account_id
      AND transaction_type = 'Bank Service Fee'
      AND voided_at IS NULL
      AND cleared = true
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
                                    - v_outstanding_checks_total
                                    - v_outstanding_sf_eft_total
                                    + v_outstanding_deposits_total
                                    + v_returned_checks_unreim;
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
      'Auto-computed by pfa_monthly_reconciliation.',
      now()
    )
    RETURNING id INTO v_recon_id;

    -- Branch on clean vs. discrepancy
    IF abs(v_difference) < 0.005 AND v_shared_secret IS NOT NULL THEN
      -- CLEAN → auto-send
      PERFORM extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS', '10000');
      PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '60000');
      BEGIN
        SELECT (extensions.http_post(
          'https://vulhdujhbwvibbojiimi.supabase.co/functions/v1/pfa-reconciliation-send',
          jsonb_build_object(
            'agency_id',         p_agency_id,
            'shared_secret',     v_shared_secret,
            'reconciliation_id', v_recon_id,
            'force',             false
          )::text,
          'application/json'
        )).content::jsonb INTO v_send_resp;
        v_send_ok := COALESCE((v_send_resp->>'ok')::boolean, false);
        v_send_status := COALESCE(v_send_resp->>'status', 'unknown');
      EXCEPTION WHEN OTHERS THEN
        v_send_ok := false;
        v_send_status := 'exception: ' || SQLERRM;
        v_send_resp := jsonb_build_object('ok', false, 'error', SQLERRM);
      END;

      IF v_send_ok AND v_send_status = 'sent' THEN
        v_dm_text := format(
          E'✅ PFA reconciliation auto-sent\n\nStatement ending: %s\nDifference: $0.00 (clean)\nSent to peter.story.yrru@statefarm.com\n\nMessage ID: %s',
          to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'),
          COALESCE(v_send_resp->>'message_id', 'unknown')
        );
      ELSE
        v_alert_title := 'PFA reconciliation SEND FAILED for ' || to_char(v_statement.statement_period_end, 'FMMonth YYYY');
        v_alert_message := format('Reconciliation for %s computed clean ($0.00 diff) but auto-send failed: %s. Retry from Deposits → Reconciliations → Send to SF.',
          to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'),
          COALESCE(v_send_resp->>'error', v_send_status));
        INSERT INTO public.alerts (
          agency_id, alert_type, severity, title, message, module_reference,
          is_read, is_resolved, related_id, created_at
        ) VALUES (
          p_agency_id, 'pfa_reconciliation_send_failed', 'warning',
          v_alert_title, v_alert_message,
          'pfa_reconciliation:' || v_recon_id::text,
          false, false, v_recon_id, now()
        );
        v_dm_text := format(
          E'⚠️ PFA auto-send failed\n\nStatement ending: %s\nDifference: $0.00 (clean)\nSend error: %s\n\nRetry at https://newtworks.vercel.app/pfa (Deposits → Reconciliations → Send to SF).',
          to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'),
          COALESCE(v_send_resp->>'error', v_send_status)
        );
      END IF;

    ELSE
      -- DISCREPANCY → alert + DM Peter for manual review
      v_alert_title := '⚠️ PFA reconciliation DISCREPANCY — ' || to_char(v_statement.statement_period_end, 'FMMonth YYYY');
      v_alert_message := format('The reconciliation for the PFA statement ending %s has a difference of $%s. Do NOT send to SF until reviewed. Open Deposits → Reconciliations and expand the row to see the waterfall + outstanding items.',
        to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'),
        trim(to_char(v_difference, 'FM999,999,990.00')));
      INSERT INTO public.alerts (
        agency_id, alert_type, severity, title, message, module_reference,
        is_read, is_resolved, related_id, created_at
      ) VALUES (
        p_agency_id, 'pfa_reconciliation_ready', 'warning',
        v_alert_title, v_alert_message,
        'pfa_reconciliation:' || v_recon_id::text,
        false, false, v_recon_id, now()
      );
      v_dm_text := format(E'⚠️ PFA reconciliation discrepancy\n\nStatement ending: %s\nClosing balance: $%s\nOutstanding SF EFTs: $%s\nOutstanding deposits: $%s\nAdjusted balance: $%s\nPrior personal funds: $%s\n\nDifference: $%s ❌\n\nReview at https://newtworks.vercel.app/pfa before sending.',
        to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'),
        trim(to_char(v_statement.closing_balance, 'FM999,999,990.00')),
        trim(to_char(v_outstanding_sf_eft_total, 'FM999,999,990.00')),
        trim(to_char(v_outstanding_deposits_total, 'FM999,999,990.00')),
        trim(to_char(v_adjusted_statement_balance, 'FM999,999,990.00')),
        trim(to_char(v_prior_personal_funds, 'FM999,999,990.00')),
        trim(to_char(v_difference, 'FM999,999,990.00')));
    END IF;

    BEGIN
      PERFORM public.telegram_send_message_v2(v_peter_tg, v_dm_text, 'paper_newt');
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'PFA recon % Telegram DM failed: %', v_recon_id, SQLERRM;
    END;

    v_results := v_results || jsonb_build_object(
      'reconciliation_id', v_recon_id,
      'statement_period_end', v_statement.statement_period_end,
      'adjusted_balance', v_adjusted_statement_balance,
      'difference', v_difference,
      'clean', (abs(v_difference) < 0.005),
      'auto_sent', COALESCE(v_send_ok AND v_send_status = 'sent', false)
    );
  END LOOP;

  IF v_processed_count = 0 THEN
    RETURN jsonb_build_object('records_processed', 0, 'output_summary', 'No unreconciled statements.');
  END IF;

  RETURN jsonb_build_object(
    'records_processed', v_processed_count,
    'output_summary', format('Auto-computed %s reconciliation(s).', v_processed_count),
    'results', v_results
  );
END;
$$;

