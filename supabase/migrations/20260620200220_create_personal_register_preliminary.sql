-- Personal expense tracking — parallel to bank_register_preliminary but stripped of
-- the GL/journal-entries pipeline. Adds categorization fields. Permanently isolated
-- from the business books (no FK to journal_entries, no agency-GL writers touch it).

CREATE TABLE IF NOT EXISTS public.personal_register_preliminary (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,

  -- Transaction core (same shape as business)
  txn_date date NOT NULL,
  txn_timestamp timestamptz,
  account_type text CHECK (account_type IN ('checking','credit_card')),
  account_last4 text,
  account_label text,
  direction text CHECK (direction IN ('credit','debit')),
  amount numeric(12,2) CHECK (amount > 0),
  merchant text,
  raw_subject text,

  -- Source tracking (dedup)
  source_message_id text UNIQUE NOT NULL,
  source_email_received_at timestamptz,

  -- Categorization
  category text CHECK (category IS NULL OR category IN (
    'Groceries','Dining','Fuel','Auto','Utilities','Insurance',
    'Medical','Home','Entertainment','Subscriptions','Travel',
    'Personal Care','Family','Giving','Transfer/Payment',
    'Refund/Credit','Bank Fee','Other'
  )),
  category_confidence text CHECK (category_confidence IS NULL OR category_confidence IN (
    'high','medium','low','needs_peter'
  )),
  peter_category text,
  peter_categorized_at timestamptz,
  peter_note text,

  -- Status
  status text DEFAULT 'auto_categorized' CHECK (status IN (
    'auto_categorized','peter_categorized','needs_peter','disputed'
  )),

  -- Gmail/Drive tracking
  gmail_labeled_at timestamptz,
  gmail_label_applied text,
  drive_filed_at timestamptz,
  drive_file_url text,
  drive_folder_id text,

  -- General
  notes text,
  created_at timestamptz DEFAULT NOW(),
  updated_at timestamptz DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_personal_register_agency_date
  ON public.personal_register_preliminary (agency_id, txn_date DESC);
CREATE INDEX IF NOT EXISTS idx_personal_register_category
  ON public.personal_register_preliminary (agency_id, category, txn_date DESC);

-- Updated_at trigger
CREATE OR REPLACE FUNCTION public.touch_personal_register_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_personal_register_updated_at ON public.personal_register_preliminary;
CREATE TRIGGER trg_personal_register_updated_at
  BEFORE UPDATE ON public.personal_register_preliminary
  FOR EACH ROW EXECUTE FUNCTION public.touch_personal_register_updated_at();

-- RLS — mirror business table pattern
ALTER TABLE public.personal_register_preliminary ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS authenticated_select_personal_register ON public.personal_register_preliminary;
CREATE POLICY authenticated_select_personal_register
  ON public.personal_register_preliminary FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS authenticated_insert_personal_register ON public.personal_register_preliminary;
CREATE POLICY authenticated_insert_personal_register
  ON public.personal_register_preliminary FOR INSERT TO authenticated
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

DROP POLICY IF EXISTS authenticated_update_personal_register ON public.personal_register_preliminary;
CREATE POLICY authenticated_update_personal_register
  ON public.personal_register_preliminary FOR UPDATE TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

DROP POLICY IF EXISTS service_role_all_personal_register ON public.personal_register_preliminary;
CREATE POLICY service_role_all_personal_register
  ON public.personal_register_preliminary FOR ALL TO service_role
  USING (true) WITH CHECK (true);

COMMENT ON TABLE public.personal_register_preliminary IS
  'Personal expense tracking — parallel to bank_register_preliminary. NO GL pipeline. Categorized for budgeting only. Tax/business books NEVER reference this table.';

