-- The automation runner dispatches internal recipes via run_internal_recipe(),
-- which calls public.<internal_handler>(agency_id uuid, recipe_id uuid) and
-- expects jsonb back with records_processed / output_summary. The original
-- zero-argument, integer-returning version could never have been dispatched.
DROP FUNCTION IF EXISTS public.fn_check_statement_reconciliation();

CREATE OR REPLACE FUNCTION public.fn_check_statement_reconciliation(
  p_agency_id uuid,
  p_recipe_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_alert_count integer := 0;
  v_resolved_count integer := 0;
  r RECORD;
  v_module_ref text;
  v_message text;
  v_exists boolean;
BEGIN
  -- (a) in_period_error: one alert each
  FOR r IN
    SELECT * FROM public.v_statement_reconciliation WHERE finding = 'in_period_error'
  LOOP
    v_module_ref := 'statement_reconciliation:' || r.statement_balance_id;
    SELECT EXISTS (SELECT 1 FROM public.alerts
                   WHERE module_reference = v_module_ref AND is_resolved = false) INTO v_exists;
    IF NOT v_exists THEN
      v_message := 'Account ' || r.account_code || ' (' || COALESCE(r.account_name,'unknown') ||
        ') does not match its ' || to_char(r.statement_period_end,'YYYY-MM-DD') || ' statement close. ' ||
        'Statement closing balance is ' || r.closing_balance || '; the ledger balance as of that date is ' ||
        r.ledger_balance || '. The gap ' ||
        CASE WHEN r.variance_delta >= 0 THEN 'grew' ELSE 'shrank' END ||
        ' by ' || ABS(r.variance_delta) || ' versus the prior statement.';
      INSERT INTO public.alerts (agency_id, alert_type, severity, module_reference, related_id,
                                 title, message, is_read, is_resolved, created_at)
      VALUES (p_agency_id, 'statement_reconciliation_gap', 'high', v_module_ref, r.statement_balance_id,
              'Ledger does not match statement close — ' || r.account_code, v_message, false, false, NOW());
      v_alert_count := v_alert_count + 1;
    END IF;
  END LOOP;

  -- (b) baseline_offset: one alert per account, latest statement only
  FOR r IN
    SELECT DISTINCT ON (account_code) * FROM public.v_statement_reconciliation
    WHERE finding = 'baseline_offset' ORDER BY account_code, statement_period_end DESC
  LOOP
    v_module_ref := 'statement_reconciliation_baseline:' || r.account_code;
    SELECT EXISTS (SELECT 1 FROM public.alerts
                   WHERE module_reference = v_module_ref AND is_resolved = false) INTO v_exists;
    IF NOT v_exists THEN
      v_message := 'Account ' || r.account_code || ' (' || COALESCE(r.account_name,'unknown') ||
        ') carries a constant gap of ' || ABS(r.variance) || ' versus its statement close as of ' ||
        to_char(r.statement_period_end,'YYYY-MM-DD') || '. This points at a missing or wrong opening ' ||
        'balance for the account rather than a new error.';
      INSERT INTO public.alerts (agency_id, alert_type, severity, module_reference, related_id,
                                 title, message, is_read, is_resolved, created_at)
      VALUES (p_agency_id, 'statement_reconciliation_baseline', 'medium', v_module_ref, r.statement_balance_id,
              'Ledger does not match statement close — ' || r.account_code, v_message, false, false, NOW());
      v_alert_count := v_alert_count + 1;
    END IF;
  END LOOP;

  -- (c) ambiguous_account: one alert each
  FOR r IN
    SELECT * FROM public.v_statement_reconciliation WHERE finding = 'ambiguous_account'
  LOOP
    v_module_ref := 'statement_reconciliation_ambiguous:' || r.statement_balance_id;
    SELECT EXISTS (SELECT 1 FROM public.alerts
                   WHERE module_reference = v_module_ref AND is_resolved = false) INTO v_exists;
    IF NOT v_exists THEN
      v_message := 'Statement balance row for account code ' || r.account_code ||
        ' as of ' || to_char(r.statement_period_end,'YYYY-MM-DD') ||
        ' resolves to more than one chart of accounts row. Needs manual disambiguation before it can be reconciled.';
      INSERT INTO public.alerts (agency_id, alert_type, severity, module_reference, related_id,
                                 title, message, is_read, is_resolved, created_at)
      VALUES (p_agency_id, 'statement_reconciliation_ambiguous', 'medium', v_module_ref, r.statement_balance_id,
              'Ambiguous chart-of-accounts match — ' || r.account_code, v_message, false, false, NOW());
      v_alert_count := v_alert_count + 1;
    END IF;
  END LOOP;

  -- (f) auto-resolve anything that now ties
  WITH resolved AS (
    UPDATE public.alerts a
    SET is_resolved = true, resolved_at = NOW()
    WHERE a.is_resolved = false
      AND a.module_reference LIKE 'statement_reconciliation%'
      AND (
        EXISTS (SELECT 1 FROM public.v_statement_reconciliation v
                WHERE v.finding = 'ties'
                  AND (a.module_reference = 'statement_reconciliation:' || v.statement_balance_id
                    OR a.module_reference = 'statement_reconciliation_ambiguous:' || v.statement_balance_id))
        OR EXISTS (SELECT 1 FROM (
                     SELECT DISTINCT ON (account_code) account_code, finding
                     FROM public.v_statement_reconciliation
                     ORDER BY account_code, statement_period_end DESC) latest
                   WHERE latest.finding = 'ties'
                     AND a.module_reference = 'statement_reconciliation_baseline:' || latest.account_code)
      )
    RETURNING 1
  )
  SELECT count(*) INTO v_resolved_count FROM resolved;

  RETURN jsonb_build_object(
    'records_processed', v_alert_count,
    'output_summary', 'Statement reconciliation check: ' || v_alert_count ||
                      ' new alert(s) written, ' || v_resolved_count || ' auto-resolved.',
    'alerts_written', v_alert_count,
    'alerts_resolved', v_resolved_count
  );
END;
$fn$;
