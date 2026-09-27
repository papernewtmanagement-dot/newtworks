-- Fix: the hand-coded check returned NULL (not false) for untouched rows, so nothing on the
-- books was ever picked. Scope: rows never posted are only closed when the register writer
-- would otherwise post them (not a possible transfer, dated on/after the writer's start date).
CREATE OR REPLACE FUNCTION public.retire_unclaimed_register_guesses(p_agency_id uuid, p_dry_run boolean DEFAULT true,
                                                                  p_from date DEFAULT '2026-08-01')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_rows jsonb; v_held jsonb; v_led uuid[]; v_reg uuid[];
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _retire_pool (reg_id uuid, ledger_id uuid, txn_date date, amount numeric,
    merchant text, last4 text, hand_touched boolean) ON COMMIT DROP;
  TRUNCATE _retire_pool;

  INSERT INTO _retire_pool
  SELECT c.id, l.id, c.txn_date, c.amount, c.merchant, c.account_last4,
         COALESCE(c.coding_status = 'peter_classified', false)
         OR (l.id IS NOT NULL AND (l.tithe_draw_source IS NOT DISTINCT FROM 'manual'
              OR EXISTS (SELECT 1 FROM transaction_tags tt WHERE tt.journal_line_id = l.id)
              OR EXISTS (SELECT 1 FROM amazon_orders ao WHERE ao.matched_ledger_id = l.id)))
    FROM cash_register_preliminary c
    JOIN LATERAL (SELECT a.id, coa.account_code FROM accounts a JOIN chart_of_accounts coa ON coa.id = a.chart_account_id
                   WHERE a.agency_id = c.agency_id AND a.is_active
                     AND (a.account_number_last4 = c.account_last4 OR c.account_last4 = ANY (a.alternate_last4s))
                   LIMIT 1) acct ON true
    LEFT JOIN ledger l ON l.cash_register_id = c.id
   WHERE c.agency_id = p_agency_id
     AND COALESCE(c.status, '') <> 'reconciled'
     AND ((l.id IS NOT NULL AND l.source = 'cash_register_gl_writer' AND l.statement_id IS NULL)
          OR (l.id IS NULL AND c.txn_date >= p_from AND COALESCE(c.status, '') <> 'possible_transfer'))
     AND EXISTS (SELECT 1 FROM statement_balances sb WHERE sb.agency_id = p_agency_id AND sb.account_code = acct.account_code
                  AND c.txn_date BETWEEN sb.statement_period_start AND sb.statement_period_end)
     AND EXISTS (SELECT 1 FROM statement_balances sb WHERE sb.agency_id = p_agency_id AND sb.account_code = acct.account_code
                  AND c.txn_date + 4 BETWEEN sb.statement_period_start AND sb.statement_period_end);

  SELECT COALESCE(jsonb_agg(jsonb_build_object('date', txn_date, 'amount', amount, 'merchant', merchant,
                   'card', last4, 'was_on_books', ledger_id IS NOT NULL) ORDER BY txn_date), '[]'::jsonb),
         array_agg(ledger_id) FILTER (WHERE ledger_id IS NOT NULL), array_agg(reg_id)
    INTO v_rows, v_led, v_reg
    FROM _retire_pool WHERE NOT hand_touched;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('date', txn_date, 'amount', amount, 'merchant', merchant, 'card', last4)), '[]'::jsonb)
    INTO v_held FROM _retire_pool WHERE hand_touched;

  IF NOT p_dry_run AND v_reg IS NOT NULL THEN
    INSERT INTO ledger_backfill_20260926 SELECT * FROM ledger WHERE id = ANY (COALESCE(v_led, ARRAY[]::uuid[]));
    DELETE FROM ledger WHERE id = ANY (COALESCE(v_led, ARRAY[]::uuid[]));
    UPDATE cash_register_preliminary
       SET status = 'reconciled', reconciled_at = now(), reconciled_journal_entry_id = NULL, updated_at = now(),
           coding_question = 'The statement for this date was read and does not show this exact amount — usually the amount before tip or a temporary hold. The statement line is the one on the books.'
     WHERE id = ANY (v_reg);
  END IF;

  RETURN jsonb_build_object('retired', v_rows, 'left_alone_hand_coded', v_held);
END $$;
DROP FUNCTION IF EXISTS public.retire_unclaimed_register_guesses(uuid, boolean);
