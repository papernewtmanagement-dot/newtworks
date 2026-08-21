
-- Add Gmail label and Drive filing tracking to bank_register_preliminary
ALTER TABLE bank_register_preliminary
  ADD COLUMN IF NOT EXISTS gmail_labeled_at    timestamptz,
  ADD COLUMN IF NOT EXISTS gmail_label_applied text,
  ADD COLUMN IF NOT EXISTS drive_filed_at      timestamptz,
  ADD COLUMN IF NOT EXISTS drive_file_url      text,
  ADD COLUMN IF NOT EXISTS drive_folder_id     text,
  ADD COLUMN IF NOT EXISTS applied_rule_id     uuid REFERENCES txn_coding_rules(id),
  ADD COLUMN IF NOT EXISTS gl_eligible         boolean GENERATED ALWAYS AS (
    coding_status IN ('peter_classified', 'auto_classified')
    AND status NOT IN ('possible_transfer', 'void')
  ) STORED;

-- View: only GL-ready transactions (the firewall gate)
CREATE OR REPLACE VIEW v_bank_register_gl_ready AS
SELECT
  id, agency_id, txn_date, account_type, account_last4, account_label,
  direction, amount, merchant,
  COALESCE(peter_debit_account, suggested_debit_account)   AS debit_account,
  COALESCE(peter_credit_account, suggested_credit_account)  AS credit_account,
  COALESCE(peter_note, notes)                               AS memo,
  coding_status, status, reconciled_journal_entry_id
FROM bank_register_preliminary
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND gl_eligible = true
  AND reconciled_journal_entry_id IS NULL
ORDER BY txn_date, amount;

-- View: weekly running balance summary across all accounts
CREATE OR REPLACE VIEW v_weekly_cash_position AS
WITH week_buckets AS (
  SELECT
    account_last4,
    account_label,
    account_type,
    date_trunc('week', txn_date) + interval '6 days' AS week_ending,
    SUM(CASE WHEN direction = 'credit' THEN amount ELSE 0 END) AS credits,
    SUM(CASE WHEN direction = 'debit'  THEN amount ELSE 0 END) AS debits,
    COUNT(*) AS txn_count,
    COUNT(*) FILTER (WHERE coding_status IN ('needs_peter','unclassified')) AS uncoded_count
  FROM bank_register_preliminary
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND status NOT IN ('void')
  GROUP BY account_last4, account_label, account_type,
           date_trunc('week', txn_date) + interval '6 days'
)
SELECT
  wb.*,
  pb.running_balance AS projected_end_of_week_balance
FROM week_buckets wb
LEFT JOIN LATERAL (
  SELECT running_balance
  FROM v_projected_account_balance vp
  WHERE vp.account_last4 = wb.account_last4
    AND vp.txn_date <= wb.week_ending
  ORDER BY vp.txn_date DESC, vp.amount
  LIMIT 1
) pb ON true
ORDER BY wb.week_ending DESC, wb.account_last4;

