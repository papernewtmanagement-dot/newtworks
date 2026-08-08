-- Phase B1: journal_lines becomes self-contained ahead of the journal_entries drop.
-- Everything the P&L needs that currently lives on the parent moves onto the line.
-- Entity is NOT copied here -- it resolves through chart_of_accounts.business_entity_id
-- per the 2026-07-29 decision that removed the redundant column. Do not re-add it.
ALTER TABLE public.journal_lines
  ADD COLUMN IF NOT EXISTS entry_date date,
  ADD COLUMN IF NOT EXISTS entry_type text,
  ADD COLUMN IF NOT EXISTS source text,
  ADD COLUMN IF NOT EXISTS reference_number text,
  ADD COLUMN IF NOT EXISTS memo text,
  ADD COLUMN IF NOT EXISTS document_id uuid,
  ADD COLUMN IF NOT EXISTS statement_id uuid,
  ADD COLUMN IF NOT EXISTS classification_status text,
  ADD COLUMN IF NOT EXISTS suspense_reason text,
  ADD COLUMN IF NOT EXISTS rule_id_used uuid,
  ADD COLUMN IF NOT EXISTS classified_by text,
  ADD COLUMN IF NOT EXISTS classified_at timestamptz;

UPDATE public.journal_lines jl
SET entry_date = je.entry_date,
    entry_type = je.entry_type,
    source = je.source,
    reference_number = je.reference_number,
    memo = je.memo,
    document_id = je.document_id,
    classification_status = je.classification_status,
    suspense_reason = je.suspense_reason,
    rule_id_used = je.rule_id_used,
    classified_by = je.classified_by,
    classified_at = je.classified_at
FROM public.journal_entries je
WHERE je.id = jl.journal_entry_id
  AND jl.entry_date IS NULL;

-- link lines back to the statement row that produced them, via the old entry pointer
UPDATE public.journal_lines jl
SET statement_id = s.id
FROM public.statements s
WHERE s.legacy_journal_entry_id = jl.journal_entry_id
  AND jl.statement_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_journal_lines_entry_date ON public.journal_lines(entry_date);
CREATE INDEX IF NOT EXISTS idx_journal_lines_statement ON public.journal_lines(statement_id);