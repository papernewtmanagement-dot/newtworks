
-- 1. The $28.69 on the agency card is the refund of the January spinner die sent to
--    Thomas for the prize cart. File it against the same account as the original.
UPDATE ledger l
SET account_id = (SELECT id FROM chart_of_accounts WHERE account_code='6160'
                  AND business_entity_id=(SELECT id FROM business_entities WHERE name='Peter Story State Farm')),
    memo = 'Refund - spinner die (prize cart, sent to Thomas)',
    classified_by='rule', classified_at=now()
FROM statements st, accounts a, chart_of_accounts cur
WHERE l.statement_id=st.id AND st.account_id=a.id AND cur.id=l.account_id
  AND a.account_number_last4='3447' AND cur.account_code='6950'
  AND l.entry_date='2026-04-20' AND l.credit=28.69;

-- 2. Refunds are credits. An Amazon ORDER is always a purchase, so a refund can never
--    have a matching order -- yet the matcher was pulling refunds in via
--    GREATEST(debit,credit) and then reporting them as unmatched purchases. That is what
--    inflated the gap list Alvi had to work through. Restrict both the view and the
--    matcher function to actual charges (debit > 0).

CREATE OR REPLACE FUNCTION public.match_amazon_orders_to_ledger(p_agency_id uuid, p_dry_run boolean DEFAULT false)
RETURNS TABLE(order_id text, ledger_id uuid, entry_date date, charge_amount numeric, action text)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  WITH amz_ledger AS (
    SELECT l.id AS ledger_id, l.entry_date, l.debit AS charge_amount,
      COALESCE(cr.account_last4, acct.account_number_last4) AS card_last4,
      acct.alternate_last4s
    FROM ledger l
    LEFT JOIN cash_register_preliminary cr ON cr.id = l.cash_register_id
    LEFT JOIN statements st ON st.id = l.statement_id
    LEFT JOIN accounts acct ON acct.id = st.account_id
    WHERE l.agency_id = p_agency_id
      AND l.description ~* '\yamazon\y|\yamzn\y'
      AND l.debit > 0
  ),
  candidates AS (
    SELECT o.order_id, al.ledger_id, al.entry_date, al.charge_amount,
      count(*) OVER (PARTITION BY al.ledger_id) AS ledger_side_candidates,
      count(*) OVER (PARTITION BY o.order_id) AS order_side_candidates
    FROM amazon_orders o
    JOIN amz_ledger al
      ON o.agency_id = p_agency_id
     AND o.grand_total = al.charge_amount
     AND o.payment_card_last4 IN (SELECT unnest(array_append(COALESCE(al.alternate_last4s, '{}'::text[]), al.card_last4)))
     AND o.order_date::date BETWEEN (al.entry_date - INTERVAL '10 days') AND (al.entry_date + INTERVAL '2 days')
    WHERE o.matched_ledger_id IS NULL
  ),
  unique_matches AS (
    SELECT * FROM candidates WHERE ledger_side_candidates = 1 AND order_side_candidates = 1
  ),
  applied AS (
    UPDATE amazon_orders o
    SET matched_ledger_id = um.ledger_id, matched_at = now()
    FROM unique_matches um
    WHERE o.order_id = um.order_id AND NOT p_dry_run
    RETURNING o.order_id
  )
  SELECT um.order_id, um.ledger_id, um.entry_date::date, um.charge_amount,
    CASE WHEN p_dry_run THEN 'would_match' ELSE 'matched' END
  FROM unique_matches um;
END;
$$;

