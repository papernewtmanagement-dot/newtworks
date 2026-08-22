
CREATE OR REPLACE VIEW public.v_amazon_charge_matches AS
WITH amz_ledger AS (
  SELECT l.id AS ledger_id, l.agency_id, l.entry_date, l.description,
    GREATEST(l.debit, l.credit) AS charge_amount, l.source, l.statement_id, l.cash_register_id,
    coa.account_code AS current_code, coa.account_name AS current_name,
    COALESCE(cr.account_last4, acct.account_number_last4) AS card_last4,
    acct.alternate_last4s
  FROM ledger l
  JOIN chart_of_accounts coa ON coa.id = l.account_id
  LEFT JOIN cash_register_preliminary cr ON cr.id = l.cash_register_id
  LEFT JOIN statements st ON st.id = l.statement_id
  LEFT JOIN accounts acct ON acct.id = st.account_id
  WHERE l.description ~* '\yamazon\y|\yamzn\y'
),
order_majority AS (
  SELECT DISTINCT ON (i.order_id) i.order_id, i.gl_account_code, i.category_label
  FROM amazon_order_items i
  WHERE i.gl_account_code IS NOT NULL
  GROUP BY i.order_id, i.gl_account_code, i.category_label
  ORDER BY i.order_id, (sum(i.total_amount)) DESC, i.gl_account_code
),
order_shape AS (
  SELECT o.order_id, o.agency_id, o.order_date::date AS order_date, o.grand_total,
    o.payment_card_last4, o.target_business_entity_id, o.matched_ledger_id,
    count(*) AS item_count,
    count(DISTINCT i.gl_account_code) AS distinct_categories,
    count(*) FILTER (WHERE i.gl_account_code IS NULL) AS uncoded_items,
    string_agg((left(i.product_name, 50) || ' [' || COALESCE(i.gl_account_code, '?') || ' $' || i.total_amount || ']'), '; ' ORDER BY i.total_amount DESC) AS item_breakdown
  FROM amazon_orders o
  JOIN amazon_order_items i USING (order_id)
  GROUP BY o.order_id, o.agency_id, o.order_date, o.grand_total, o.payment_card_last4, o.target_business_entity_id, o.matched_ledger_id
),
paired AS (
  SELECT al.ledger_id, al.agency_id, al.entry_date, al.description, al.charge_amount, al.source,
    al.statement_id, al.cash_register_id, al.current_code, al.current_name, al.card_last4, al.alternate_last4s,
    os.order_id, os.order_date, os.grand_total, os.target_business_entity_id, os.item_count,
    os.distinct_categories, os.uncoded_items, os.item_breakdown, os.matched_ledger_id AS order_already_linked_to,
    om.gl_account_code AS proposed_code, om.category_label AS proposed_label,
    count(*) OVER (PARTITION BY al.ledger_id) AS candidate_orders,
    abs(os.order_date - al.entry_date) AS day_diff
  FROM amz_ledger al
  JOIN order_shape os ON os.agency_id = al.agency_id AND os.grand_total = al.charge_amount
    AND (os.payment_card_last4 IN (SELECT unnest(array_append(COALESCE(al.alternate_last4s, '{}'::text[]), al.card_last4))))
    AND os.order_date >= (al.entry_date - '10 days'::interval) AND os.order_date <= (al.entry_date + '2 days'::interval)
  LEFT JOIN order_majority om USING (order_id)
),
with_min AS (
  SELECT *, min(day_diff) OVER (PARTITION BY ledger_id) AS min_day_diff
  FROM paired
),
nearest AS (
  SELECT *,
    row_number() OVER (PARTITION BY ledger_id ORDER BY day_diff ASC, order_date DESC) AS rn,
    count(*) FILTER (WHERE day_diff = min_day_diff) OVER (PARTITION BY ledger_id) AS tied_at_min
  FROM with_min
)
SELECT ledger_id, entry_date, description, charge_amount, source, current_code, current_name, card_last4,
  order_id, order_date, target_business_entity_id, proposed_code, proposed_label, item_count,
  distinct_categories, uncoded_items, item_breakdown, candidate_orders, order_already_linked_to,
  CASE
    WHEN tied_at_min > 1 THEN 'ambiguous: multiple orders equally close in date'
    WHEN proposed_code IS NULL THEN 'no category on any item'
    WHEN uncoded_items > 0 THEN 'some items still uncategorized'
    WHEN proposed_code = current_code THEN 'already correct'
    WHEN distinct_categories > 1 THEN 'ready (mixed order, majority category)'
    ELSE 'ready'
  END AS verdict
FROM nearest
WHERE rn = 1;

