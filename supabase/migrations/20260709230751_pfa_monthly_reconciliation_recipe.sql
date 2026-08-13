-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-09 23:07:51 UTC (ledger name: pfa_monthly_reconciliation_recipe) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260709230751.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- ============================================================================
-- pfa_monthly_reconciliation: auto-compute reconciliation on new statements
--
-- Fires daily at 12 PM CT (17 UTC in CDT, ~11 AM CT in CST — DST drift
-- accepted for MVP). Scans for pfa_bank_statements rows that don't have a
-- matching pfa_reconciliations row and computes the reconciliation math:
--
--   adjusted_statement_balance = closing_balance
--                               - outstanding_checks (non-SF debits)
--                               - outstanding_sf_eft
--                               + outstanding_deposits
--                               + returned_checks_unreimbursed
--   difference_to_reconcile = adjusted_statement_balance - prior_personal_funds
--
-- Prior personal funds carry from previous reconciliation
-- (prior_personal_funds - current_bank_service_fees). First-ever recon = $0.
--
-- Actual PDF generation + SF email is NOT done here — the Deno edge runtime
-- doesn't have a clean path for the specific SF PDF layout. On completion,
-- fires an alert + Telegram DM to Peter to review and trigger the send via
-- Claude/workbench.
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
BEGIN
  SELECT id INTO v_pfa_account_id
  FROM public.pfa_accounts
  WHERE agency_id = p_agency_id AND is_active = true
  LIMIT 1;

  IF v_pfa_account_id IS NULL THEN
    RETURN jsonb_build_object('records_processed', 0, 'output_summary', 'No active PFA account.');
  END IF;

  -- Peter's Telegram DM chat (fallback to hardcoded id)
  SELECT ttm.telegram_user_id INTO v_peter_tg
  FROM public.team_telegram_map ttm
  JOIN public.team t ON t.id = ttm.team_id
  WHERE t.first_name='Peter' AND t.last_name='Story' LIMIT 1;
  v_peter_tg := COALESCE(v_peter_tg, 7778113542);

  -- Iterate statements without a reconciliation
  FOR v_statement IN
    SELECT s.id, s.statement_period_start, s.statement_period_end, s.closing_balance
    FROM public.pfa_bank_statements s
    WHERE s.pfa_account_id = v_pfa_account_id
      AND NOT EXISTS (
        SELECT 1 FROM public.pfa_reconciliations r
        WHERE r.statement_id = s.id
      )
    ORDER BY s.statement_period_end
  LOOP
    v_processed_count := v_processed_count + 1;

    -- Outstanding SF EFTs (uncleared as of statement end)
    SELECT COALESCE(SUM(debit_amount), 0) INTO v_outstanding_sf_eft_total
    FROM public.pfa_transactions
    WHERE pfa_account_id = v_pfa_account_id
      AND transaction_type = 'State Farm EFT'
      AND voided_at IS NULL
      AND transaction_date <= v_statement.statement_period_end
      AND (cleared = false OR cleared_date > v_statement.statement_period_end);

    -- Outstanding deposits (uncleared credits as of statement end)
    SELECT COALESCE(SUM(credit_amount), 0) INTO v_outstanding_deposits_total
    FROM public.pfa_transactions
    WHERE pfa_account_id = v_pfa_account_id
      AND credit_amount IS NOT NULL
      AND voided_at IS NULL
      AND transaction_date <= v_statement.statement_period_end
      AND (cleared = false OR cleared_date > v_statement.statement_period_end);

    -- Outstanding "checks" bucket (all uncleared non-SF-EFT debits as of statement end).
    -- For PFA, this is typically zero but catches Misc Withdrawal, Bank Service Fee,
    -- NSF, Returned Check outstanding items.
    SELECT COALESCE(SUM(debit_amount), 0) INTO v_outstanding_checks_total
    FROM public.pfa_transactions
    WHERE pfa_account_id = v_pfa_account_id
      AND debit_amount IS NOT NULL
      AND transaction_type <> 'State Farm EFT'
      AND voided_at IS NULL
      AND transaction_date <= v_statement.statement_period_end
      AND (cleared = false OR cleared_date > v_statement.statement_period_end);

    -- Current-period bank service fees (cleared, within statement period)
    SELECT COALESCE(SUM(debit_amount), 0) INTO v_current_bank_service_fees
    FROM public.pfa_transactions
    WHERE pfa_account_id = v_pfa_account_id
      AND transaction_type = 'Bank Service Fee'
      AND voided_at IS NULL
      AND cleared = true
      AND cleared_date >= v_statement.statement_period_start
      AND cleared_date <= v_statement.statement_period_end;

    -- Prior personal funds = last recon's carryover minus its service fees.
    -- First-ever reconciliation: $0.
    SELECT r.prior_personal_funds, r.current_bank_service_fees INTO v_prev_recon
    FROM public.pfa_reconciliations r
    WHERE r.pfa_account_id = v_pfa_account_id
      AND r.statement_ending_date < v_statement.statement_period_end
    ORDER BY r.statement_ending_date DESC
    LIMIT 1;

    v_prior_personal_funds := COALESCE(v_prev_recon.prior_personal_funds, 0)
                              - COALESCE(v_prev_recon.current_bank_service_fees, 0);

    -- Compute adjusted balance and difference
    v_adjusted_statement_balance := v_statement.closing_balance
                                    - v_outstanding_checks_total
                                    - v_outstanding_sf_eft_total
                                    + v_outstanding_deposits_total
                                    + v_returned_checks_unreim;
    v_difference := v_adjusted_statement_balance - v_prior_personal_funds;

    -- Insert reconciliation row
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
      'Auto-computed by pfa_monthly_reconciliation. Review numbers before sending to SF.',
      now()
    )
    RETURNING id INTO v_recon_id;

    -- Alert + Telegram DM Peter
    IF abs(v_difference) < 0.005 THEN
      v_alert_title := 'PFA reconciliation ready — ' || to_char(v_statement.statement_period_end, 'FMMonth YYYY') || ' (clean)';
      v_alert_message := format('The reconciliation for the PFA statement ending %s balances to $0.00. Review in Deposits → Reconciliations, then ask Peter''s assistant (Claude) to generate the PDF and email SF.',
        to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'));
      v_dm_text := format(E'✅ PFA reconciliation ready\n\nStatement ending: %s\nAdjusted balance: $%s\nPersonal funds carryover: $%s\nDifference: $0.00 — clean\n\nReview at https://newtworks.vercel.app/pfa (Deposits → Reconciliations) and DM me when ready to send to SF.',
        to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'),
        trim(to_char(v_adjusted_statement_balance, 'FM999,999,990.00')),
        trim(to_char(v_prior_personal_funds, 'FM999,999,990.00')));
    ELSE
      v_alert_title := '⚠️ PFA reconciliation DISCREPANCY — ' || to_char(v_statement.statement_period_end, 'FMMonth YYYY');
      v_alert_message := format('The reconciliation for the PFA statement ending %s has a difference of $%s. Do NOT send to SF until reviewed. Open Deposits → Reconciliations and expand the row to see the waterfall + outstanding items.',
        to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'),
        trim(to_char(v_difference, 'FM999,999,990.00')));
      v_dm_text := format(E'⚠️ PFA reconciliation discrepancy\n\nStatement ending: %s\nClosing balance: $%s\nOutstanding SF EFTs: $%s\nOutstanding deposits: $%s\nAdjusted balance: $%s\nPrior personal funds: $%s\n\nDifference: $%s ❌\n\nReview at https://newtworks.vercel.app/pfa before sending. Might be a missing deposit, a duplicate, or a real reconciling item.',
        to_char(v_statement.statement_period_end, 'FMMon DD, YYYY'),
        trim(to_char(v_statement.closing_balance, 'FM999,999,990.00')),
        trim(to_char(v_outstanding_sf_eft_total, 'FM999,999,990.00')),
        trim(to_char(v_outstanding_deposits_total, 'FM999,999,990.00')),
        trim(to_char(v_adjusted_statement_balance, 'FM999,999,990.00')),
        trim(to_char(v_prior_personal_funds, 'FM999,999,990.00')),
        trim(to_char(v_difference, 'FM999,999,990.00')));
    END IF;

    INSERT INTO public.alerts (
      agency_id, alert_type, severity, title, message, module_reference,
      is_read, is_resolved, related_id, created_at
    ) VALUES (
      p_agency_id, 'pfa_reconciliation_ready',
      CASE WHEN abs(v_difference) < 0.005 THEN 'info' ELSE 'warning' END,
      v_alert_title, v_alert_message,
      'pfa_reconciliation:' || v_recon_id::text,
      false, false, v_recon_id, now()
    );

    BEGIN
      PERFORM public.telegram_send_message_v2(v_peter_tg, v_dm_text, 'paper_newt');
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'PFA recon % created, Telegram DM failed: %', v_recon_id, SQLERRM;
    END;

    v_results := v_results || jsonb_build_object(
      'reconciliation_id', v_recon_id,
      'statement_period_end', v_statement.statement_period_end,
      'adjusted_balance', v_adjusted_statement_balance,
      'difference', v_difference,
      'clean', (abs(v_difference) < 0.005)
    );
  END LOOP;

  IF v_processed_count = 0 THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', 'No unreconciled statements.'
    );
  END IF;

  RETURN jsonb_build_object(
    'records_processed', v_processed_count,
    'output_summary', format('Auto-computed %s reconciliation(s).', v_processed_count),
    'results', v_results
  );
END;
$$;


-- ============================================================================
-- pfa_recompute_reconciliation: owner/manager can force a recompute for a
-- specific reconciliation. Fires from the "Recompute" button in the UI.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.pfa_recompute_reconciliation(p_reconciliation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_auth_uid                   uuid;
  v_agency_id                  uuid;
  v_role                       text;
  v_recon                      record;
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
BEGIN
  v_auth_uid := auth.uid();
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT u.agency_id, u.role INTO v_agency_id, v_role
  FROM public.users u WHERE u.auth_user_id = v_auth_uid;
  IF v_role NOT IN ('owner','manager') THEN
    RAISE EXCEPTION 'only owner or manager can recompute reconciliations' USING ERRCODE = '42501';
  END IF;

  SELECT r.id, r.pfa_account_id, r.statement_id, r.statement_ending_date, a.agency_id
  INTO v_recon
  FROM public.pfa_reconciliations r
  JOIN public.pfa_accounts a ON a.id = r.pfa_account_id
  WHERE r.id = p_reconciliation_id;
  IF v_recon.id IS NULL THEN
    RAISE EXCEPTION 'reconciliation not found' USING ERRCODE = 'P0001';
  END IF;
  IF v_recon.agency_id <> v_agency_id THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  SELECT id, statement_period_start, statement_period_end, closing_balance
  INTO v_statement
  FROM public.pfa_bank_statements
  WHERE id = v_recon.statement_id;
  IF v_statement.id IS NULL THEN
    RAISE EXCEPTION 'linked statement not found' USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(SUM(debit_amount), 0) INTO v_outstanding_sf_eft_total
  FROM public.pfa_transactions
  WHERE pfa_account_id = v_recon.pfa_account_id
    AND transaction_type = 'State Farm EFT'
    AND voided_at IS NULL
    AND transaction_date <= v_statement.statement_period_end
    AND (cleared = false OR cleared_date > v_statement.statement_period_end);

  SELECT COALESCE(SUM(credit_amount), 0) INTO v_outstanding_deposits_total
  FROM public.pfa_transactions
  WHERE pfa_account_id = v_recon.pfa_account_id
    AND credit_amount IS NOT NULL
    AND voided_at IS NULL
    AND transaction_date <= v_statement.statement_period_end
    AND (cleared = false OR cleared_date > v_statement.statement_period_end);

  SELECT COALESCE(SUM(debit_amount), 0) INTO v_outstanding_checks_total
  FROM public.pfa_transactions
  WHERE pfa_account_id = v_recon.pfa_account_id
    AND debit_amount IS NOT NULL
    AND transaction_type <> 'State Farm EFT'
    AND voided_at IS NULL
    AND transaction_date <= v_statement.statement_period_end
    AND (cleared = false OR cleared_date > v_statement.statement_period_end);

  SELECT COALESCE(SUM(debit_amount), 0) INTO v_current_bank_service_fees
  FROM public.pfa_transactions
  WHERE pfa_account_id = v_recon.pfa_account_id
    AND transaction_type = 'Bank Service Fee'
    AND voided_at IS NULL
    AND cleared = true
    AND cleared_date >= v_statement.statement_period_start
    AND cleared_date <= v_statement.statement_period_end;

  SELECT r.prior_personal_funds, r.current_bank_service_fees INTO v_prev_recon
  FROM public.pfa_reconciliations r
  WHERE r.pfa_account_id = v_recon.pfa_account_id
    AND r.statement_ending_date < v_statement.statement_period_end
  ORDER BY r.statement_ending_date DESC
  LIMIT 1;

  v_prior_personal_funds := COALESCE(v_prev_recon.prior_personal_funds, 0)
                            - COALESCE(v_prev_recon.current_bank_service_fees, 0);

  v_adjusted_statement_balance := v_statement.closing_balance
                                  - v_outstanding_checks_total
                                  - v_outstanding_sf_eft_total
                                  + v_outstanding_deposits_total
                                  + v_returned_checks_unreim;
  v_difference := v_adjusted_statement_balance - v_prior_personal_funds;

  UPDATE public.pfa_reconciliations
  SET statement_ending_balance    = v_statement.closing_balance,
      outstanding_checks_total    = v_outstanding_checks_total,
      outstanding_sf_eft_total    = v_outstanding_sf_eft_total,
      outstanding_deposits_total  = v_outstanding_deposits_total,
      returned_checks_unreimbursed = v_returned_checks_unreim,
      adjusted_statement_balance  = v_adjusted_statement_balance,
      prior_personal_funds        = v_prior_personal_funds,
      current_bank_service_fees   = v_current_bank_service_fees,
      difference_to_reconcile     = v_difference,
      reconciled_at               = now(),
      updated_at                  = now()
  WHERE id = v_recon.id;

  RETURN jsonb_build_object(
    'ok', true,
    'reconciliation_id', v_recon.id,
    'adjusted_statement_balance', v_adjusted_statement_balance,
    'difference_to_reconcile', v_difference,
    'clean', (abs(v_difference) < 0.005)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pfa_recompute_reconciliation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pfa_recompute_reconciliation(uuid) TO authenticated;


-- ============================================================================
-- Install the automation recipe (daily 12 PM CT ~= 17:00 UTC in CDT)
-- ============================================================================
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description,
  trigger_type, cron_expression,
  internal_handler, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'PFA Monthly Reconciliation',
  'Daily 12 PM CT: computes reconciliation for any PFA statement not yet reconciled. Alerts + Telegram-DMs Peter with the difference. Send-to-SF step remains a Claude/workbench flow triggered manually by Peter.',
  'cron', '0 17 * * *',
  'pfa_monthly_reconciliation', true
);

-- Immediate smoke test: run the handler now against the current data
SELECT public.pfa_monthly_reconciliation(
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  (SELECT id FROM public.automation_recipes WHERE recipe_name = 'PFA Monthly Reconciliation' LIMIT 1)
) AS smoke_test;
