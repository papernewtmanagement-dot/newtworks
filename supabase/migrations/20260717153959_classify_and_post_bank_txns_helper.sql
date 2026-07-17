-- Batch classifier + poster for bank/CC transactions. Mirrors the TS
-- classifyBankTxn + postJournalEntry pipeline in the doc-processor edge fn.
-- Purpose: reprocess archived statements without spinning up the edge fn
-- path (which requires Gmail intake).

CREATE OR REPLACE FUNCTION public.classify_and_post_bank_txns(
  p_agency_id uuid,
  p_source_document_id uuid,
  p_source_account_code text,   -- COA code of the bank/card, e.g. 'COA-006'
  p_txns jsonb                   -- [{"date":"YYYY-MM-DD","payee":"...","memo":"...","amount":<±number>}, ...]
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_txn jsonb;
  v_amt numeric;
  v_payee text;
  v_memo text;
  v_date date;
  v_direction text;
  v_rule record;
  v_debit_code text;
  v_credit_code text;
  v_debit_id uuid;
  v_credit_id uuid;
  v_je_id uuid;
  v_reference text;
  v_is_suspense boolean;
  v_desc text;
  v_je_count int := 0;
  v_susp_count int := 0;
  v_skipped_count int := 0;
  v_no_acct_count int := 0;
BEGIN
  FOR v_txn IN SELECT jsonb_array_elements(p_txns) LOOP
    v_amt := (v_txn->>'amount')::numeric;
    IF v_amt IS NULL OR v_amt = 0 THEN
      v_skipped_count := v_skipped_count + 1;
      CONTINUE;
    END IF;
    v_payee := COALESCE(v_txn->>'payee', '');
    v_memo := COALESCE(v_txn->>'memo', '');
    v_date := (v_txn->>'date')::date;
    v_direction := CASE WHEN v_amt > 0 THEN 'credit' ELSE 'debit' END;

    -- Idempotency reference
    v_reference := 'bank_reparse:' || p_source_document_id::text || ':' || v_date::text
                || ':' || md5(v_payee || '|' || v_memo || '|' || v_amt::text);

    IF EXISTS(SELECT 1 FROM public.journal_entries
              WHERE agency_id = p_agency_id AND reference_number = v_reference) THEN
      v_skipped_count := v_skipped_count + 1;
      CONTINUE;
    END IF;

    -- Match against gl_classification_rules by priority
    SELECT id, rule_name, debit_account_code, credit_account_code, sub_category_label
      INTO v_rule
    FROM public.gl_classification_rules r
    WHERE r.agency_id = p_agency_id
      AND r.is_active = TRUE
      AND r.confidence != 'suspense'
      AND (r.match_direction = 'both' OR r.match_direction = v_direction)
      AND (r.match_payee_regex IS NULL OR v_payee ~* r.match_payee_regex)
      AND (r.match_memo_regex IS NULL OR v_memo ~* r.match_memo_regex)
      AND (r.match_source_account IS NULL OR r.match_source_account = p_source_account_code)
      AND (r.match_amount_min IS NULL OR abs(v_amt) >= r.match_amount_min)
      AND (r.match_amount_max IS NULL OR abs(v_amt) <= r.match_amount_max)
    ORDER BY r.match_priority ASC
    LIMIT 1;

    IF v_rule.id IS NOT NULL THEN
      v_debit_code := CASE WHEN v_rule.debit_account_code = '__SOURCE__'
                           THEN p_source_account_code ELSE v_rule.debit_account_code END;
      v_credit_code := CASE WHEN v_rule.credit_account_code = '__SOURCE__'
                            THEN p_source_account_code ELSE v_rule.credit_account_code END;
      v_is_suspense := FALSE;
      v_desc := v_payee || CASE WHEN v_rule.sub_category_label IS NOT NULL
                                     AND v_rule.sub_category_label != ''
                                THEN ' — ' || v_rule.sub_category_label ELSE '' END;
    ELSE
      -- Suspense — outflow debits SUSP, inflow credits SUSP
      IF v_amt < 0 THEN
        v_debit_code := 'COA-SUSP';
        v_credit_code := p_source_account_code;
      ELSE
        v_debit_code := p_source_account_code;
        v_credit_code := 'COA-SUSP';
      END IF;
      v_is_suspense := TRUE;
      v_desc := v_payee;
    END IF;

    SELECT id INTO v_debit_id FROM public.chart_of_accounts
      WHERE agency_id = p_agency_id AND account_code = v_debit_code LIMIT 1;
    SELECT id INTO v_credit_id FROM public.chart_of_accounts
      WHERE agency_id = p_agency_id AND account_code = v_credit_code LIMIT 1;

    IF v_debit_id IS NULL OR v_credit_id IS NULL THEN
      v_no_acct_count := v_no_acct_count + 1;
      CONTINUE;
    END IF;

    INSERT INTO public.journal_entries(
      agency_id, entry_date, entry_type, reference_number, description, memo,
      source, document_id, classification_status, suspense_reason,
      rule_id_used, classified_by, classified_at, created_by, created_at
    ) VALUES (
      p_agency_id, v_date, 'bank_txn', v_reference, v_desc,
      NULLIF(v_memo, ''),
      'claude_bank_reparse', p_source_document_id,
      CASE WHEN v_is_suspense THEN 'pending_review' ELSE 'classified' END,
      CASE WHEN v_is_suspense THEN 'no_rule_match' ELSE NULL END,
      v_rule.id,
      CASE WHEN v_is_suspense THEN NULL ELSE 'rule' END,
      CASE WHEN v_is_suspense THEN NULL ELSE NOW() END,
      'claude_bank_reparse', NOW()
    ) RETURNING id INTO v_je_id;

    INSERT INTO public.journal_lines(journal_entry_id, agency_id, account_id, debit, credit, description)
    VALUES
      (v_je_id, p_agency_id, v_debit_id,  abs(v_amt), 0,           v_desc),
      (v_je_id, p_agency_id, v_credit_id, 0,          abs(v_amt),  v_desc);

    v_je_count := v_je_count + 1;
    IF v_is_suspense THEN v_susp_count := v_susp_count + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'je_count', v_je_count,
    'suspense_count', v_susp_count,
    'skipped_count', v_skipped_count,
    'no_account_count', v_no_acct_count
  );
END; $$;;