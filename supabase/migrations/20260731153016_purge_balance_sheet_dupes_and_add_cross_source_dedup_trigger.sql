-- Peter's question: why didn't the second backfill script clean up the first
-- broken entry when it re-posted the same $2000 deposit correctly?
--
-- Answer: no code path was checking for pre-existing coverage of the same
-- economic event before writing. Each script wrote its own version. The
-- database allowed all of them to sit side by side.
--
-- Prior cleanup on P&L accounts caught 84 fake JEs. This one catches 36
-- more on balance-sheet-only transactions (credit card payments, internal
-- transfers, owner draws) that the earlier P&L-only sweep missed.
--
-- Structural fix: a trigger that hard-rejects any new journal line if
-- another JE from a different source already has an identical line
-- (same account, same date, same debit/credit amount). Legit coincidences
-- always come from the same source and pass; cross-source duplicates fail
-- at INSERT — no matter which script or edge function is running.

-- ============================================================
-- Step 1: Repoint bank_transactions FKs from dupe JEs → canonical JEs
-- ============================================================
WITH pl_lines AS (
  SELECT je.id AS je_id, je.entry_date, je.source, jl.account_id,
         COALESCE(jl.debit,0) AS debit, COALESCE(jl.credit,0) AS credit
  FROM public.journal_lines jl
  JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
),
canonical AS (SELECT * FROM pl_lines WHERE source IN ('cc_gl_writer','bank_gl_writer')),
backfill AS (SELECT * FROM pl_lines WHERE source IN ('claude_bank_reparse','pf4_personal_backfill','chat_backfill_0353_20260727')),
dupe_pairs AS (
  SELECT DISTINCT b.je_id AS backfill_je_id,
         FIRST_VALUE(c.je_id) OVER (PARTITION BY b.je_id ORDER BY c.je_id) AS canonical_je_id
  FROM backfill b
  JOIN canonical c ON b.entry_date = c.entry_date
                   AND b.account_id = c.account_id
                   AND b.debit = c.debit AND b.credit = c.credit
)
UPDATE public.bank_transactions bt
   SET journal_entry_id = dp.canonical_je_id
  FROM dupe_pairs dp
 WHERE bt.journal_entry_id = dp.backfill_je_id;

-- ============================================================
-- Step 2: Repoint credit_transactions FKs from dupe JEs → canonical JEs
-- ============================================================
WITH pl_lines AS (
  SELECT je.id AS je_id, je.entry_date, je.source, jl.account_id,
         COALESCE(jl.debit,0) AS debit, COALESCE(jl.credit,0) AS credit
  FROM public.journal_lines jl
  JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
),
canonical AS (SELECT * FROM pl_lines WHERE source IN ('cc_gl_writer','bank_gl_writer')),
backfill AS (SELECT * FROM pl_lines WHERE source IN ('claude_bank_reparse','pf4_personal_backfill','chat_backfill_0353_20260727')),
dupe_pairs AS (
  SELECT DISTINCT b.je_id AS backfill_je_id,
         FIRST_VALUE(c.je_id) OVER (PARTITION BY b.je_id ORDER BY c.je_id) AS canonical_je_id
  FROM backfill b
  JOIN canonical c ON b.entry_date = c.entry_date
                   AND b.account_id = c.account_id
                   AND b.debit = c.debit AND b.credit = c.credit
)
UPDATE public.credit_transactions ct
   SET journal_entry_id = dp.canonical_je_id
  FROM dupe_pairs dp
 WHERE ct.journal_entry_id = dp.backfill_je_id;

-- ============================================================
-- Step 3: Delete the backfill dupe JEs
-- ============================================================
WITH pl_lines AS (
  SELECT je.id AS je_id, je.entry_date, je.source, jl.account_id,
         COALESCE(jl.debit,0) AS debit, COALESCE(jl.credit,0) AS credit
  FROM public.journal_lines jl
  JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
),
canonical AS (SELECT * FROM pl_lines WHERE source IN ('cc_gl_writer','bank_gl_writer')),
backfill AS (SELECT * FROM pl_lines WHERE source IN ('claude_bank_reparse','pf4_personal_backfill','chat_backfill_0353_20260727')),
backfill_dupes AS (
  SELECT DISTINCT b.je_id
  FROM backfill b
  JOIN canonical c ON b.entry_date = c.entry_date
                   AND b.account_id = c.account_id
                   AND b.debit = c.debit AND b.credit = c.credit
)
DELETE FROM public.journal_entries WHERE id IN (SELECT je_id FROM backfill_dupes);

-- ============================================================
-- Step 4: Cross-source duplicate rejection trigger
-- ============================================================
CREATE OR REPLACE FUNCTION public.reject_cross_source_duplicate_je_line()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_new_je RECORD;
  v_conflict_je_id UUID;
  v_conflict_source TEXT;
BEGIN
  SELECT id, entry_date, source, agency_id
    INTO v_new_je
    FROM public.journal_entries
   WHERE id = NEW.journal_entry_id;
  IF NOT FOUND THEN RETURN NEW; END IF;

  SELECT je2.id, je2.source
    INTO v_conflict_je_id, v_conflict_source
    FROM public.journal_lines jl2
    JOIN public.journal_entries je2 ON je2.id = jl2.journal_entry_id
   WHERE je2.agency_id = v_new_je.agency_id
     AND je2.entry_date = v_new_je.entry_date
     AND je2.id <> v_new_je.id
     AND je2.source <> v_new_je.source
     AND jl2.account_id = NEW.account_id
     AND COALESCE(jl2.debit, 0) = COALESCE(NEW.debit, 0)
     AND COALESCE(jl2.credit, 0) = COALESCE(NEW.credit, 0)
     AND (COALESCE(NEW.debit, 0) > 0 OR COALESCE(NEW.credit, 0) > 0)
   LIMIT 1;

  IF v_conflict_je_id IS NOT NULL THEN
    RAISE EXCEPTION 'Cross-source duplicate rejected: an existing journal entry (id=%, source="%") already covers this account/date/amount. Delete or correct the existing entry before re-posting from source "%".',
      v_conflict_je_id, v_conflict_source, v_new_je.source;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_reject_cross_source_duplicate_je_line ON public.journal_lines;
CREATE TRIGGER trg_reject_cross_source_duplicate_je_line
AFTER INSERT ON public.journal_lines
FOR EACH ROW EXECUTE FUNCTION public.reject_cross_source_duplicate_je_line();
