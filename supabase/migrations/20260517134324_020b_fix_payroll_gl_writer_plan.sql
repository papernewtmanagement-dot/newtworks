DROP FUNCTION IF EXISTS public.payroll_gl_writer(uuid, boolean);

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
  
  v_run_id uuid;
  v_pay_date date;
  v_pay_period_start date;
  v_pay_period_end date;
  v_gross_payroll numeric;
  v_employer_taxes numeric;
  v_payroll_provider text;
  v_posted_at timestamptz;
  v_existing_je_id uuid;
  
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
  IF v_cutover_date IS NULL THEN v_cutover_date := '2026-05-01'::date; END IF;
  
  SELECT setting_value INTO v_chart_namespace
    FROM settings WHERE agency_id = p_agency_id AND setting_key = 'gl_chart_namespace';
  IF v_chart_namespace IS NULL THEN v_chart_namespace := 'books_historical'; END IF;
  
  SELECT setting_value INTO v_payroll_expense_account_name
    FROM settings WHERE agency_id = p_agency_id AND setting_key = 'gl_payroll_expense_account_name';
  IF v_payroll_expense_account_name IS NULL THEN v_payroll_expense_account_name := 'Payroll Costs'; END IF;
  
  SELECT setting_value INTO v_intercompany_account_name
    FROM settings WHERE agency_id = p_agency_id AND setting_key = 'gl_intercompany_paypernewt_account_name';
  IF v_intercompany_account_name IS NULL THEN v_intercompany_account_name := 'Due to PaperNewt LLC (intercompany)'; END IF;
  
  -- Resolve intercompany account
  SELECT id INTO v_intercompany_account_id
    FROM chart_of_accounts
    WHERE agency_id = p_agency_id
      AND chart_namespace = v_chart_namespace
      AND account_name = v_intercompany_account_name
      AND parent_account_id IS NULL
    LIMIT 1;
  
  IF v_intercompany_account_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'intercompany_account_not_found',
      'searched_for', v_intercompany_account_name, 'namespace', v_chart_namespace);
  END IF;
  
  -- Resolve TEAM parent
  SELECT id INTO v_team_parent_id
    FROM chart_of_accounts
    WHERE agency_id = p_agency_id
      AND chart_namespace = v_chart_namespace
      AND account_name LIKE '0002 TEAM%'
      AND parent_account_id IS NULL
    LIMIT 1;
  
  IF v_team_parent_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'team_parent_not_found');
  END IF;
  
  -- Resolve Payroll Costs sub-account
  SELECT id INTO v_payroll_expense_account_id
    FROM chart_of_accounts
    WHERE agency_id = p_agency_id
      AND chart_namespace = v_chart_namespace
      AND parent_account_id = v_team_parent_id
      AND account_name = v_payroll_expense_account_name
    LIMIT 1;
  
  IF v_payroll_expense_account_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'payroll_expense_account_not_found',
      'searched_for', v_payroll_expense_account_name);
  END IF;
  
  -- Walk payroll_runs using explicit FOR loop with scalar variables
  FOR v_run_id, v_pay_date, v_pay_period_start, v_pay_period_end,
      v_gross_payroll, v_employer_taxes, v_payroll_provider, v_posted_at, v_existing_je_id IN
    SELECT id, pay_date, pay_period_start, pay_period_end, 
           gross_payroll, employer_taxes, payroll_provider, posted_at, journal_entry_id
    FROM payroll_runs 
    WHERE agency_id = p_agency_id
    ORDER BY pay_date
  LOOP
    v_count_eligible := v_count_eligible + 1;
    
    -- Cutover gate
    IF v_pay_date < v_cutover_date THEN
      v_count_skipped_cutover := v_count_skipped_cutover + 1;
      IF NOT p_dry_run AND v_posted_at IS NULL THEN
        UPDATE payroll_runs
        SET posted_at = NOW(),
            notes = COALESCE(notes, '') || ' [pre-cutover; no JE posted per accounting_rules]'
        WHERE id = v_run_id;
      END IF;
      CONTINUE;
    END IF;
    
    -- Already posted
    IF v_posted_at IS NOT NULL AND v_existing_je_id IS NOT NULL THEN
      v_count_skipped_already_posted := v_count_skipped_already_posted + 1;
      CONTINUE;
    END IF;
    
    v_dr_amount := COALESCE(v_gross_payroll, 0) + COALESCE(v_employer_taxes, 0);
    v_cr_amount := v_dr_amount;
    v_description := 'Payroll run ' || v_pay_period_start || ' to ' || v_pay_period_end || 
                     ' (check ' || v_pay_date || ') — ' || COALESCE(v_payroll_provider, 'Payroll');
    
    IF v_dr_amount <= 0 THEN
      v_count_errored := v_count_errored + 1;
      v_errors := v_errors || jsonb_build_object('run_id', v_run_id, 'reason', 'zero_or_negative_amount');
      CONTINUE;
    END IF;
    
    IF p_dry_run THEN
      v_posted_runs := v_posted_runs || jsonb_build_object(
        'run_id', v_run_id,
        'pay_date', v_pay_date,
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
      p_agency_id, v_pay_date, v_description,
      'payroll_gl_writer', 'PAYROLL-' || v_run_id::text,
      'classified', NOW()
    ) RETURNING id INTO v_je_id;
    
    INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description)
    VALUES (v_je_id, p_agency_id, v_payroll_expense_account_id, v_dr_amount, 0,
            'Gross payroll $' || v_gross_payroll::text || ' + ER taxes $' || v_employer_taxes::text);
    
    INSERT INTO journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description)
    VALUES (v_je_id, p_agency_id, v_intercompany_account_id, 0, v_cr_amount,
            'Owed to PaperNewt LLC for ' || v_pay_period_start || ' to ' || v_pay_period_end);
    
    UPDATE payroll_runs
    SET posted_at = NOW(),
        journal_entry_id = v_je_id,
        notes = COALESCE(notes, '') || ' [posted by payroll_gl_writer ' || NOW()::text || ']'
    WHERE id = v_run_id;
    
    v_count_posted := v_count_posted + 1;
    v_total_expense := v_total_expense + v_dr_amount;
    v_posted_runs := v_posted_runs || jsonb_build_object(
      'run_id', v_run_id, 'pay_date', v_pay_date,
      'je_id', v_je_id, 'dr', v_dr_amount, 'cr', v_cr_amount
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
