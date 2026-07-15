-- =========================================================================
-- Bank register coding rule matcher (mirror of production state 2026-07-15)
-- =========================================================================
-- Wires the txn_coding_rules table into an auto-matcher for
-- bank_register_preliminary rows. AFTER INSERT trigger applies the best
-- matching rule (highest specificity, then confidence). High-confidence
-- matches set applied_rule_id + coding_status='auto_classified'.
-- Medium/low → coding_status='needs_peter'. No match → 'unclassified'.
-- Also refreshes v_bank_register_coding_questions to surface NULL statuses.
-- Backfill fn provided for existing uncoded rows.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.apply_coding_rule_to_register_row(p_row_id uuid)
 RETURNS TABLE(matched boolean, rule_id uuid, rule_name text, confidence text, applied boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.tg_bank_register_apply_coding_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  PERFORM public.apply_coding_rule_to_register_row(NEW.id);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_bank_register_apply_coding_rules ON public.bank_register_preliminary;
CREATE TRIGGER trg_bank_register_apply_coding_rules
  AFTER INSERT ON public.bank_register_preliminary
  FOR EACH ROW EXECUTE FUNCTION public.tg_bank_register_apply_coding_rules();

CREATE OR REPLACE FUNCTION public.apply_coding_rules_backfill(p_agency_id uuid)
 RETURNS TABLE(rows_scanned integer, rows_matched integer, rows_auto_applied integer)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_row_id uuid;
  v_scanned int := 0;
  v_matched int := 0;
  v_applied int := 0;
  v_result record;
BEGIN
  FOR v_row_id IN
    SELECT id FROM public.bank_register_preliminary
     WHERE agency_id = p_agency_id
       AND reconciled_journal_entry_id IS NULL
       AND suggested_rule_id IS NULL
     ORDER BY txn_date
  LOOP
    v_scanned := v_scanned + 1;
    SELECT * INTO v_result FROM public.apply_coding_rule_to_register_row(v_row_id);
    IF v_result.matched THEN
      v_matched := v_matched + 1;
      IF v_result.applied THEN v_applied := v_applied + 1; END IF;
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_scanned, v_matched, v_applied;
END;
$function$;

CREATE OR REPLACE VIEW public.v_bank_register_coding_questions AS
 SELECT id,
    txn_date,
    account_label,
    direction,
    amount,
    merchant,
    suggested_debit_account,
    suggested_credit_account,
    suggested_confidence,
    coding_status,
    coding_question,
    status,
    agency_id
   FROM bank_register_preliminary
  WHERE (coding_status IS NULL OR (coding_status = ANY (ARRAY['needs_peter'::text, 'unclassified'::text])))
    AND (status IS NULL OR (status <> ALL (ARRAY['possible_transfer'::text, 'reconciled'::text])))
    AND reconciled_journal_entry_id IS NULL
  ORDER BY txn_date DESC, amount DESC;
