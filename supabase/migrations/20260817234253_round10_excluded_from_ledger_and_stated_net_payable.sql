-- Round 10: honor excluded_from_ledger everywhere, canonical unposted-lines
-- view, retire pre-2026 lines, store comp-statement stated net totals.

-- ============================================================
-- FIX 31: raise_not_on_statement_alerts Pass 1 now skips register rows whose
-- matching statement line was deliberately excluded_from_ledger. Pass 2 was
-- already correct (an excluded line still confirms the transaction happened,
-- it just doesn't post to the ledger, so it should still count as a match).
-- Audit of tg_post_gl_on_arrival and statement_gl_writer_recipe: both
-- delegate entirely to statement_gl_writer, which already filters
-- excluded_from_ledger correctly -- no change needed, they're safe by
-- inheritance. v_statement_reconciliation and v_ledger_dup_candidates
-- correctly include excluded rows (reconciliation and dedup both need the
-- full picture, not just what posts). No frontend code reads statements
-- directly outside the ingestion writer's dedup guard.
-- ============================================================
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
  -- Pass 1: cash-register rows that WERE posted to the ledger and never got
  -- claimed by a statement line covering their period. FIX 31: skip if a
  -- matching statement line exists but was deliberately excluded
  -- (excluded_from_ledger = true) -- that is settled, not missing.
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
      AND NOT EXISTS (
        SELECT 1 FROM statements s
        WHERE s.agency_id = l.agency_id AND s.account_id = ra.id
          AND s.excluded_from_ledger IS TRUE
          AND round(abs(s.amount),2) = round(CASE WHEN l.debit > 0 THEN l.debit ELSE l.credit END,2)
          AND (CASE WHEN s.transaction_type IN ('withdrawal','charge','debit') THEN 'debit'
                    WHEN s.transaction_type IN ('deposit','payment_or_credit','credit','payment') THEN 'credit'
                    ELSE NULL END) = (CASE WHEN l.debit > 0 THEN 'debit' ELSE 'credit' END)
          AND abs(s.transaction_date - l.entry_date) <= 4
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
        rec.account_name || ' — ' || rec.n || ' transaction(s) not on the statement',
        'The statement covering ' || rec.statement_period_start || ' to ' || rec.statement_period_end ||
          ' has arrived, and ' || rec.n || ' transaction(s) totaling ' ||
          to_char(rec.total_amount, 'FM$999,999,990.00') || ' seen in the bank alerts were not on it.',
        'financials', rec.statement_balance_id, false, false, now()
      );
      v_count := v_count + 1;
    END IF;
  END LOOP;

  -- Pass 2 (unchanged)
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

-- ============================================================
-- FIX 32: canonical view for "what statement lines are genuinely unposted
-- and unexplained." Excludes anything with a ledger row, anything
-- deliberately excluded_from_ledger, anything a verification-only or
-- balance-sheet rule already covers, and anything carrying a *_NO_JE
-- category marker.
-- ============================================================
CREATE OR REPLACE VIEW public.v_statement_lines_unposted AS
SELECT
  s.id AS statement_id,
  s.agency_id,
  s.account_id,
  s.transaction_date,
  s.amount,
  s.description,
  s.transaction_type,
  'no ledger row, not excluded, no skip rule, no balance-sheet target, no no-JE marker'::text AS reason_unexplained
FROM statements s
WHERE NOT EXISTS (SELECT 1 FROM ledger l WHERE l.statement_id = s.id)
  AND s.excluded_from_ledger IS NOT TRUE
  AND NOT (s.category IS NOT NULL AND upper(trim(s.category)) LIKE '%\_NO\_JE')
  AND NOT EXISTS (
    SELECT 1 FROM gl_classification_rules r
    WHERE r.agency_id = s.agency_id AND r.is_active
      AND (r.debit_account_code = '__SKIP__' OR r.credit_account_code = '__SKIP__')
      AND (r.match_payee_regex IS NULL OR s.description ~* r.match_payee_regex)
  )
  AND NOT EXISTS (
    SELECT 1 FROM gl_classification_rules r
    JOIN chart_of_accounts coa ON coa.agency_id = r.agency_id
      AND coa.account_code IN (r.debit_account_code, r.credit_account_code)
    WHERE r.agency_id = s.agency_id AND r.is_active
      AND (r.match_payee_regex IS NULL OR s.description ~* r.match_payee_regex)
      AND coa.account_type IN ('asset','liability','equity')
  );

-- ============================================================
-- FIX 33: retire pre-2026 lines with no ledger row. 87 lines flagged
-- excluded_from_ledger = true, total $4,679.19, across 11 accounts. Applied
-- directly via Supabase MCP; mirrored here for the record. Not re-running
-- the UPDATE in this migration file since it's already applied and is not
-- idempotent-safe to blindly re-run against a moving "no ledger row" set.
-- ============================================================
-- UPDATE statements SET excluded_from_ledger = TRUE
-- WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
--   AND transaction_date < '2026-01-01'
--   AND NOT EXISTS (SELECT 1 FROM ledger l WHERE l.statement_id = statements.id)
--   AND excluded_from_ledger IS NOT TRUE;

-- ============================================================
-- FIX 34: store the comp statement's own stated net total, separate from
-- reconciliation_delta (which means a difference, not a total).
-- ============================================================
ALTER TABLE public.documents ADD COLUMN IF NOT EXISTS stated_net_payable numeric;

-- Backfilled for all 15 2026 comp statements by re-reading the source PDFs
-- from Drive (values only, no comp_recap lines touched). Applied directly;
-- see round-10 report for the full pay-date -> amount list.

-- Comp deposit guard now matches against documents.stated_net_payable via
-- comp_recap.source_document_id instead of summing comp_recap lines, so a
-- future parsing miss (like the one on 2026-07-31) can't silently break the
-- guard again.
