-- =============================================================================
-- MIGRATION 029: Gmail label → doc_type classification map
-- =============================================================================
-- Stores the mapping from Gmail label NAMES (stable across re-creates) to
-- document classifier doc_types. The Edge Function resolves label names to IDs
-- by calling GMAIL_LIST_LABELS once at start of each run, then matches incoming
-- emails by labelIds.
-- 
-- Label names map directly to BCC convention:
--   BCC/Bank-Statement → bank_statement_primary
--   BCC/CC-Statement → bank_statement_secondary  (treated as CC by sender)
--   BCC/Payroll → adp_payroll
--   BCC/Comp-Recap → comp_recap_daily
--   BCC/Production → team_production
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.gmail_label_classification_map (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  label_name text NOT NULL,
  doc_type text NOT NULL,
  source_account_code text,    -- pre-fill legacy source bank account when label-routing CC/bank
  priority int NOT NULL DEFAULT 10,  -- Label-based matching beats pattern matching
  is_active boolean NOT NULL DEFAULT TRUE,
  notes text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE(agency_id, label_name)
);

INSERT INTO gmail_label_classification_map 
  (agency_id, label_name, doc_type, source_account_code, priority, notes)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'BCC/Bank-Statement', 'bank_statement_primary', NULL, 10, 'Bank statements forwarded by Peter. source_account_code=NULL means classifier will fall back to filename/sender pattern matching.'),
  ('126794dd-25ff-47d2-a436-724499733365', 'BCC/CC-Statement', 'bank_statement_secondary', NULL, 10, 'Credit card statements. Falls back to filename/sender for which card.'),
  ('126794dd-25ff-47d2-a436-724499733365', 'BCC/Payroll', 'adp_payroll', NULL, 10, 'Payroll forwards (Heartland/ADP/Gusto).'),
  ('126794dd-25ff-47d2-a436-724499733365', 'BCC/Comp-Recap', 'comp_recap_daily', NULL, 10, 'SF comp recap forwards (1H or daily variant).'),
  ('126794dd-25ff-47d2-a436-724499733365', 'BCC/Production', 'team_production', NULL, 10, 'Team production reports.')
ON CONFLICT (agency_id, label_name) DO UPDATE SET 
  doc_type = EXCLUDED.doc_type,
  priority = EXCLUDED.priority,
  notes = EXCLUDED.notes,
  updated_at = NOW();

SELECT label_name, doc_type, priority FROM gmail_label_classification_map 
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' ORDER BY priority, label_name;
