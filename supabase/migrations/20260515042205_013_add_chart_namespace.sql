-- Allow multiple chart "books" to coexist for the same agency.
-- 'bcc_sf'  = the generic SF chart seeded at install (used by automation recipes going forward)
-- 'books_historical'     = verbatim copy of Peter's legacy-source chart (used for historical journals + CPA reporting)
ALTER TABLE chart_of_accounts
  ADD COLUMN IF NOT EXISTS chart_namespace text NOT NULL DEFAULT 'bcc_sf';

CREATE INDEX IF NOT EXISTS chart_of_accounts_ns_idx 
  ON chart_of_accounts(agency_id, chart_namespace, account_code);

-- Drop and recreate any unique constraint on account_code if it exists, scoped by namespace
DO $$
DECLARE
  c text;
BEGIN
  -- Find and drop any unique constraint on chart_of_accounts that would conflict
  FOR c IN
    SELECT conname FROM pg_constraint 
    WHERE conrelid = 'public.chart_of_accounts'::regclass 
      AND contype = 'u'
  LOOP
    EXECUTE format('ALTER TABLE public.chart_of_accounts DROP CONSTRAINT %I', c);
  END LOOP;
END $$;

-- Recreate uniqueness: account_code must be unique within (agency, namespace)
ALTER TABLE chart_of_accounts
  ADD CONSTRAINT chart_of_accounts_agency_ns_code_uniq
  UNIQUE (agency_id, chart_namespace, account_code);
