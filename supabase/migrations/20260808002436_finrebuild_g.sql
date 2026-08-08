-- Peter directive: delete journal_entries, wipe journal_lines, rename it `ledger`.
-- The line already carries date/source/reference/classification, so it stands alone.

-- 1. drop the silent rerouting + guard triggers before anything else writes
DROP TRIGGER IF EXISTS trg_redirect_susp_to_unclassified ON public.journal_lines;
DROP TRIGGER IF EXISTS trg_redirect_prior_susp_line ON public.journal_lines;
DROP TRIGGER IF EXISTS trg_reject_self_offsetting_je_line ON public.journal_lines;
DROP TRIGGER IF EXISTS trg_reject_cross_source_duplicate_je_line ON public.journal_lines;
DROP TRIGGER IF EXISTS trg_enforce_us_bank_alliance_account_source ON public.journal_lines;
DROP TRIGGER IF EXISTS trg_pair_eriosto_on_smvc ON public.journal_lines;
DROP FUNCTION IF EXISTS public.redirect_susp_to_unclassified() CASCADE;
DROP FUNCTION IF EXISTS public.redirect_prior_susp_line() CASCADE;
DROP FUNCTION IF EXISTS public.reject_self_offsetting_je_line() CASCADE;
DROP FUNCTION IF EXISTS public.reject_cross_source_duplicate_je_line() CASCADE;
DROP FUNCTION IF EXISTS public.enforce_us_bank_alliance_account_source() CASCADE;
DROP FUNCTION IF EXISTS public.pair_eriosto_on_smvc_credit() CASCADE;

-- 2. canon tables stop pointing at the derived table; the ledger points at canon instead
ALTER TABLE public.comp_recap   DROP COLUMN IF EXISTS journal_entry_id;
ALTER TABLE public.payroll_runs DROP COLUMN IF EXISTS journal_entry_id;

-- 3. wipe the derived table
TRUNCATE TABLE public.journal_lines CASCADE;

-- 4. drop the parent
DROP TABLE IF EXISTS public.journal_entries CASCADE;

-- 5. rename and finish the shape
ALTER TABLE public.journal_lines RENAME TO ledger;
ALTER TABLE public.ledger DROP COLUMN IF EXISTS journal_entry_id;
ALTER TABLE public.ledger
  ADD COLUMN IF NOT EXISTS comp_recap_id uuid,
  ADD COLUMN IF NOT EXISTS payroll_run_id uuid;
ALTER TABLE public.ledger ALTER COLUMN entry_date SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ledger_comp_recap ON public.ledger(comp_recap_id);
CREATE INDEX IF NOT EXISTS idx_ledger_payroll_run ON public.ledger(payroll_run_id);

COMMENT ON TABLE public.ledger IS
 'Derived P&L table. Built entirely from canon (statements, comp_recap, payroll_runs, documents) by gl_classification_rules. Never written to directly. Safe to wipe and rebuild at any time. One line per transaction - no matched offset pair, no suspense account.';