-- Peter caught a suspense-expense pair on the agency P&L for April 2026:
-- $2,000 "Deposit — Pending agent classification" with a matching -$2,000
-- counterpart on the same account. Investigation:
--
-- JE 48f2cc7d-6fb9-4489-a29e-f32fc1ece980 (source: document_processor,
-- 2026-04-30) has TWO journal_lines on the SAME account
-- (*Unclassified Expense — Business, Peter Story State Farm entity):
--   * line 1: debit $2,000
--   * line 2: credit $2,000
-- Net-zero on P&L math, but two visible ledger rows and zero economic
-- content — the JE debits and credits the same account.
--
-- Root cause: the underlying transaction (a $2,000 deposit into
-- Personal — RBFCU Savings 6596 on 2026-04-30) was posted through the
-- document_processor edge function BEFORE the RBFCU classifier pattern
-- (index.ts line 606) existed. Classifier fell through to a state where
-- both the debit and credit legs resolved to the same suspense account
-- on the wrong entity. The real deposit was correctly re-posted by
-- pf4_personal_backfill as JE 32c89a85 (debit RBFCU Savings, credit
-- Gifts Received (nontaxable) on Personal entity), so removing the
-- broken doc_processor JE loses no economic information.
--
-- Fix: delete 48f2cc7d, then add a constraint-trigger that structurally
-- rejects any JE where a single account_id has both nonzero debit AND
-- nonzero credit totals. This blocks the self-offsetting pattern at the
-- database level regardless of which edge function or backfill script
-- inserts the lines — belt-and-suspenders on Peter's "no fake
-- transactions" directive.

DELETE FROM public.journal_entries
WHERE id = '48f2cc7d-6fb9-4489-a29e-f32fc1ece980'::uuid;

-- Invariant: no single account may carry both a debit AND a credit
-- within one JE. Legitimate multi-line same-account JEs (e.g., payroll
-- splits with two debits to Staff Wages) always keep all lines on that
-- account in the same direction, so they pass; a self-offsetting JE
-- like 48f2cc7d fails.
CREATE OR REPLACE FUNCTION public.reject_self_offsetting_je_line()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_bad_account UUID;
  v_total_dr NUMERIC;
  v_total_cr NUMERIC;
BEGIN
  SELECT jl.account_id, SUM(COALESCE(jl.debit,0)), SUM(COALESCE(jl.credit,0))
    INTO v_bad_account, v_total_dr, v_total_cr
  FROM public.journal_lines jl
  WHERE jl.journal_entry_id = NEW.journal_entry_id
  GROUP BY jl.account_id
  HAVING SUM(COALESCE(jl.debit,0)) > 0
     AND SUM(COALESCE(jl.credit,0)) > 0
  LIMIT 1;

  IF v_bad_account IS NOT NULL THEN
    RAISE EXCEPTION 'Self-offsetting JE rejected: journal_entry_id=% has both debit ($%) AND credit ($%) on account_id=% — no economic content. If you meant to zero out an entry, delete it instead.',
      NEW.journal_entry_id, v_total_dr, v_total_cr, v_bad_account;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_reject_self_offsetting_je ON public.journal_lines;
CREATE TRIGGER trg_reject_self_offsetting_je
AFTER INSERT ON public.journal_lines
FOR EACH ROW EXECUTE FUNCTION public.reject_self_offsetting_je_line();
