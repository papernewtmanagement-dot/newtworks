-- One-off: apply the keyword rules to every order item with no category yet.
-- The repeatable version of this lives in amazon_categorize_new_items().
WITH pick AS (
  SELECT DISTINCT ON (i.id)
         i.id, r.gl_account_code, r.category_label
  FROM amazon_order_items i
  JOIN amazon_orders o ON o.order_id = i.order_id
  JOIN business_entities be ON be.id = o.target_business_entity_id
  JOIN amazon_item_category_rules r
    ON r.is_active
   AND r.agency_id = i.agency_id
   AND r.entity_name = CASE be.name
                         WHEN 'Peter Story State Farm' THEN 'Agency'
                         WHEN 'PaperNewt LLC'          THEN 'PaperNewt'
                         WHEN 'Personal'               THEN 'Personal'
                         ELSE be.name END
   AND i.product_name ~* r.keyword_pattern
  WHERE i.gl_account_code IS NULL
  ORDER BY i.id, r.priority, r.category_label
)
UPDATE amazon_order_items i
SET gl_account_code = pick.gl_account_code,
    category_label  = pick.category_label,
    classified_at   = NOW()
FROM pick
WHERE pick.id = i.id;
