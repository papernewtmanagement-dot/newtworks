-- 1) canonical backfill already applied in prior step (occurrence sequence = which repeat within card+date+|amount|)
UPDATE credit_transactions ct SET dedup_fingerprint = sub.fp
FROM (
  SELECT id,
    COALESCE(credit_account_id::text,'nocard') || '|' ||
    transaction_date::text || '|' ||
    to_char(abs(amount),'FM999999990.00') || '|' ||
    (row_number() OVER (PARTITION BY credit_account_id, transaction_date, abs(amount)
                        ORDER BY created_at, id))::text AS fp
  FROM credit_transactions
) sub WHERE sub.id = ct.id;

-- 2) enforce
CREATE UNIQUE INDEX IF NOT EXISTS uq_credit_transactions_dedup
  ON public.credit_transactions(dedup_fingerprint);
ALTER TABLE public.credit_transactions ALTER COLUMN dedup_fingerprint SET NOT NULL;
