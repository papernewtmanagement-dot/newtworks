CREATE OR REPLACE FUNCTION public.raise_not_on_statement_alerts(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  rec record;
  v_count int := 0;
BEGIN
  FOR rec IN
    SELECT ra.id AS account_id, ra.account_name, sb.id AS statement_balance_id,
           sb.statement_period_start, sb.statement_period_end,
           count(*) AS n,
           sum(CASE WHEN l.debit > 0 THEN l.debit ELSE l.credit END) AS total_amount
    FROM ledger l
    JOIN cash_register_preliminary c ON c.id = l.cash_register_id
    JOIN accounts ra ON (ra.account_number_last4 = c.account_last4 OR c.account_last4 = ANY(ra.alternate_last4s))
    JOIN statement_balances sb ON sb.agency_id = l.agency_id
      AND (sb.account_last4 = ra.account_number_last4 OR sb.account_last4 = ANY(COALESCE(ra.alternate_last4s, ARRAY[]::text[])))
      AND l.entry_date BETWEEN sb.statement_period_start AND sb.statement_period_end
    WHERE l.agency_id = p_agency_id
      AND l.cash_register_id IS NOT NULL
      AND l.statement_id IS NULL
    GROUP BY ra.id, ra.account_name, sb.id, sb.statement_period_start, sb.statement_period_end
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM alerts a
      WHERE a.agency_id = p_agency_id
        AND a.module_reference = 'financials'
        AND a.related_id = rec.statement_balance_id
        AND a.is_resolved IS NOT TRUE
    ) THEN
      INSERT INTO alerts (id, agency_id, alert_type, severity, title, message, module_reference, related_id, is_read, is_resolved, created_at)
      VALUES (
        gen_random_uuid(), p_agency_id, 'not_on_statement', 'medium',
        rec.account_name || ' — ' || rec.n || ' transaction(s) not on the statement',
        'The statement covering ' || rec.statement_period_start || ' to ' || rec.statement_period_end ||
          ' has arrived, and ' || rec.n || ' transaction(s) totaling ' ||
          to_char(rec.total_amount, 'FM$999,999,990.00') || ' seen in the bank alerts were not on it.',
        'financials', rec.statement_balance_id, false, false, now()
      );
      v_count := v_count + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object(
    'ok', true,
    'records_processed', v_count,
    'output_summary', v_count || ' not-on-statement alert(s) raised'
  );
END;
$function$;
