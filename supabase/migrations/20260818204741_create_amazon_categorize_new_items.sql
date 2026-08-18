-- Applies the keyword rules to any Amazon order item that has no category yet.
-- Repeatable and safe to run every cycle; only fills blanks, never overwrites.
CREATE OR REPLACE FUNCTION public.amazon_categorize_new_items(p_agency_id uuid)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $fn$
DECLARE
  v_count int;
BEGIN
  WITH pick AS (
    SELECT DISTINCT ON (i.id) i.id, r.gl_account_code, r.category_label
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
      AND i.agency_id = p_agency_id
    ORDER BY i.id, r.priority, r.category_label
  ), upd AS (
    UPDATE amazon_order_items i
    SET gl_account_code = pick.gl_account_code,
        category_label  = pick.category_label,
        classified_at   = NOW()
    FROM pick WHERE pick.id = i.id
    RETURNING 1
  )
  SELECT count(*) INTO v_count FROM upd;
  RETURN v_count;
END;
$fn$;
