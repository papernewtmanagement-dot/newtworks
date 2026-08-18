-- Repoints Amazon ledger lines to the category the order actually calls for.
-- Only touches rows the matcher calls "ready". Will not go back past p_from,
-- which defaults to 2026-08-01 so earlier history is never moved without asking.
CREATE OR REPLACE FUNCTION public.amazon_apply_charge_categories(
  p_agency_id uuid,
  p_from date DEFAULT '2026-08-01',
  p_dry_run boolean DEFAULT true
)
RETURNS TABLE (
  ledger_id uuid, entry_date date, charge_amount numeric,
  moved_from text, moved_to text, order_id text, note text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $fn$
DECLARE
  r record;
  v_target_account uuid;
BEGIN
  FOR r IN
    SELECT m.* FROM v_amazon_charge_matches m
    JOIN ledger l ON l.id = m.ledger_id
    WHERE l.agency_id = p_agency_id
      AND m.entry_date >= p_from
      AND m.verdict LIKE 'ready%'
    ORDER BY m.entry_date, m.ledger_id
  LOOP
    SELECT coa.id INTO v_target_account
    FROM chart_of_accounts coa
    WHERE coa.agency_id = p_agency_id
      AND coa.account_code = r.proposed_code
      AND coa.business_entity_id = r.target_business_entity_id
      AND coa.is_active
    LIMIT 1;

    IF v_target_account IS NULL THEN
      RETURN QUERY SELECT r.ledger_id, r.entry_date, r.charge_amount,
                          r.current_code, r.proposed_code, r.order_id,
                          'skipped: that category does not exist for this entity'::text;
      CONTINUE;
    END IF;

    IF NOT p_dry_run THEN
      UPDATE ledger l
      SET account_id = v_target_account,
          original_account_id   = COALESCE(l.original_account_id, l.account_id),
          original_account_code = COALESCE(l.original_account_code, r.current_code),
          original_account_name = COALESCE(l.original_account_name, r.current_name),
          classification_status = 'classified',
          classified_by = 'amazon_order_match',
          classified_at = NOW(),
          memo = 'Amazon order ' || r.order_id || ' (' || r.order_date || '): ' || r.item_breakdown
      WHERE l.id = r.ledger_id;

      UPDATE amazon_orders o
      SET matched_ledger_id = r.ledger_id, matched_at = NOW(),
          category = r.proposed_label, updated_at = NOW()
      WHERE o.order_id = r.order_id;
    END IF;

    RETURN QUERY SELECT r.ledger_id, r.entry_date, r.charge_amount,
                        r.current_code, r.proposed_code, r.order_id,
                        CASE WHEN p_dry_run THEN 'would move'::text ELSE 'moved'::text END
                        || CASE WHEN r.distinct_categories > 1
                                THEN ' (mixed order, majority category, full split in memo)'
                                ELSE '' END;
  END LOOP;
END;
$fn$;
