-- Enforce match_source_account on cc_gl_writer as well.
-- Prior version referenced the column only in a "must have at least one matcher" guard,
-- but did NOT actually filter rules to those matching the transaction's source card.
-- Result: Amazon-on-Discover rule fired on AMEX/Cap One/USB3447 Amazon charges too.

CREATE OR REPLACE FUNCTION public.cc_gl_writer(p_agency_id uuid, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cutover_date date;
  v_suspense_account_id uuid;
  v_txn_id uuid; v_credit_account_id uuid; v_card_chart_account_id uuid; v_card_name text;
  v_card_source_code text;
  v_txn_date date; v_description text; v_amount numeric; v_txn_type text; v_category text;
  v_posted_at timestamptz; v_existing_je_id uuid;
  v_other_side_account_id uuid; v_rule_id uuid;
  v_classification_status text; v_suspense_reason text;
  v_je_id uuid; v_dup_je_id uuid;
  v_count_eligible int := 0; v_count_skipped_cutover int := 0; v_count_skipped_already_posted int := 0;
  v_count_skipped_no_card int := 0; v_count_skipped_unlinked_card int := 0;
  v_count_skipped_duplicate int := 0; v_count_posted_classified int := 0;
  v_count_posted_suspense int := 0; v_count_errored int := 0;
  v_total_posted numeric := 0; v_errors jsonb := '[]'::jsonb; v_posted_runs jsonb := '[]'::jsonb;
BEGIN
  SELECT setting_value::date INTO v_cutover_date FROM settings
    WHERE agency_id = p_agency_id AND setting_key = 'gl_cutover_date';
  IF v_cutover_date IS NULL THEN v_cutover_date := '1900-01-01'::date; END IF;

  SELECT id INTO v_suspense_account_id FROM chart_of_accounts
    WHERE agency_id = p_agency_id AND account_code = 'COA-SUSP' LIMIT 1;
  IF v_suspense_account_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'suspense_account_not_found');
  END IF;

  FOR v_txn_id, v_credit_account_id, v_card_chart_account_id, v_card_name,
      v_txn_date, v_description, v_amount, v_txn_type, v_category,
      v_posted_at, v_existing_je_id IN
    SELECT ct.id, ct.credit_account_id, ca.chart_account_id, ca.account_name,
           ct.transaction_date, ct.description, ct.amount, ct.transaction_type, ct.category,
           ct.posted_at, ct.journal_entry_id
    FROM credit_transactions ct
    LEFT JOIN credit_accounts ca ON ca.id = ct.credit_account_id
    WHERE ct.agency_id = p_agency_id
    ORDER BY ct.transaction_date, ct.id
  LOOP
    v_count_eligible := v_count_eligible + 1;
    v_other_side_account_id := NULL; v_rule_id := NULL;
    v_classification_status := NULL; v_suspense_reason := NULL; v_dup_je_id := NULL;
    v_card_source_code := NULL;

    IF v_txn_date < v_cutover_date THEN
      v_count_skipped_cutover := v_count_skipped_cutover + 1;
      IF NOT p_dry_run AND v_posted_at IS NULL THEN
        UPDATE credit_transactions
        SET posted_at = NOW(),
            notes = COALESCE(notes, '') || ' [pre-cutover; no JE posted per accounting_rules]'
        WHERE id = v_txn_id;
      END IF;
      CONTINUE;
    END IF;

    IF v_posted_at IS NOT NULL AND v_existing_je_id IS NOT NULL THEN
      v_count_skipped_already_posted := v_count_skipped_already_posted + 1; CONTINUE;
    END IF;

    IF v_credit_account_id IS NULL THEN
      v_count_skipped_no_card := v_count_skipped_no_card + 1;
      v_errors := v_errors || jsonb_build_object('txn_id', v_txn_id, 'reason', 'no_credit_account_id');
      CONTINUE;
    END IF;

    IF v_card_chart_account_id IS NULL THEN
      v_count_skipped_unlinked_card := v_count_skipped_unlinked_card + 1;
      v_errors := v_errors || jsonb_build_object('txn_id', v_txn_id, 'reason', 'credit_account_not_linked_to_chart');
      CONTINUE;
    END IF;

    -- Resolve the card's chart-of-accounts code so match_source_account scoping can be enforced
    SELECT account_code INTO v_card_source_code
    FROM chart_of_accounts
    WHERE id = v_card_chart_account_id;

    IF v_amount IS NULL OR v_amount = 0 THEN
      v_count_errored := v_count_errored + 1;
      v_errors := v_errors || jsonb_build_object('txn_id', v_txn_id, 'reason', 'zero_or_null_amount');
      CONTINUE;
    END IF;

    SELECT je.id INTO v_dup_je_id
    FROM journal_entries je JOIN journal_lines jl ON jl.journal_entry_id = je.id
    WHERE je.agency_id = p_agency_id AND je.entry_date = v_txn_date AND je.source != 'cc_gl_writer'
      AND jl.account_id = v_card_chart_account_id
      AND (jl.debit = abs(v_amount) OR jl.credit = abs(v_amount))
    LIMIT 1;

    IF v_dup_je_id IS NOT NULL THEN
      v_count_skipped_duplicate := v_count_skipped_duplicate + 1;
      IF NOT p_dry_run THEN
        UPDATE credit_transactions
        SET journal_entry_id = v_dup_je_id, posted_at = NOW(),
            notes = COALESCE(notes, '') || ' [linked to existing JE ' || v_dup_je_id::text || ' from other source]'
        WHERE id = v_txn_id;
      END IF;
      CONTINUE;
    END IF;

    -- 1. Direct category match. STRUCTURAL: reject income (cards don't produce income).
    IF v_category IS NOT NULL AND length(trim(v_category)) > 0 THEN
      SELECT id INTO v_other_side_account_id FROM chart_of_accounts
        WHERE agency_id = p_agency_id AND account_name = v_category AND is_active = TRUE
          AND account_type != 'income'
        LIMIT 1;
      IF v_other_side_account_id IS NOT NULL THEN v_classification_status := 'classified'; END IF;
    END IF;

    -- 2. Rule matching. STRUCTURAL: reject rules whose target for this direction is income.
    IF v_other_side_account_id IS NULL THEN
      DECLARE v_rule_direction text; v_target_code text;
      BEGIN
        v_rule_direction := CASE
          WHEN v_txn_type = 'charge' THEN 'debit'
          WHEN v_txn_type IN ('payment','credit') THEN 'credit'
          WHEN v_amount > 0 THEN 'debit'
          ELSE 'credit'
        END;

        SELECT r.id,
          CASE WHEN v_rule_direction = 'credit' THEN r.credit_account_code ELSE r.debit_account_code END
        INTO v_rule_id, v_target_code
        FROM gl_classification_rules r
        LEFT JOIN chart_of_accounts target_coa
          ON target_coa.agency_id = p_agency_id
         AND target_coa.account_code =
             (CASE WHEN v_rule_direction = 'credit' THEN r.credit_account_code ELSE r.debit_account_code END)
        WHERE r.agency_id = p_agency_id AND r.is_active = TRUE
          AND NOT (COALESCE(r.debit_account_code, '') = 'COA-SUSP'
                   AND COALESCE(r.credit_account_code, '') = 'COA-SUSP')
          AND (r.match_payee_regex IS NOT NULL OR r.match_memo_regex IS NOT NULL
               OR r.match_source_account IS NOT NULL)
          AND (r.match_payee_regex IS NULL OR v_description ~* r.match_payee_regex)
          AND (r.match_memo_regex IS NULL OR v_description ~* r.match_memo_regex)
          AND (r.match_source_account IS NULL OR r.match_source_account = v_card_source_code)
          AND (r.match_amount_min IS NULL OR abs(v_amount) >= r.match_amount_min)
          AND (r.match_amount_max IS NULL OR abs(v_amount) <= r.match_amount_max)
          AND (r.match_direction IS NULL OR r.match_direction = v_rule_direction
               OR r.match_direction = 'both')
          AND (CASE WHEN v_rule_direction = 'credit' THEN r.credit_account_code ELSE r.debit_account_code END)
              IS NOT NULL
          AND (CASE WHEN v_rule_direction = 'credit' THEN r.credit_account_code ELSE r.debit_account_code END)
              NOT IN ('__SOURCE__', 'COA-SUSP')
          AND target_coa.account_type != 'income'
        ORDER BY r.match_priority ASC NULLS LAST LIMIT 1;

        IF v_rule_id IS NOT NULL AND v_target_code IS NOT NULL THEN
          SELECT id INTO v_other_side_account_id FROM chart_of_accounts
            WHERE agency_id = p_agency_id AND account_code = v_target_code AND is_active = TRUE
            LIMIT 1;
          IF v_other_side_account_id IS NOT NULL THEN
            v_classification_status := 'classified';
            IF NOT p_dry_run THEN
              UPDATE gl_classification_rules
              SET historical_uses = COALESCE(historical_uses, 0) + 1, last_used_at = NOW()
              WHERE id = v_rule_id;
            END IF;
          END IF;
        END IF;
      END;
    END IF;

    IF v_other_side_account_id IS NULL THEN
      v_other_side_account_id := v_suspense_account_id;
      v_classification_status := 'pending_review';
      v_suspense_reason := CASE
        WHEN v_category IS NULL OR length(trim(v_category)) = 0 THEN 'no_category_provided'
        ELSE 'category_unresolved: ' || left(v_category, 80)
      END;
    END IF;

    DECLARE
      v_dr_account_id uuid; v_cr_account_id uuid;
      v_abs_amount numeric := abs(v_amount);
      v_je_description text; v_is_charge boolean;
    BEGIN
      v_is_charge := CASE
        WHEN v_txn_type = 'charge' THEN TRUE
        WHEN v_txn_type IN ('payment','credit') THEN FALSE
        WHEN v_amount > 0 THEN TRUE ELSE FALSE END;

      IF v_is_charge THEN
        v_dr_account_id := v_other_side_account_id; v_cr_account_id := v_card_chart_account_id;
      ELSE
        v_dr_account_id := v_card_chart_account_id; v_cr_account_id := v_other_side_account_id;
      END IF;

      v_je_description := COALESCE(v_description, 'Credit card transaction') || ' [' || v_card_name || ']';

      IF p_dry_run THEN
        IF v_classification_status = 'classified' THEN v_count_posted_classified := v_count_posted_classified + 1;
        ELSE v_count_posted_suspense := v_count_posted_suspense + 1; END IF;
        v_total_posted := v_total_posted + v_abs_amount;
        CONTINUE;
      END IF;

      INSERT INTO journal_entries (
        agency_id, entry_date, description, source, reference_number,
        classification_status, suspense_reason, rule_id_used, classified_by, classified_at, created_at
      ) VALUES (
        p_agency_id, v_txn_date, v_je_description, 'cc_gl_writer', 'CCTXN-' || v_txn_id::text,
        v_classification_status, v_suspense_reason, v_rule_id,
        CASE WHEN v_classification_status = 'classified' AND v_rule_id IS NOT NULL THEN 'rule:' || v_rule_id::text
             WHEN v_classification_status = 'classified' THEN 'category_match' ELSE NULL END,
        CASE WHEN v_classification_status = 'classified' THEN NOW() ELSE NULL END, NOW()
      ) RETURNING id INTO v_je_id;

      INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description)
      VALUES (v_je_id, p_agency_id, v_dr_account_id, v_abs_amount, 0, left(v_je_description, 200));
      INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description)
      VALUES (v_je_id, p_agency_id, v_cr_account_id, 0, v_abs_amount, left(v_je_description, 200));

      UPDATE credit_transactions
      SET journal_entry_id = v_je_id, posted_at = NOW(),
          notes = COALESCE(notes, '') || ' [posted by cc_gl_writer ' || NOW()::text ||
                  CASE WHEN v_classification_status = 'pending_review'
                       THEN '; suspense: ' || COALESCE(v_suspense_reason, 'unknown')
                       ELSE '' END || ']'
      WHERE id = v_txn_id;

      IF v_classification_status = 'classified' THEN v_count_posted_classified := v_count_posted_classified + 1;
      ELSE v_count_posted_suspense := v_count_posted_suspense + 1; END IF;
      v_total_posted := v_total_posted + v_abs_amount;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', TRUE, 'dry_run', p_dry_run, 'cutover_date', v_cutover_date,
    'eligible', v_count_eligible,
    'skipped_pre_cutover', v_count_skipped_cutover,
    'skipped_already_posted', v_count_skipped_already_posted,
    'skipped_no_card_account', v_count_skipped_no_card,
    'skipped_unlinked_card', v_count_skipped_unlinked_card,
    'skipped_duplicate', v_count_skipped_duplicate,
    'posted_classified', v_count_posted_classified,
    'posted_suspense', v_count_posted_suspense,
    'errors', v_count_errored, 'total_amount_posted', v_total_posted,
    'error_details', v_errors
  );
END;
$function$;
