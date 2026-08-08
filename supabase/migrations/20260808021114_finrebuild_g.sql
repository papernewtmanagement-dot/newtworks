-- finrebuild_f2_statement_gl_writer_legacy_txn_type_vocab
-- The 1,542 merge-era statements rows carry transaction_type vocabulary from
-- their pre-rebuild writers, not the new vocabulary document-processor/
-- llm-queue-drainer now write. Verified against real data (not guessed):
--   bank:   'credit' (amount>=0, 23 rows) = deposit-direction; 'debit' (amount<0, 8 rows) = withdrawal-direction
--   credit: 'credit' (amount<0, 18 rows) and 'payment' (amount<0, 57 rows) = credit-direction (matches old cc_gl_writer's own mapping)
-- One row has transaction_type NULL — left as a genuine error, not guessed
-- from amount sign, consistent with D15.
CREATE OR REPLACE FUNCTION public.statement_gl_writer(
  p_agency_id uuid,
  p_account_id uuid DEFAULT NULL,
  p_from date DEFAULT NULL,
  p_to date DEFAULT NULL,
  p_dry_run boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_stmt_id uuid; v_business_entity_id uuid; v_txn_date date;
  v_description text; v_amount numeric; v_transaction_type text; v_category text;
  v_reference_number text; v_chart_account_code text;
  v_direction text; v_target_account_id uuid; v_rule_id uuid; v_classification_status text;
  v_count_total int := 0; v_count_skipped_no_je int := 0; v_count_skipped_already_posted int := 0;
  v_count_direct_category int := 0; v_count_rule_matched int := 0; v_count_unclassified int := 0;
  v_count_errored int := 0;
  v_total_direct numeric := 0; v_total_rule numeric := 0; v_total_unclassified numeric := 0;
  v_errors jsonb := '[]'::jsonb;
  v_unclassified_items jsonb := '[]'::jsonb;
  v_top_unclassified jsonb;
BEGIN
  FOR v_stmt_id, v_business_entity_id, v_txn_date, v_description, v_amount,
      v_transaction_type, v_category, v_reference_number, v_chart_account_code IN
    SELECT s.id, s.business_entity_id, s.transaction_date, s.description, s.amount,
           s.transaction_type, s.category, s.reference_number, coa.account_code
    FROM statements s
    LEFT JOIN accounts a ON a.id = s.account_id
    LEFT JOIN chart_of_accounts coa ON coa.id = a.chart_account_id
    WHERE s.agency_id = p_agency_id
      AND (p_account_id IS NULL OR s.account_id = p_account_id)
      AND (p_from IS NULL OR s.transaction_date >= p_from)
      AND (p_to IS NULL OR s.transaction_date <= p_to)
    ORDER BY s.transaction_date, s.id
  LOOP
    v_count_total := v_count_total + 1;
    v_target_account_id := NULL; v_rule_id := NULL; v_classification_status := NULL;

    IF EXISTS (SELECT 1 FROM ledger WHERE statement_id = v_stmt_id) THEN
      v_count_skipped_already_posted := v_count_skipped_already_posted + 1;
      CONTINUE;
    END IF;

    IF v_category IS NOT NULL AND upper(trim(v_category)) LIKE '%\_NO\_JE' THEN
      v_count_skipped_no_je := v_count_skipped_no_je + 1;
      CONTINUE;
    END IF;

    v_direction := CASE
      WHEN v_transaction_type IN ('withdrawal','charge','debit') THEN 'debit'
      WHEN v_transaction_type IN ('deposit','payment_or_credit','credit','payment') THEN 'credit'
      ELSE NULL
    END;
    IF v_direction IS NULL THEN
      v_count_errored := v_count_errored + 1;
      v_errors := v_errors || jsonb_build_object(
        'statement_id', v_stmt_id, 'reason',
        'unrecognized_transaction_type: ' || coalesce(v_transaction_type, 'null')
      );
      CONTINUE;
    END IF;

    IF v_category IS NOT NULL AND length(trim(v_category)) > 0 THEN
      SELECT id INTO v_target_account_id FROM chart_of_accounts
      WHERE agency_id = p_agency_id AND account_name = v_category AND is_active = TRUE
        AND account_type != 'income'
        AND (business_entity_id = v_business_entity_id OR business_entity_id IS NULL)
      ORDER BY (business_entity_id = v_business_entity_id) DESC NULLS LAST
      LIMIT 1;
      IF v_target_account_id IS NOT NULL THEN
        v_classification_status := 'classified';
        v_count_direct_category := v_count_direct_category + 1;
        v_total_direct := v_total_direct + abs(v_amount);
      END IF;
    END IF;

    IF v_target_account_id IS NULL THEN
      DECLARE v_target_code text;
      BEGIN
        SELECT r.id,
          CASE WHEN v_direction = 'credit' THEN r.credit_account_code ELSE r.debit_account_code END
        INTO v_rule_id, v_target_code
        FROM gl_classification_rules r
        WHERE r.agency_id = p_agency_id AND r.is_active = TRUE
          AND (r.match_payee_regex IS NULL OR v_description ~* r.match_payee_regex)
          AND (r.match_memo_regex IS NULL OR v_description ~* r.match_memo_regex)
          AND (r.match_source_account IS NULL OR r.match_source_account = v_chart_account_code)
          AND (r.match_amount_min IS NULL OR abs(v_amount) >= r.match_amount_min)
          AND (r.match_amount_max IS NULL OR abs(v_amount) <= r.match_amount_max)
          AND (r.match_direction IS NULL OR r.match_direction = v_direction OR r.match_direction = 'both')
          AND (CASE WHEN v_direction = 'credit' THEN r.credit_account_code ELSE r.debit_account_code END) IS NOT NULL
          AND (CASE WHEN v_direction = 'credit' THEN r.credit_account_code ELSE r.debit_account_code END) != '__SOURCE__'
        ORDER BY r.match_priority ASC NULLS LAST
        LIMIT 1;

        IF v_rule_id IS NOT NULL AND v_target_code IS NOT NULL THEN
          SELECT id INTO v_target_account_id FROM chart_of_accounts
          WHERE agency_id = p_agency_id AND account_code = v_target_code AND is_active = TRUE
            AND account_type != 'income'
            AND (business_entity_id = v_business_entity_id OR business_entity_id IS NULL)
          ORDER BY (business_entity_id = v_business_entity_id) DESC NULLS LAST
          LIMIT 1;
          IF v_target_account_id IS NULL THEN
            SELECT id INTO v_target_account_id FROM chart_of_accounts
            WHERE agency_id = p_agency_id AND account_code = v_target_code AND is_active = TRUE
              AND account_type != 'income'
            LIMIT 1;
          END IF;

          IF v_target_account_id IS NOT NULL THEN
            v_classification_status := 'classified';
            v_count_rule_matched := v_count_rule_matched + 1;
            v_total_rule := v_total_rule + abs(v_amount);
            IF NOT p_dry_run THEN
              UPDATE gl_classification_rules
              SET historical_uses = COALESCE(historical_uses, 0) + 1, last_used_at = NOW()
              WHERE id = v_rule_id;
            END IF;
          ELSE
            v_rule_id := NULL;
          END IF;
        END IF;
      END;
    END IF;

    IF v_target_account_id IS NULL THEN
      v_target_account_id := get_entity_unclassified_account(
        p_agency_id, v_business_entity_id,
        CASE WHEN v_direction = 'credit' THEN 'income' ELSE 'expense' END
      );
      IF v_target_account_id IS NULL THEN
        v_count_errored := v_count_errored + 1;
        v_errors := v_errors || jsonb_build_object(
          'statement_id', v_stmt_id, 'reason', 'no_unclassified_account_for_entity',
          'business_entity_id', v_business_entity_id
        );
        CONTINUE;
      END IF;
      v_classification_status := 'unclassified';
      v_count_unclassified := v_count_unclassified + 1;
      v_total_unclassified := v_total_unclassified + abs(v_amount);
      v_unclassified_items := v_unclassified_items || jsonb_build_object(
        'description', v_description, 'amount', abs(v_amount), 'date', v_txn_date
      );
    END IF;

    IF NOT p_dry_run THEN
      INSERT INTO ledger (
        agency_id, entry_date, account_id, debit, credit, description,
        source, reference_number, statement_id, rule_id_used, classification_status,
        classified_by, classified_at, entry_type
      ) VALUES (
        p_agency_id, v_txn_date, v_target_account_id,
        CASE WHEN v_direction = 'debit' THEN abs(v_amount) ELSE 0 END,
        CASE WHEN v_direction = 'credit' THEN abs(v_amount) ELSE 0 END,
        v_description, 'statement_gl_writer', v_reference_number, v_stmt_id, v_rule_id,
        v_classification_status,
        CASE WHEN v_rule_id IS NOT NULL THEN 'rule:' || v_rule_id::text
             WHEN v_classification_status = 'classified' THEN 'category_match'
             ELSE NULL END,
        CASE WHEN v_classification_status = 'classified' THEN NOW() ELSE NULL END,
        'statement_txn'
      );
    END IF;
  END LOOP;

  SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) INTO v_top_unclassified
  FROM (
    SELECT (item->>'description') AS description, SUM((item->>'amount')::numeric) AS total_amount, count(*) AS n
    FROM jsonb_array_elements(v_unclassified_items) AS item
    GROUP BY (item->>'description')
    ORDER BY SUM((item->>'amount')::numeric) DESC
    LIMIT 20
  ) t;

  RETURN jsonb_build_object(
    'ok', TRUE, 'dry_run', p_dry_run,
    'total_statements_seen', v_count_total,
    'skipped_already_posted', v_count_skipped_already_posted,
    'skipped_no_je_marker', v_count_skipped_no_je,
    'direct_category_matched', v_count_direct_category, 'direct_category_amount', v_total_direct,
    'rule_matched', v_count_rule_matched, 'rule_matched_amount', v_total_rule,
    'unclassified', v_count_unclassified, 'unclassified_amount', v_total_unclassified,
    'errors', v_count_errored, 'error_details', v_errors,
    'top_20_unclassified_merchants', v_top_unclassified
  );
END;
$function$;