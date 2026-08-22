CREATE OR REPLACE FUNCTION public.amazon_categorize_email_orders(p_agency_id uuid, p_dry_run boolean DEFAULT true)
RETURNS TABLE(order_id text, ledger_id uuid, category text, moved_from text, moved_to text, note text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  r RECORD;
  rule RECORD;
  v_target_account uuid;
  v_entity_name text;
BEGIN
  FOR r IN
    SELECT o.order_id, o.category, o.target_business_entity_id, o.matched_cash_register_id,
           l.id AS ledger_id, l.account_id AS current_account_id,
           coa.account_code AS current_code, coa.account_name AS current_name
    FROM amazon_orders o
    LEFT JOIN ledger l ON l.cash_register_id = o.matched_cash_register_id AND l.agency_id = p_agency_id
    LEFT JOIN chart_of_accounts coa ON coa.id = l.account_id
    WHERE o.agency_id = p_agency_id
      AND o.category IS NOT NULL
      AND o.target_business_entity_id IS NOT NULL
      AND o.matched_cash_register_id IS NOT NULL
      -- Only order-level (no item breakdown) — item-level orders are handled
      -- by amazon_apply_charge_categories / amazon_categorize_new_items instead.
      AND NOT EXISTS (SELECT 1 FROM amazon_order_items i WHERE i.order_id = o.order_id)
  LOOP
    IF r.ledger_id IS NULL THEN
      order_id := r.order_id; ledger_id := NULL; category := r.category;
      moved_from := NULL; moved_to := NULL;
      note := 'no ledger row yet for this cash-register match (writer may not have run)';
      RETURN NEXT;
      CONTINUE;
    END IF;

    SELECT be.name INTO v_entity_name FROM business_entities be WHERE be.id = r.target_business_entity_id;

    SELECT cr.gl_account_code, cr.category_label INTO rule
    FROM amazon_order_category_rules cr
    WHERE cr.agency_id = p_agency_id
      AND cr.is_active
      AND cr.target_business_entity_id = r.target_business_entity_id
      AND r.category ~* cr.category_pattern
    ORDER BY cr.priority, cr.category_label
    LIMIT 1;

    IF rule.gl_account_code IS NULL THEN
      order_id := r.order_id; ledger_id := r.ledger_id; category := r.category;
      moved_from := r.current_code; moved_to := NULL;
      note := 'no category rule matched for this entity';
      RETURN NEXT;
      CONTINUE;
    END IF;

    SELECT coa.id INTO v_target_account
    FROM chart_of_accounts coa
    WHERE coa.agency_id = p_agency_id
      AND coa.account_code = rule.gl_account_code
      AND coa.business_entity_id = r.target_business_entity_id
      AND coa.is_active
    LIMIT 1;

    IF v_target_account IS NULL THEN
      order_id := r.order_id; ledger_id := r.ledger_id; category := r.category;
      moved_from := r.current_code; moved_to := rule.gl_account_code;
      note := 'proposed account does not exist for this entity';
      RETURN NEXT;
      CONTINUE;
    END IF;

    IF r.current_account_id = v_target_account THEN
      order_id := r.order_id; ledger_id := r.ledger_id; category := r.category;
      moved_from := r.current_code; moved_to := rule.gl_account_code;
      note := 'already correct';
      RETURN NEXT;
      CONTINUE;
    END IF;

    IF NOT p_dry_run THEN
      UPDATE ledger l
      SET account_id = v_target_account,
          original_account_id   = COALESCE(l.original_account_id, l.account_id),
          original_account_code = COALESCE(l.original_account_code, r.current_code),
          original_account_name = COALESCE(l.original_account_name, r.current_name),
          classification_status = 'classified',
          classified_by = 'amazon_order_email_category',
          classified_at = NOW(),
          memo = 'Amazon order ' || r.order_id || ' — subject-line category "' || r.category || '" -> ' || rule.category_label
      WHERE l.id = r.ledger_id;
    END IF;

    order_id := r.order_id; ledger_id := r.ledger_id; category := r.category;
    moved_from := r.current_code; moved_to := rule.gl_account_code;
    note := CASE WHEN p_dry_run THEN 'would move to ' || rule.category_label ELSE 'moved to ' || rule.category_label END;
    RETURN NEXT;
  END LOOP;
  RETURN;
END;
$function$;
