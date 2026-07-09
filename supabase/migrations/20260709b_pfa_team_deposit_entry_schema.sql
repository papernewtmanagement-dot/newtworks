-- ============================================================================
-- PFA team-facing deposit entry: schema changes
-- Peter's constraints (2026-07-09):
--   * customer_name: only "First L." format (first name + last initial + period). NEVER full last name.
--   * NO policy_or_app_number captured from team. Drop the column.
--   * NO notes captured from team. (Column stays for admin/audit use; not exposed in team UI.)
--   * NEW: policy_type dropdown - auto | fire | life | health | billing
-- ============================================================================

-- 1) Add policy_type column with CHECK for the 5 allowed values
ALTER TABLE public.pfa_transactions
  ADD COLUMN IF NOT EXISTS policy_type text;

ALTER TABLE public.pfa_transactions
  DROP CONSTRAINT IF EXISTS pfa_transactions_policy_type_check;
ALTER TABLE public.pfa_transactions
  ADD CONSTRAINT pfa_transactions_policy_type_check
  CHECK (policy_type IS NULL OR policy_type IN ('auto','fire','life','health','billing'));

-- 2) DROP policy_or_app_number - never captured going forward (SPI protection rule)
ALTER TABLE public.pfa_transactions
  DROP COLUMN IF EXISTS policy_or_app_number;

-- 3) Enforce masked customer_name format at the DB level ("First L.")
-- Accepts: "Jane D.", "Mary-Anne S.", "Bob X.", "Jose R."
-- Rejects: "Jane Doe" (full last name), "Jane" (no initial), "Jane D" (no period)
ALTER TABLE public.pfa_transactions
  DROP CONSTRAINT IF EXISTS pfa_transactions_customer_name_masked_format;
ALTER TABLE public.pfa_transactions
  ADD CONSTRAINT pfa_transactions_customer_name_masked_format
  CHECK (
    customer_name IS NULL
    OR customer_name ~ '^[^\s]+([- ][^\s]+)?\s[A-Za-z]\.$'
  );

COMMENT ON COLUMN public.pfa_transactions.customer_name IS 'Masked customer identifier - "First L." format only (first name + last initial + period). Full last names are prohibited (SPI protection per Peter 2026-07-09).';
COMMENT ON COLUMN public.pfa_transactions.policy_type IS 'One of: auto, fire, life, health, billing. Set on customer deposit entries via pfa_record_customer_deposit RPC.';
