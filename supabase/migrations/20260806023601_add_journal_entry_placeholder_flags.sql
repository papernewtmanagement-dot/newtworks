ALTER TABLE public.journal_entries
  ADD COLUMN IF NOT EXISTS is_placeholder boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS placeholder_reason text,
  ADD COLUMN IF NOT EXISTS placeholder_cleared_by uuid REFERENCES public.journal_entries(id);

COMMENT ON COLUMN public.journal_entries.is_placeholder IS
  'True when this entry is a stand-in for a transaction whose real source data was not yet ingested. Must be retired (reversed) once real data arrives.';
COMMENT ON COLUMN public.journal_entries.placeholder_reason IS
  'Plain-English statement of what real data would retire this placeholder.';
COMMENT ON COLUMN public.journal_entries.placeholder_cleared_by IS
  'The journal_entries.id of the reversal that retired this placeholder. NULL means still outstanding.';

CREATE INDEX IF NOT EXISTS idx_journal_entries_open_placeholder
  ON public.journal_entries (agency_id, entry_date)
  WHERE is_placeholder = true AND placeholder_cleared_by IS NULL;

UPDATE public.journal_entries
SET is_placeholder = true,
    placeholder_reason = 'OBE plug for AMEX 1006 payoff; funding source unknown pending January bank data',
    placeholder_cleared_by = 'a82239c1-cbb6-4479-b8da-4573fe2c0280'
WHERE id = '810b1ca1-cb7c-45d1-8fd7-5ad8e05f97a7';
