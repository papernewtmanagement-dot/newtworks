-- Peter 2026-09-26: a card alert often carries the amount before tip (Izumi $40.32 -> $48.32,
-- Parry's $119.93 -> $134.93) or a small hold ($1.00 Sam's). The statement writer only claims an
-- exact amount, so the early guess stayed on the books next to the real statement line.
-- Rule: once the statements covering a register row's date AND the four days after it have been
-- read, the statement is the full record for that account. A guess it did not claim is retired
-- (taken out of the ledger, register row marked reconciled), and a register row that never posted
-- is closed without posting. Rows someone coded by hand, tagged, drew from the tithe pool, or
-- matched to an Amazon order are left alone and listed.
CREATE OR REPLACE FUNCTION public.retire_unclaimed_register_guesses(p_agency_id uuid, p_dry_run boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_rows jsonb; v_held jsonb; v_led uuid[]; v_reg uuid[];
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _retire_pool (reg_id uuid, ledger_id uuid, txn_date date, amount numeric,
    merchant text, last4 text, hand_touched boolean) ON COMMIT DROP;
  TRUNCATE _retire_pool;

  INSERT INTO _retire_pool
  SELECT c.id, l.id, c.txn_date, c.amount, c.merchant, c.account_last4,
         (c.coding_status = 'peter_classified'
          OR (l.id IS NOT NULL AND (l.tithe_draw_source = 'manual'
              OR EXISTS (SELECT 1 FROM transaction_tags tt WHERE tt.journal_line_id = l.id)
              OR EXISTS (SELECT 1 FROM amazon_orders ao WHERE ao.matched_ledger_id = l.id))))
    FROM cash_register_preliminary c
    JOIN LATERAL (SELECT a.id, coa.account_code FROM accounts a JOIN chart_of_accounts coa ON coa.id = a.chart_account_id
                   WHERE a.agency_id = c.agency_id AND a.is_active
                     AND (a.account_number_last4 = c.account_last4 OR c.account_last4 = ANY (a.alternate_last4s))
                   LIMIT 1) acct ON true
    LEFT JOIN ledger l ON l.cash_register_id = c.id
   WHERE c.agency_id = p_agency_id
     AND COALESCE(c.status, '') <> 'reconciled'
     AND (l.id IS NULL OR (l.source = 'cash_register_gl_writer' AND l.statement_id IS NULL))
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
    INSERT INTO ledger_backfill_20260926 SELECT * FROM ledger WHERE id = ANY (COALESCE(v_led, ARRAY[]::uuid[]))
      ON CONFLICT DO NOTHING;
    DELETE FROM ledger WHERE id = ANY (COALESCE(v_led, ARRAY[]::uuid[]));
    UPDATE cash_register_preliminary
       SET status = 'reconciled', reconciled_at = now(), reconciled_journal_entry_id = NULL, updated_at = now(),
           coding_question = 'The statement for this date was read and does not show this exact amount — usually the amount before tip or a temporary hold. The statement line is the one on the books.'
     WHERE id = ANY (v_reg);
  END IF;

  RETURN jsonb_build_object('retired', v_rows, 'left_alone_hand_coded', v_held);
END $$;

-- Hook into the register writer so it runs on every pass, before anything posts.
DO $$
DECLARE d text;
BEGIN
  SELECT pg_get_functiondef('public.cash_register_gl_writer'::regproc) INTO d;
  IF position('retire_unclaimed_register_guesses' IN d) > 0 THEN RETURN; END IF;
  IF position(E'v_pairs jsonb := ''[]''::jsonb;\nBEGIN\n  WITH candidates AS (' IN d) = 0 THEN
    RAISE EXCEPTION 'cash_register_gl_writer body not as expected (declare/begin anchor)';
  END IF;
  IF position(E'''ok'', TRUE, ''dry_run'', p_dry_run,' IN d) = 0 THEN
    RAISE EXCEPTION 'cash_register_gl_writer body not as expected (return anchor)';
  END IF;
  d := replace(d, E'v_pairs jsonb := ''[]''::jsonb;\nBEGIN\n  WITH candidates AS (',
    E'v_pairs jsonb := ''[]''::jsonb;\n  v_retired jsonb;\nBEGIN\n  -- Statement already read for this date: retire guesses it did not claim (Peter 2026-09-26).\n  v_retired := retire_unclaimed_register_guesses(p_agency_id, p_dry_run);\n\n  WITH candidates AS (');
  d := replace(d, E'''ok'', TRUE, ''dry_run'', p_dry_run,',
    E'''ok'', TRUE, ''dry_run'', p_dry_run,\n    ''retired_unclaimed_guesses'', v_retired,');
  EXECUTE d;
END $$;
