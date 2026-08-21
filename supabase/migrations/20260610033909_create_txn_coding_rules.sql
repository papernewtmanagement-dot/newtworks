
-- Transaction coding rules table — learns from Peter's answers
-- Each time Peter codes a transaction, a rule is created here
-- Future matching transactions auto-classify using these rules
CREATE TABLE IF NOT EXISTS txn_coding_rules (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id           uuid NOT NULL REFERENCES agency(id),
  
  -- Matching criteria (at least one required)
  match_merchant      text,          -- e.g. 'VERIZON' — exact or partial
  match_merchant_mode text NOT NULL DEFAULT 'contains'  CHECK (match_merchant_mode IN ('exact','contains','starts_with')),
  match_amount_min    numeric,       -- optional amount range for disambiguation
  match_amount_max    numeric,
  match_account_last4 text,          -- limit rule to specific account
  match_direction     text           CHECK (match_direction IN ('debit','credit')),
  
  -- GL coding
  debit_account       text NOT NULL, -- COA account name/code
  credit_account      text NOT NULL,
  description_template text,         -- e.g. 'Verizon - Monthly Cell Bill'
  
  -- Metadata
  rule_name           text NOT NULL,
  rule_source         text NOT NULL DEFAULT 'peter_answer' CHECK (rule_source IN ('peter_answer','system_seed','import')),
  confidence          text NOT NULL DEFAULT 'high' CHECK (confidence IN ('high','medium','low')),
  is_active           boolean NOT NULL DEFAULT true,
  usage_count         integer NOT NULL DEFAULT 0,
  last_matched_at     timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_txn_coding_rules_agency ON txn_coding_rules(agency_id);
CREATE INDEX IF NOT EXISTS idx_txn_coding_rules_merchant ON txn_coding_rules(agency_id, match_merchant);

