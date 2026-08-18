-- Move the categorizing work from the old staging table into amazon_order_items.
-- Match on order_id + product_name (verified zero conflicting categories).
WITH src AS (
  SELECT DISTINCT order_id, product_name, gl_account, category
  FROM amazon_categorized_2026_staging
  WHERE gl_account IS NOT NULL
)
UPDATE amazon_order_items i
SET gl_account_code = src.gl_account,
    category_label  = src.category,
    classified_at   = NOW(),
    source          = COALESCE(i.source,'') || '+staging_port_20260818'
FROM src
WHERE src.order_id = i.order_id
  AND src.product_name = i.product_name
  AND i.gl_account_code IS NULL;
