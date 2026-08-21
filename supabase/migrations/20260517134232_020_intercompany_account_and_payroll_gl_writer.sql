-- =============================================================================
-- MIGRATION 020: Intercompany account + payroll_gl_writer
-- =============================================================================

-- Part 1: Create "Due to PaperNewt LLC (intercompany)" liability account
-- Uses chart_namespace=books_historical to live alongside existing 33 parent accounts.
-- Type=liability (the agency owes PaperNewt for payroll cash advances).

INSERT INTO chart_of_accounts (
  agency_id, chart_namespace, account_code, account_name,
  account_type, parent_account_id, is_active, is_system, account_subtype
)
SELECT
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  'books_historical',
  'COA-IC-001',
  'Due to PaperNewt LLC (intercompany)',
  'liability',
  NULL,
  TRUE,
  TRUE,
  'intercompany_payable; created session 14 for payroll_gl_writer; two-entity convention per accounting_rules'
WHERE NOT EXISTS (
  SELECT 1 FROM chart_of_accounts 
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND chart_namespace = 'books_historical'
    AND account_name = 'Due to PaperNewt LLC (intercompany)'
);

-- Part 2: Record setting key for lookup
INSERT INTO settings (agency_id, setting_key, setting_value, setting_type, description)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  'gl_intercompany_paypernewt_account_name',
  'Due to PaperNewt LLC (intercompany)',
  'text',
  'books_historical-namespace account that payroll_gl_writer credits (offsetting the DR payroll expense). Two-entity convention per accounting_rules.'
)
ON CONFLICT (agency_id, setting_key) DO UPDATE 
SET setting_value = EXCLUDED.setting_value,
    description = EXCLUDED.description;

-- Part 3: Record setting for payroll expense account name
INSERT INTO settings (agency_id, setting_key, setting_value, setting_type, description)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  'gl_payroll_expense_account_name',
  'Payroll Costs',
  'text',
  'books_historical-namespace sub-account under 0002 TEAM that payroll_gl_writer debits for gross + employer taxes.'
)
ON CONFLICT (agency_id, setting_key) DO UPDATE
SET setting_value = EXCLUDED.setting_value,
    description = EXCLUDED.description;

-- Part 4: Add posting tracking columns to payroll_runs
ALTER TABLE payroll_runs ADD COLUMN IF NOT EXISTS posted_at timestamptz;
ALTER TABLE payroll_runs ADD COLUMN IF NOT EXISTS journal_entry_id uuid REFERENCES journal_entries(id);
ALTER TABLE payroll_runs ADD COLUMN IF NOT EXISTS notes text;

-- =============================================================================
-- Part 5: payroll_gl_writer function
-- =============================================================================

CREATE OR REPLACE FUNCTION public.payroll_gl_writer(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_dry_run boolean DEFAULT FALSE
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cutover_date date;
  v_chart_namespace text;
  v_payroll_expense_account_name text;
  v_intercompany_account_name text;
  
  v_payroll_expense_account_id uuid;
  v_intercompany_account_id uuid;
  v_team_parent_id uuid;
  
  v_run record;
  v_je_id uuid;
  
  v_count_eligible int := 0;
  v_count_skipped_cutover int := 0;
  v_count_skipped_already_posted int := 0;
  v_count_posted int := 0;
  v_count_errored int := 0;
  
  v_total_expense numeric := 0;
  v_errors jsonb := '[]'::jsonb;
  v_posted_runs jsonb := '[]'::jsonb;
  v_dr_amount numeric;
  v_cr_amount numeric;
  v_description text;
BEGIN
  -- Load settings
  SELECT setting_value::date INTO v_cutover_date
    FROM settings WHERE agency_id = p_agency_id AND setting_key = 'gl_cutover_date';
  IF v_cutover_date IS NULL THEN
    v_cutover_date := '2026-05-01'::date;
  END IF;
  
  SELECT setting_value INTO v_chart_namespace
    FROM settings WHERE agency_id = p_agency_id AND setting_key = 'gl_chart_namespace';
  IF v_chart_namespace IS NULL THEN
    v_chart_namespace := 'books_historical';
  END IF;
  
  SELECT setting_value INTO v_payroll_expense_account_name
    FROM settings WHERE agency_id = p_agency_id AND setting_key = 'gl_payroll_expense_account_name';
  IF v_payroll_expense_account_name IS NULL THEN
    v_payroll_expense_account_name := 'Payroll Costs';
  END IF;
  
  SELECT setting_value INTO v_intercompany_account_name
    FROM settings WHERE agency_id = p_agency_id AND setting_key = 'gl_intercompany_paypernewt_account_name';
  IF v_intercompany_account_name IS NULL THEN
    v_intercompany_account_name := 'Due to PaperNewt LLC (intercompany)';
  END IF;
  
  -- Resolve account ids (relational, by name + namespace)
  -- Intercompany: top-level liability account
  SELECT id INTO v_intercompany_account_id
    FROM chart_of_accounts
    WHERE agency_id = p_agency_id
      AND chart_namespace = v_chart_namespace
      AND account_name = v_intercompany_account_name
      AND parent_account_id IS NULL
    LIMIT 1;
  
  IF v_intercompany_account_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', FALSE,
      'error', 'intercompany_account_not_found',
      'searched_for', v_intercompany_account_name,
      'namespace', v_chart_namespace
    );
  END IF;
  
  -- Find 0002 TEAM parent so we can locate Payroll Costs sub-account relationally
  SELECT id INTO v_team_parent_id
    FROM chart_of_accounts
    WHERE agency_id = p_agency_id
      AND chart_namespace = v_chart_namespace
      AND account_name LIKE '0002 TEAM%'
      AND parent_account_id IS NULL
    LIMIT 1;
  
  IF v_team_parent_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', FALSE,
      'error', 'team_parent_not_found',
      'searched_for', '0002 TEAM%',
      'namespace', v_chart_namespace
    );
  END IF;
  
  -- Resolve Payroll Costs sub-account under TEAM parent
  SELECT id INTO v_payroll_expense_account_id
    FROM chart_of_accounts
    WHERE agency_id = p_agency_id
      AND chart_namespace = v_chart_namespace
      AND parent_account_id = v_team_parent_id
      AND account_name = v_payroll_expense_account_name
    LIMIT 1;
  
  IF v_payroll_expense_account_id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', FALSE,
      'error', 'payroll_expense_account_not_found',
      'searched_for', v_payroll_expense_account_name,
      'under_parent', '0002 TEAM%'
    );
  END IF;
  
  -- Walk payroll_runs
  FOR v_run IN 
    SELECT id, pay_date, pay_period_start, pay_period_end, 
           gross_payroll, employer_taxes, net_payroll, payroll_provider, posted_at
    FROM payroll_runs 
    WHERE agency_id = p_agency_id
    ORDER BY pay_date
  LOOP
    v_count_eligible := v_count_eligible + 1;
    
    -- Cutover gate
    IF v_run.pay_date < v_cutover_date THEN
      v_count_skipped_cutover := v_count_skipped_cutover + 1;
      -- Mark as posted-skipped pre-cutover (detail-only archive)
      IF NOT p_dry_run AND v_run.posted_at IS NULL THEN
        UPDATE payroll_runs
        SET posted_at = NOW(),
            notes = COALESCE(notes, '') || ' [pre-cutover; no JE posted per accounting_rules]'
        WHERE id = v_run.id;
      END IF;
      CONTINUE;
    END IF;
    
    -- Already posted gate
    IF v_run.posted_at IS NOT NULL AND v_run.journal_entry_id IS NOT NULL THEN
      v_count_skipped_already_posted := v_count_skipped_already_posted + 1;
      CONTINUE;
    END IF;
    
    -- Build the JE
    v_dr_amount := COALESCE(v_run.gross_payroll, 0) + COALESCE(v_run.employer_taxes, 0);
    v_cr_amount := v_dr_amount;
    v_description := 'Payroll run ' || v_run.pay_period_start || ' to ' || v_run.pay_period_end || 
                     ' (check ' || v_run.pay_date || ') — ' || COALESCE(v_run.payroll_provider, 'Payroll');
    
    IF v_dr_amount <= 0 THEN
      v_count_errored := v_count_errored + 1;
      v_errors := v_errors || jsonb_build_object(
        'run_id', v_run.id,
        'pay_date', v_run.pay_date,
        'reason', 'zero_or_negative_amount',
        'gross', v_run.gross_payroll,
        'er_tax', v_run.employer_taxes
      );
      CONTINUE;
    END IF;
    
    IF p_dry_run THEN
      v_posted_runs := v_posted_runs || jsonb_build_object(
        'run_id', v_run.id,
        'pay_date', v_run.pay_date,
        'dr_payroll_expense', v_dr_amount,
        'cr_intercompany', v_cr_amount,
        'description', v_description
      );
      v_count_posted := v_count_posted + 1;
      v_total_expense := v_total_expense + v_dr_amount;
      CONTINUE;
    END IF;
    
    -- Insert JE
    INSERT INTO journal_entries (
      agency_id, entry_date, description, source, reference_number,
      classification_status, created_at
    ) VALUES (
      p_agency_id,
      v_run.pay_date,
      v_description,
      'payroll_gl_writer',
      'PAYROLL-' || v_run.id::text,
      'classified',
      NOW()
    ) RETURNING id INTO v_je_id;
    
    -- DR: Payroll Costs (gross + er taxes combined)
    INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description)
    VALUES (v_je_id, p_agency_id, v_payroll_expense_account_id, v_dr_amount, 0,
            'Gross payroll $' || v_run.gross_payroll::text || ' + ER taxes $' || v_run.employer_taxes::text);
    
    -- CR: Due to PaperNewt LLC
    INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description)
    VALUES (v_je_id, p_agency_id, v_intercompany_account_id, 0, v_cr_amount,
            'Owed to PaperNewt LLC for ' || v_run.pay_period_start || ' to ' || v_run.pay_period_end || ' payroll run');
    
    -- Mark posted
    UPDATE payroll_runs
    SET posted_at = NOW(),
        journal_entry_id = v_je_id,
        notes = COALESCE(notes, '') || ' [posted by payroll_gl_writer ' || NOW()::text || ']'
    WHERE id = v_run.id;
    
    v_count_posted := v_count_posted + 1;
    v_total_expense := v_total_expense + v_dr_amount;
    v_posted_runs := v_posted_runs || jsonb_build_object(
      'run_id', v_run.id,
      'pay_date', v_run.pay_date,
      'je_id', v_je_id,
      'dr_payroll_expense', v_dr_amount,
      'cr_intercompany', v_cr_amount
    );
  END LOOP;
  
  RETURN jsonb_build_object(
    'ok', TRUE,
    'dry_run', p_dry_run,
    'cutover_date', v_cutover_date,
    'eligible', v_count_eligible,
    'skipped_pre_cutover', v_count_skipped_cutover,
    'skipped_already_posted', v_count_skipped_already_posted,
    'posted', v_count_posted,
    'errors', v_count_errored,
    'total_payroll_expense_posted', v_total_expense,
    'posted_runs', v_posted_runs,
    'error_details', v_errors,
    'accounts_used', jsonb_build_object(
      'dr_expense', v_payroll_expense_account_name,
      'cr_intercompany', v_intercompany_account_name
    )
  );
END;
$$;

COMMENT ON FUNCTION public.payroll_gl_writer(uuid, boolean) IS
'Posts post-cutover payroll_runs to journal_entries with two-entity convention:
 DR 0002 TEAM > Payroll Costs (gross + employer taxes)
 CR Due to PaperNewt LLC (intercompany)
Pre-cutover runs (< gl_cutover_date) are marked posted_at without JE generation (detail-only archive).
Already-posted runs are skipped (idempotent).
Pass p_dry_run=TRUE to preview without writing.';

SELECT 'migration 020 applied' as status;
