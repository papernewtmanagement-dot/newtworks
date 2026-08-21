-- =============================================================================
-- MIGRATION 022: cc_gl_writer (sibling to bank_gl_writer)
-- =============================================================================
-- Walks credit_transactions, posts post-cutover rows to journal_entries.
-- 
-- Resolution waterfall for "other side":
--   1. Direct category text match → account_name in books_historical namespace
--   2. gl_classification_rules priority match against description
--   3. Fallback → COA-SUSP with pending_review status
--
-- Direction:
--   Charge (negative amount): DR <other_side> / CR <credit_card_account>
--   Payment/credit (positive amount): DR <credit_card_account> / CR <other_side>
--
-- NOTE: legacy source has credit card accounts classified as account_type='asset', not 
-- liability. We honor that classification per accounting_rules (CPA presentation
-- is source of truth). Mechanics are identical either way.
-- =============================================================================

-- Add posting tracking columns to credit_transactions
ALTER TABLE credit_transactions ADD COLUMN IF NOT EXISTS posted_at timestamptz;
ALTER TABLE credit_transactions ADD COLUMN IF NOT EXISTS notes text;
ALTER TABLE credit_transactions ADD COLUMN IF NOT EXISTS source_document_id uuid;
-- journal_entry_id already exists per schema check

CREATE OR REPLACE FUNCTION public.cc_gl_writer(
  p_agency_id uuid,
  p_dry_run boolean DEFAULT FALSE
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cutover_date date;
  v_chart_namespace text;
  v_suspense_account_id uuid;
  
  v_txn_id uuid;
  v_credit_account_id uuid;
  v_txn_date date;
  v_description text;
  v_amount numeric;
  v_txn_type text;
  v_category text;
  v_posted_at timestamptz;
  v_existing_je_id uuid;
  
  v_other_side_account_id uuid;
  v_rule_id uuid;
  v_classification_status text;
  v_suspense_reason text;
  
  v_je_id uuid;
  
  v_count_eligible int := 0;
  v_count_skipped_cutover int := 0;
  v_count_skipped_already_posted int := 0;
  v_count_skipped_no_card int := 0;
  v_count_posted_classified int := 0;
  v_count_posted_suspense int := 0;
  v_count_errored int := 0;
  
  v_total_posted numeric := 0;
  v_errors jsonb := '[]'::jsonb;
  v_posted_runs jsonb := '[]'::jsonb;
BEGIN
  -- Settings
  SELECT setting_value::date INTO v_cutover_date
    FROM settings WHERE agency_id = p_agency_id AND setting_key = 'gl_cutover_date';
  IF v_cutover_date IS NULL THEN v_cutover_date := '2026-05-01'::date; END IF;
  
  SELECT setting_value INTO v_chart_namespace
    FROM settings WHERE agency_id = p_agency_id AND setting_key = 'gl_chart_namespace';
  IF v_chart_namespace IS NULL THEN v_chart_namespace := 'books_historical'; END IF;
  
  -- Resolve suspense
  SELECT id INTO v_suspense_account_id
    FROM chart_of_accounts
    WHERE agency_id = p_agency_id AND chart_namespace = v_chart_namespace AND account_code = 'COA-SUSP'
    LIMIT 1;
  
  IF v_suspense_account_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'suspense_account_not_found');
  END IF;
  
  FOR v_txn_id, v_credit_account_id, v_txn_date, v_description, v_amount, v_txn_type,
      v_category, v_posted_at, v_existing_je_id IN
    SELECT id, credit_account_id, transaction_date, description, amount, transaction_type,
           category, posted_at, journal_entry_id
    FROM credit_transactions
    WHERE agency_id = p_agency_id
    ORDER BY transaction_date, id
  LOOP
    v_count_eligible := v_count_eligible + 1;
    v_other_side_account_id := NULL;
    v_rule_id := NULL;
    v_classification_status := NULL;
    v_suspense_reason := NULL;
    
    -- Cutover gate
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
    
    -- Already posted
    IF v_posted_at IS NOT NULL AND v_existing_je_id IS NOT NULL THEN
      v_count_skipped_already_posted := v_count_skipped_already_posted + 1;
      CONTINUE;
    END IF;
    
    -- Validate credit card account
    IF v_credit_account_id IS NULL THEN
      v_count_skipped_no_card := v_count_skipped_no_card + 1;
      v_errors := v_errors || jsonb_build_object(
        'txn_id', v_txn_id, 'reason', 'no_credit_account_id',
        'description', LEFT(v_description, 100)
      );
      CONTINUE;
    END IF;
    
    -- Validate amount
    IF v_amount IS NULL OR v_amount = 0 THEN
      v_count_errored := v_count_errored + 1;
      v_errors := v_errors || jsonb_build_object('txn_id', v_txn_id, 'reason', 'zero_or_null_amount');
      CONTINUE;
    END IF;
    
    -- ===== Resolution waterfall =====
    
    -- 1. Direct category match
    IF v_category IS NOT NULL AND length(trim(v_category)) > 0 THEN
      SELECT id INTO v_other_side_account_id
        FROM chart_of_accounts
        WHERE agency_id = p_agency_id
          AND chart_namespace = v_chart_namespace
          AND account_name = v_category
          AND is_active = TRUE
        LIMIT 1;
      
      IF v_other_side_account_id IS NOT NULL THEN
        v_classification_status := 'classified';
      END IF;
    END IF;
    
    -- 2. gl_classification_rules priority match
    IF v_other_side_account_id IS NULL THEN
      DECLARE
        v_match_direction text;
        v_target_code text;
      BEGIN
        -- For CC: charge (negative) means we want the DEBIT side (expense),
        --        payment (positive) means we want the CREDIT side (income/refund)
        v_match_direction := CASE WHEN v_amount > 0 THEN 'credit' ELSE 'debit' END;
        
        SELECT 
          r.id,
          CASE WHEN v_amount > 0 THEN r.credit_account_code ELSE r.debit_account_code END
        INTO v_rule_id, v_target_code
        FROM gl_classification_rules r
        WHERE r.agency_id = p_agency_id
          AND r.is_active = TRUE
          AND (r.match_payee_regex IS NULL OR v_description ~* r.match_payee_regex)
          AND (r.match_memo_regex IS NULL OR v_description ~* r.match_memo_regex)
          AND (r.match_amount_min IS NULL OR abs(v_amount) >= r.match_amount_min)
          AND (r.match_amount_max IS NULL OR abs(v_amount) <= r.match_amount_max)
          AND (r.match_direction IS NULL OR r.match_direction = v_match_direction)
        ORDER BY r.match_priority ASC NULLS LAST
        LIMIT 1;
        
        IF v_rule_id IS NOT NULL AND v_target_code IS NOT NULL AND v_target_code != '__SOURCE__' THEN
          SELECT id INTO v_other_side_account_id
            FROM chart_of_accounts
            WHERE agency_id = p_agency_id
              AND chart_namespace = v_chart_namespace
              AND account_code = v_target_code
              AND is_active = TRUE
            LIMIT 1;
          
          IF v_other_side_account_id IS NOT NULL THEN
            v_classification_status := 'classified';
            UPDATE gl_classification_rules
            SET historical_uses = COALESCE(historical_uses, 0) + 1,
                last_used_at = NOW()
            WHERE id = v_rule_id;
          END IF;
        END IF;
      END;
    END IF;
    
    -- 3. Suspense fallback
    IF v_other_side_account_id IS NULL THEN
      v_other_side_account_id := v_suspense_account_id;
      v_classification_status := 'pending_review';
      v_suspense_reason := CASE 
        WHEN v_category IS NULL OR length(trim(v_category)) = 0 THEN 'no_category_provided'
        ELSE 'category_unresolved: ' || left(v_category, 80)
      END;
    END IF;
    
    -- ===== Post the JE =====
    DECLARE
      v_dr_account_id uuid;
      v_cr_account_id uuid;
      v_abs_amount numeric := abs(v_amount);
      v_je_description text;
    BEGIN
      -- Direction:
      --   Charge (negative amount): DR other-side (expense up), CR card (card balance up, asset down per legacy source)
      --   Payment (positive amount): DR card (card balance down), CR other-side (or bank)
      IF v_amount < 0 THEN
        v_dr_account_id := v_other_side_account_id;
        v_cr_account_id := v_credit_account_id;
      ELSE
        v_dr_account_id := v_credit_account_id;
        v_cr_account_id := v_other_side_account_id;
      END IF;
      
      v_je_description := COALESCE(v_description, 'Credit card transaction');
      
      IF p_dry_run THEN
        v_posted_runs := v_posted_runs || jsonb_build_object(
          'txn_id', v_txn_id,
          'date', v_txn_date,
          'amount', v_amount,
          'description', left(v_description, 80),
          'dr_account', v_dr_account_id,
          'cr_account', v_cr_account_id,
          'classification_status', v_classification_status,
          'rule_id', v_rule_id,
          'suspense_reason', v_suspense_reason
        );
        IF v_classification_status = 'classified' THEN
          v_count_posted_classified := v_count_posted_classified + 1;
        ELSE
          v_count_posted_suspense := v_count_posted_suspense + 1;
        END IF;
        v_total_posted := v_total_posted + v_abs_amount;
        CONTINUE;
      END IF;
      
      -- Insert JE
      INSERT INTO journal_entries (
        agency_id, entry_date, description, source, reference_number,
        classification_status, suspense_reason, rule_id_used, classified_by, classified_at,
        created_at
      ) VALUES (
        p_agency_id, v_txn_date, v_je_description,
        'cc_gl_writer', 'CCTXN-' || v_txn_id::text,
        v_classification_status, v_suspense_reason, v_rule_id,
        CASE WHEN v_classification_status = 'classified' AND v_rule_id IS NOT NULL THEN 'rule:' || v_rule_id::text
             WHEN v_classification_status = 'classified' THEN 'category_match'
             ELSE NULL END,
        CASE WHEN v_classification_status = 'classified' THEN NOW() ELSE NULL END,
        NOW()
      ) RETURNING id INTO v_je_id;
      
      INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description)
      VALUES (v_je_id, p_agency_id, v_dr_account_id, v_abs_amount, 0, left(v_je_description, 200));
      
      INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description)
      VALUES (v_je_id, p_agency_id, v_cr_account_id, 0, v_abs_amount, left(v_je_description, 200));
      
      UPDATE credit_transactions
      SET journal_entry_id = v_je_id,
          posted_at = NOW(),
          notes = COALESCE(notes, '') || ' [posted by cc_gl_writer ' || NOW()::text || 
                  CASE WHEN v_classification_status = 'pending_review' 
                       THEN '; suspense: ' || COALESCE(v_suspense_reason, 'unknown') 
                       ELSE '' END || ']'
      WHERE id = v_txn_id;
      
      IF v_classification_status = 'classified' THEN
        v_count_posted_classified := v_count_posted_classified + 1;
      ELSE
        v_count_posted_suspense := v_count_posted_suspense + 1;
      END IF;
      v_total_posted := v_total_posted + v_abs_amount;
    END;
  END LOOP;
  
  RETURN jsonb_build_object(
    'ok', TRUE,
    'dry_run', p_dry_run,
    'cutover_date', v_cutover_date,
    'eligible', v_count_eligible,
    'skipped_pre_cutover', v_count_skipped_cutover,
    'skipped_already_posted', v_count_skipped_already_posted,
    'skipped_no_card_account', v_count_skipped_no_card,
    'posted_classified', v_count_posted_classified,
    'posted_suspense', v_count_posted_suspense,
    'errors', v_count_errored,
    'total_amount_posted', v_total_posted,
    'posted_runs', v_posted_runs,
    'error_details', v_errors
  );
END;
$$;

-- Runner-compat overload
CREATE OR REPLACE FUNCTION public.cc_gl_writer(
  p_agency_id uuid,
  p_recipe_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public.cc_gl_writer(p_agency_id, FALSE);
END;
$$;

COMMENT ON FUNCTION public.cc_gl_writer(uuid, boolean) IS
'Posts post-cutover credit_transactions to journal_entries.
Resolution waterfall: category match → classification rules → suspense.
Charge (negative): DR expense, CR card. Payment (positive): DR card, CR other-side.
Pre-cutover archive-only. Idempotent.';
