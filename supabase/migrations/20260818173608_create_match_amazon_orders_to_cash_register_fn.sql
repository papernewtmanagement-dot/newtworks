CREATE OR REPLACE FUNCTION public.match_amazon_orders_to_cash_register(p_agency_id uuid)
RETURNS TABLE(order_id text, matched boolean, reason text) AS $$
DECLARE
  r RECORD;
  candidate RECORD;
  candidate_count int;
  resolved_entity uuid;
BEGIN
  FOR r IN
    SELECT ao.order_id, ao.order_date, ao.grand_total
    FROM amazon_orders ao
    WHERE ao.agency_id = p_agency_id
      AND ao.target_business_entity_id IS NULL
      AND ao.matched_cash_register_id IS NULL
  LOOP
    -- Find cash-register rows matching this order's exact amount, within a
    -- window around the order date (Amazon often charges on ship, not order,
    -- and split shipments can land days apart).
    SELECT count(*) INTO candidate_count
    FROM cash_register_preliminary crp
    WHERE crp.agency_id = p_agency_id
      AND crp.direction = 'debit'
      AND abs(crp.amount) = r.grand_total
      AND crp.txn_date BETWEEN r.order_date::date - 1 AND r.order_date::date + 10;

    IF candidate_count = 1 THEN
      SELECT crp.id, crp.account_last4 INTO candidate
      FROM cash_register_preliminary crp
      WHERE crp.agency_id = p_agency_id
        AND crp.direction = 'debit'
        AND abs(crp.amount) = r.grand_total
        AND crp.txn_date BETWEEN r.order_date::date - 1 AND r.order_date::date + 10
      LIMIT 1;

      SELECT a.business_entity_id INTO resolved_entity
      FROM accounts a
      WHERE a.agency_id = p_agency_id
        AND (a.account_number_last4 = candidate.account_last4
             OR candidate.account_last4 = ANY(a.alternate_last4s))
      LIMIT 1;

      IF resolved_entity IS NOT NULL THEN
        UPDATE amazon_orders
        SET matched_cash_register_id = candidate.id,
            payment_card_last4 = candidate.account_last4,
            target_business_entity_id = resolved_entity,
            matched_at = now()
        WHERE amazon_orders.order_id = r.order_id AND amazon_orders.agency_id = p_agency_id;
        order_id := r.order_id; matched := true; reason := 'matched to card ' || candidate.account_last4;
        RETURN NEXT;
      ELSE
        order_id := r.order_id; matched := false; reason := 'register match found but card ' || candidate.account_last4 || ' not in accounts table';
        RETURN NEXT;
      END IF;
    ELSIF candidate_count = 0 THEN
      order_id := r.order_id; matched := false; reason := 'no cash-register row at this amount/date window';
      RETURN NEXT;
    ELSE
      order_id := r.order_id; matched := false; reason := candidate_count || ' ambiguous register candidates at this amount';
      RETURN NEXT;
    END IF;
  END LOOP;
  RETURN;
END;
$$ LANGUAGE plpgsql;
