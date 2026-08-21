-- =============================================================================
-- MIGRATION 025: gl_entry_writer v2
-- Rewrite to use comp_category_map and comp_deduction_map.
-- Splits comp_recap rows by comp_category prefix:
--   deduction_* → expense path (DR <expense account> / CR <cash account>)
--   everything else → revenue path (DR <cash account> / CR <revenue account>)
-- =============================================================================

DROP FUNCTION IF EXISTS public.gl_entry_writer(uuid, uuid);
DROP FUNCTION IF EXISTS public.gl_entry_writer(uuid, boolean);

CREATE OR REPLACE FUNCTION public.gl_entry_writer(
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
  v_cash_acct_name text;
  v_sf_parent_name text;
  v_cash_acct_id uuid;
  v_sf_parent_id uuid;
  v_suspense_id uuid;
  
  v_id uuid;
  v_period_year int;
  v_period_month int;
  v_period_day int;
  v_comp_type text;
  v_comp_category text;
  v_amount numeric;
  v_description text;
  v_posted_at timestamptz;
  
  v_entry_date date;
  v_is_deduction boolean;
  v_target_account_id uuid;
  v_target_account_name text;
  v_classification_status text;
  v_suspense_reason text;
  v_je_id uuid;
  
  v_count_eligible int := 0;
  v_count_skipped_cutover int := 0;
  v_count_skipped_already int := 0;
  v_count_posted_rev int := 0;
  v_count_posted_ded int := 0;
  v_count_posted_susp int := 0;
  v_count_errored int := 0;
  v_total_revenue numeric := 0;
  v_total_deductions numeric := 0;
  v_posted_runs jsonb := '[]'::jsonb;
  v_errors jsonb := '[]'::jsonb;
BEGIN
  -- Load settings
  SELECT setting_value::date INTO v_cutover_date FROM settings 
    WHERE agency_id = p_agency_id AND setting_key = 'gl_cutover_date';
  IF v_cutover_date IS NULL THEN v_cutover_date := '2026-05-01'::date; END IF;
  
  SELECT setting_value INTO v_chart_namespace FROM settings 
    WHERE agency_id = p_agency_id AND setting_key = 'gl_chart_namespace';
  IF v_chart_namespace IS NULL THEN v_chart_namespace := 'books_historical'; END IF;
  
  SELECT setting_value INTO v_cash_acct_name FROM settings 
    WHERE agency_id = p_agency_id AND setting_key = 'gl_default_cash_account_name';
  IF v_cash_acct_name IS NULL THEN v_cash_acct_name := 'US Bank - Income'; END IF;
  
  SELECT setting_value INTO v_sf_parent_name FROM settings 
    WHERE agency_id = p_agency_id AND setting_key = 'gl_default_sf_revenue_account_name';
  IF v_sf_parent_name IS NULL THEN v_sf_parent_name := '4005 State Farm'; END IF;
  
  -- Resolve cash account
  SELECT id INTO v_cash_acct_id FROM chart_of_accounts
    WHERE agency_id = p_agency_id AND chart_namespace = v_chart_namespace
      AND account_name = v_cash_acct_name LIMIT 1;
  
  IF v_cash_acct_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'cash_account_not_found',
      'searched_for', v_cash_acct_name);
  END IF;
  
  -- Resolve SF parent
  SELECT id INTO v_sf_parent_id FROM chart_of_accounts
    WHERE agency_id = p_agency_id AND chart_namespace = v_chart_namespace
      AND account_name = v_sf_parent_name AND parent_account_id IS NULL LIMIT 1;
  
  IF v_sf_parent_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'sf_parent_not_found');
  END IF;
  
  -- Suspense
  SELECT id INTO v_suspense_id FROM chart_of_accounts
    WHERE agency_id = p_agency_id AND chart_namespace = v_chart_namespace
      AND account_code = 'COA-SUSP' LIMIT 1;
  
  IF v_suspense_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'suspense_account_not_found');
  END IF;
  
  -- Walk unposted comp_recap
  FOR v_id, v_period_year, v_period_month, v_period_day, v_comp_type, v_comp_category,
      v_amount, v_description, v_posted_at IN
    SELECT id, period_year, period_month, period_day, comp_type, comp_category,
           amount, description, posted_at
    FROM comp_recap
    WHERE agency_id = p_agency_id
      AND posted_at IS NULL
      AND amount IS NOT NULL AND amount != 0
      AND period_year IS NOT NULL AND period_month IS NOT NULL
    ORDER BY period_year, period_month, period_day NULLS LAST, id
    LIMIT 1000
  LOOP
    v_count_eligible := v_count_eligible + 1;
    v_target_account_id := NULL;
    v_target_account_name := NULL;
    v_classification_status := NULL;
    v_suspense_reason := NULL;
    
    -- Date: use period_day if present, else 1st of month
    v_entry_date := MAKE_DATE(v_period_year, v_period_month, COALESCE(v_period_day, 1));
    
    -- Cutover gate
    IF v_entry_date < v_cutover_date THEN
      IF NOT p_dry_run THEN
        UPDATE comp_recap
        SET posted_at = NOW(),
            notes = COALESCE(notes, '') || ' [pre-cutover archive - not posted to GL]'
        WHERE id = v_id;
      END IF;
      v_count_skipped_cutover := v_count_skipped_cutover + 1;
      CONTINUE;
    END IF;
    
    v_is_deduction := (v_comp_category IS NOT NULL AND v_comp_category LIKE 'deduction_%');
    
    -- ===== Resolve target account =====
    IF v_is_deduction THEN
      -- Deduction path: lookup comp_deduction_map
      SELECT coa.id, coa.account_name
        INTO v_target_account_id, v_target_account_name
      FROM comp_deduction_map m
      JOIN chart_of_accounts coa 
        ON coa.agency_id = m.agency_id
        AND coa.chart_namespace = v_chart_namespace
        AND coa.account_name = m.source_account_name
        AND coa.parent_account_id = (
          SELECT p.id FROM chart_of_accounts p 
          WHERE p.agency_id = m.agency_id 
            AND p.chart_namespace = v_chart_namespace 
            AND p.account_name = m.source_parent_account_name
            AND p.parent_account_id IS NULL
        )
      WHERE m.agency_id = p_agency_id 
        AND m.comp_category = v_comp_category 
        AND m.is_active = TRUE
        AND (m.description_pattern IS NULL 
             OR (v_description IS NOT NULL AND v_description ~* m.description_pattern))
      ORDER BY m.priority ASC, m.description_pattern NULLS LAST
      LIMIT 1;
    ELSE
      -- Revenue path: lookup comp_category_map under SF parent
      SELECT coa.id, coa.account_name
        INTO v_target_account_id, v_target_account_name
      FROM comp_category_map m
      JOIN chart_of_accounts coa 
        ON coa.agency_id = m.agency_id
        AND coa.chart_namespace = v_chart_namespace
        AND coa.account_name = m.source_account_name
        AND (
          -- if mapping points at the parent itself
          (coa.parent_account_id IS NULL AND coa.account_name = m.source_parent_account_name)
          OR 
          -- otherwise it's a sub-account
          coa.parent_account_id = v_sf_parent_id
        )
      WHERE m.agency_id = p_agency_id
        AND m.comp_category = v_comp_category
        AND m.is_active = TRUE
        AND (m.description_pattern IS NULL
             OR (v_description IS NOT NULL AND v_description ~* m.description_pattern))
      ORDER BY m.priority ASC, m.description_pattern NULLS LAST
      LIMIT 1;
    END IF;
    
    -- Suspense fallback
    IF v_target_account_id IS NULL THEN
      v_target_account_id := v_suspense_id;
      v_target_account_name := 'Suspense (split offset pending)';
      v_classification_status := 'pending_review';
      v_suspense_reason := CASE 
        WHEN v_is_deduction THEN 'deduction unresolved: ' || COALESCE(v_comp_category, 'null') || ' / ' || LEFT(COALESCE(v_description, ''), 50)
        ELSE 'revenue unresolved: ' || COALESCE(v_comp_category, 'null') || ' / ' || LEFT(COALESCE(v_description, ''), 50)
      END;
    ELSE
      v_classification_status := 'classified';
    END IF;
    
    -- ===== Post JE =====
    DECLARE
      v_dr_account_id uuid;
      v_cr_account_id uuid;
      v_je_desc text;
      v_abs_amount numeric := abs(v_amount);
    BEGIN
      IF v_is_deduction THEN
        -- Deduction: DR expense, CR cash (deduction reduces cash inflow)
        v_dr_account_id := v_target_account_id;
        v_cr_account_id := v_cash_acct_id;
      ELSE
        -- Revenue: DR cash, CR revenue (positive amount = inflow)
        IF v_amount > 0 THEN
          v_dr_account_id := v_cash_acct_id;
          v_cr_account_id := v_target_account_id;
        ELSE
          -- Negative revenue (chargeback?) → reverse
          v_dr_account_id := v_target_account_id;
          v_cr_account_id := v_cash_acct_id;
        END IF;
      END IF;
      
      v_je_desc := COALESCE(v_description, COALESCE(v_comp_type, '') || ' ' || COALESCE(v_comp_category, ''));
      
      IF p_dry_run THEN
        v_posted_runs := v_posted_runs || jsonb_build_object(
          'comp_recap_id', v_id,
          'entry_date', v_entry_date,
          'comp_category', v_comp_category,
          'amount', v_amount,
          'is_deduction', v_is_deduction,
          'description', LEFT(v_description, 60),
          'dr_account', v_target_account_name,
          'cr_account', CASE WHEN v_is_deduction THEN v_cash_acct_name 
                             WHEN v_amount > 0 THEN v_target_account_name 
                             ELSE v_cash_acct_name END,
          'classification_status', v_classification_status,
          'suspense_reason', v_suspense_reason
        );
        IF v_classification_status = 'pending_review' THEN
          v_count_posted_susp := v_count_posted_susp + 1;
        ELSIF v_is_deduction THEN
          v_count_posted_ded := v_count_posted_ded + 1;
          v_total_deductions := v_total_deductions + v_abs_amount;
        ELSE
          v_count_posted_rev := v_count_posted_rev + 1;
          v_total_revenue := v_total_revenue + v_abs_amount;
        END IF;
        CONTINUE;
      END IF;
      
      -- Insert JE
      INSERT INTO journal_entries (
        agency_id, entry_date, entry_type, source, description,
        reference_number, classification_status, suspense_reason,
        classified_by, classified_at, created_by, created_at
      ) VALUES (
        p_agency_id, v_entry_date,
        CASE WHEN v_is_deduction THEN 'comp_deduction' ELSE 'comp_revenue' END,
        'gl_entry_writer', v_je_desc,
        'comp_recap:' || v_id::text,
        v_classification_status, v_suspense_reason,
        CASE WHEN v_classification_status = 'classified' THEN 'comp_map' ELSE NULL END,
        CASE WHEN v_classification_status = 'classified' THEN NOW() ELSE NULL END,
        'gl_entry_writer', NOW()
      ) RETURNING id INTO v_je_id;
      
      INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, created_at)
      VALUES (v_je_id, p_agency_id, v_dr_account_id, v_abs_amount, 0, LEFT(v_je_desc, 200), NOW());
      
      INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, created_at)
      VALUES (v_je_id, p_agency_id, v_cr_account_id, 0, v_abs_amount, LEFT(v_je_desc, 200), NOW());
      
      UPDATE comp_recap 
      SET posted_at = NOW(),
          notes = COALESCE(notes, '') || ' [posted by gl_entry_writer ' || NOW()::text || 
                  CASE WHEN v_classification_status = 'pending_review' 
                       THEN '; suspense: ' || COALESCE(v_suspense_reason, '') ELSE '' END || ']'
      WHERE id = v_id;
      
      IF v_classification_status = 'pending_review' THEN
        v_count_posted_susp := v_count_posted_susp + 1;
      ELSIF v_is_deduction THEN
        v_count_posted_ded := v_count_posted_ded + 1;
        v_total_deductions := v_total_deductions + v_abs_amount;
      ELSE
        v_count_posted_rev := v_count_posted_rev + 1;
        v_total_revenue := v_total_revenue + v_abs_amount;
      END IF;
    END;
  END LOOP;
  
  RETURN jsonb_build_object(
    'ok', TRUE,
    'dry_run', p_dry_run,
    'cutover_date', v_cutover_date,
    'eligible', v_count_eligible,
    'skipped_pre_cutover', v_count_skipped_cutover,
    'posted_revenue', v_count_posted_rev,
    'posted_deduction', v_count_posted_ded,
    'posted_suspense', v_count_posted_susp,
    'errors', v_count_errored,
    'total_revenue', v_total_revenue,
    'total_deductions', v_total_deductions,
    'net_cash_impact', v_total_revenue - v_total_deductions,
    'posted_runs', v_posted_runs,
    'error_details', v_errors
  );
END;
$$;

-- Runner-compat overload
CREATE OR REPLACE FUNCTION public.gl_entry_writer(
  p_agency_id uuid,
  p_recipe_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public.gl_entry_writer(p_agency_id, FALSE);
END;
$$;

COMMENT ON FUNCTION public.gl_entry_writer(uuid, boolean) IS
'V2: Uses comp_category_map (revenue) and comp_deduction_map (deductions) for legacy-source chart resolution.
Splits comp_recap by comp_category prefix: deduction_* → expense, else → revenue.
Pre-cutover archive-only. Suspense fallback for unmapped categories.';
