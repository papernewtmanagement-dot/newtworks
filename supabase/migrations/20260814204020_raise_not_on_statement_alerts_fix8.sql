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
  -- Pass 1 (unchanged): cash-register rows that WERE posted to the ledger and
  -- never got claimed by a statement line covering their period.
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

  -- FIX 8: pass 2 — register rows suppressed as 'possible_transfer' (which
  -- never got a ledger row, so pass 1's join never sees them) whose date
  -- falls inside a statement period that HAS been ingested, and that no
  -- statement line ever matched. These would otherwise never surface.
  FOR rec IN
    SELECT ra.id AS account_id, ra.account_name, sb.id AS statement_balance_id,
           sb.statement_period_start, sb.statement_period_end,
           count(*) AS n,
           sum(c.amount) AS total_amount
    FROM cash_register_preliminary c
    JOIN accounts ra ON (ra.account_number_last4 = c.account_last4 OR c.account_last4 = ANY(ra.alternate_last4s))
    JOIN statement_balances sb ON sb.agency_id = c.agency_id
      AND (sb.account_last4 = ra.account_number_last4 OR sb.account_last4 = ANY(COALESCE(ra.alternate_last4s, ARRAY[]::text[])))
      AND c.txn_date BETWEEN sb.statement_period_start AND sb.statement_period_end
    WHERE c.agency_id = p_agency_id
      AND c.status = 'possible_transfer'
      AND NOT EXISTS (
        SELECT 1 FROM statements s
        WHERE s.agency_id = c.agency_id AND s.account_id = ra.id
          AND round(abs(s.amount),2) = round(c.amount,2)
          AND (CASE WHEN s.transaction_type IN ('withdrawal','charge','debit') THEN 'debit'
                    WHEN s.transaction_type IN ('deposit','payment_or_credit','credit','payment') THEN 'credit'
                    ELSE NULL END) = c.direction
          AND abs(s.transaction_date - c.txn_date) <= 4
      )
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
        rec.account_name || ' — ' || rec.n || ' possible transfer(s) not confirmed by the statement',
        'The statement covering ' || rec.statement_period_start || ' to ' || rec.statement_period_end ||
          ' has arrived, and ' || rec.n || ' transaction(s) totaling ' ||
          to_char(rec.total_amount, 'FM$999,999,990.00') || ' flagged as a transfer between our own accounts were never confirmed by it.',
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
