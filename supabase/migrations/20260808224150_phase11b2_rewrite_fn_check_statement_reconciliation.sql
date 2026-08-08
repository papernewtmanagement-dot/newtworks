CREATE OR REPLACE FUNCTION public.fn_check_statement_reconciliation(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_alert_count integer := 0;
  v_resolved_count integer := 0;
  r RECORD;
  v_module_ref text;
  v_message text;
  v_exists boolean;
BEGIN
  -- (a) variance: one alert each
  FOR r IN
    SELECT * FROM public.v_statement_reconciliation WHERE finding = 'variance'
  LOOP
    v_module_ref := 'statement_reconciliation:' || r.statement_balance_id;
    SELECT EXISTS (SELECT 1 FROM public.alerts
                   WHERE module_reference = v_module_ref AND is_resolved = false) INTO v_exists;
    IF NOT v_exists THEN
      v_message := 'Account ' || r.account_code || ' (' || COALESCE(r.account_name,'unknown') ||
        ') does not reconcile for the statement period ending ' || to_char(r.statement_period_end,'YYYY-MM-DD') || '. ' ||
        'Statement closing balance is ' || r.closing_balance || '; opening balance plus that period''s ' ||
        r.transaction_count || ' transaction(s) computes to ' || r.computed_closing ||
        ' — a variance of ' || r.variance || '.';
      INSERT INTO public.alerts (agency_id, alert_type, severity, module_reference, related_id,
                                 title, message, is_read, is_resolved, created_at)
      VALUES (p_agency_id, 'statement_reconciliation_gap', 'high', v_module_ref, r.statement_balance_id,
              'Statement arithmetic does not close — ' || r.account_code, v_message, false, false, NOW());
      v_alert_count := v_alert_count + 1;
    END IF;
  END LOOP;

  -- (b) unknown_transaction_type: one alert each
  FOR r IN
    SELECT * FROM public.v_statement_reconciliation WHERE finding = 'unknown_transaction_type'
  LOOP
    v_module_ref := 'statement_reconciliation_unknown_type:' || r.statement_balance_id;
    SELECT EXISTS (SELECT 1 FROM public.alerts
                   WHERE module_reference = v_module_ref AND is_resolved = false) INTO v_exists;
    IF NOT v_exists THEN
      v_message := 'Account ' || r.account_code || ' (' || COALESCE(r.account_name,'unknown') ||
        ') has at least one statement transaction in the period ending ' || to_char(r.statement_period_end,'YYYY-MM-DD') ||
        ' with a transaction_type outside the recognized set. That period''s arithmetic could not be computed ' ||
        'and needs manual review before it can be reconciled.';
      INSERT INTO public.alerts (agency_id, alert_type, severity, module_reference, related_id,
                                 title, message, is_read, is_resolved, created_at)
      VALUES (p_agency_id, 'statement_reconciliation_unknown_type', 'medium', v_module_ref, r.statement_balance_id,
              'Unrecognized transaction type — ' || r.account_code, v_message, false, false, NOW());
      v_alert_count := v_alert_count + 1;
    END IF;
  END LOOP;

  -- (c) auto-resolve anything that no longer has a variance or unknown-type finding
  WITH resolved AS (
    UPDATE public.alerts a
    SET is_resolved = true, resolved_at = NOW()
    WHERE a.is_resolved = false
      AND a.module_reference LIKE 'statement_reconciliation%'
      AND NOT EXISTS (
        SELECT 1 FROM public.v_statement_reconciliation v
        WHERE v.finding IN ('variance','unknown_transaction_type')
          AND (a.module_reference = 'statement_reconciliation:' || v.statement_balance_id
            OR a.module_reference = 'statement_reconciliation_unknown_type:' || v.statement_balance_id)
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
$function$;
