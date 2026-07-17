-- Use canonical coding_status values per existing CHECK constraint:
--   auto_classified (high-confidence rule applied)
--   needs_peter    (medium/low match — Peter reviews suggestion)
--   unclassified   (no rule matched)
CREATE OR REPLACE FUNCTION public.apply_coding_rule_to_register_row(p_row_id uuid)
RETURNS TABLE (
  matched boolean,
  rule_id uuid,
  rule_name text,
  confidence text,
  applied boolean
) LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_row public.bank_register_preliminary%ROWTYPE;
  v_rule public.txn_coding_rules%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM public.bank_register_preliminary WHERE id = p_row_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::text, NULL::text, false;
    RETURN;
  END IF;

  IF v_row.reconciled_journal_entry_id IS NOT NULL THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::text, NULL::text, false;
    RETURN;
  END IF;

  SELECT r.* INTO v_rule
  FROM public.txn_coding_rules r
  WHERE r.agency_id = v_row.agency_id
    AND r.is_active = true
    AND (r.match_direction    IS NULL OR r.match_direction    = v_row.direction)
    AND (r.match_account_last4 IS NULL OR r.match_account_last4 = v_row.account_last4)
    AND (
      r.match_merchant IS NULL
      OR (
        v_row.merchant IS NOT NULL
        AND CASE COALESCE(r.match_merchant_mode, 'contains')
          WHEN 'exact'      THEN UPPER(v_row.merchant) = UPPER(r.match_merchant)
          WHEN 'startswith' THEN UPPER(v_row.merchant) LIKE UPPER(r.match_merchant) || '%'
          ELSE                    UPPER(v_row.merchant) LIKE '%' || UPPER(r.match_merchant) || '%'
        END
      )
    )
    AND (r.match_amount_min IS NULL OR v_row.amount >= r.match_amount_min)
    AND (r.match_amount_max IS NULL OR v_row.amount <= r.match_amount_max)
  ORDER BY
      (CASE WHEN r.match_merchant       IS NOT NULL THEN 1 ELSE 0 END
     + CASE WHEN r.match_account_last4  IS NOT NULL THEN 1 ELSE 0 END
     + CASE WHEN r.match_amount_min     IS NOT NULL THEN 1 ELSE 0 END
     + CASE WHEN r.match_amount_max     IS NOT NULL THEN 1 ELSE 0 END) DESC,
      CASE r.confidence WHEN 'high' THEN 3 WHEN 'medium' THEN 2 WHEN 'low' THEN 1 ELSE 0 END DESC,
      r.rule_name
  LIMIT 1;

  IF NOT FOUND THEN
    UPDATE public.bank_register_preliminary
       SET coding_status = COALESCE(coding_status, 'unclassified'),
           updated_at    = NOW()
     WHERE id = p_row_id;
    RETURN QUERY SELECT false, NULL::uuid, NULL::text, NULL::text, false;
    RETURN;
  END IF;

  UPDATE public.bank_register_preliminary
     SET suggested_debit_account  = v_rule.debit_account,
         suggested_credit_account = v_rule.credit_account,
         suggested_rule_id        = v_rule.id,
         suggested_confidence     = v_rule.confidence,
         applied_rule_id          = CASE WHEN v_rule.confidence = 'high' THEN v_rule.id ELSE applied_rule_id END,
         coding_status            = CASE
                                      WHEN v_rule.confidence = 'high'   THEN 'auto_classified'
                                      ELSE 'needs_peter'
                                    END,
         updated_at               = NOW()
   WHERE id = p_row_id;

  UPDATE public.txn_coding_rules
     SET usage_count     = COALESCE(usage_count, 0) + 1,
         last_matched_at = NOW()
   WHERE id = v_rule.id;

  RETURN QUERY SELECT true, v_rule.id, v_rule.rule_name, v_rule.confidence, (v_rule.confidence = 'high');
END;
$$;

-- View: surface NULL, 'needs_peter', 'unclassified' rows for Peter's review
CREATE OR REPLACE VIEW public.v_bank_register_coding_questions AS
SELECT id, txn_date, account_label, direction, amount, merchant,
       suggested_debit_account, suggested_credit_account, suggested_confidence,
       coding_status, coding_question, status,
       agency_id
  FROM public.bank_register_preliminary
 WHERE (coding_status IS NULL
        OR coding_status = ANY (ARRAY['needs_peter','unclassified']))
   AND (status IS NULL
        OR status <> ALL (ARRAY['possible_transfer','reconciled']))
   AND reconciled_journal_entry_id IS NULL
 ORDER BY txn_date DESC, amount DESC;;