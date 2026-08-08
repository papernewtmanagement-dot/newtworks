-- finrebuild_f4_comp_gl_writer
-- Phase 3.2: rename gl_entry_writer to comp_gl_writer, repoint from
-- journal_entries/journal_lines to ledger with comp_recap_id set,
-- source 'comp_gl_writer'. Category mapping logic (comp_category_map /
-- comp_deduction_map) unchanged. Clearing-account double-entry design
-- preserved (comp_recap is not a "statement transaction" under D3 — D3's
-- single-line rule is scoped to statements only); now writes two ledger
-- rows sharing comp_recap_id and reference_number instead of a
-- journal_entries header + two journal_lines.
CREATE OR REPLACE FUNCTION public.comp_gl_writer(p_agency_id uuid, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_clearing_acct_code text;
  v_clearing_acct_id uuid;
  v_catchall_inc_id uuid; v_catchall_ded_id uuid;
  v_pss_entity uuid := 'b2222222-2222-2222-2222-222222222222'::uuid;
  v_id uuid; v_period_year int; v_period_month int; v_period_day int;
  v_comp_type text; v_comp_category text; v_amount numeric; v_description text;
  v_entry_date date; v_is_deduction boolean;
  v_target_account_id uuid; v_target_account_name text;
  v_classification_status text; v_suspense_reason text;
  v_count_eligible int := 0; v_count_posted_rev int := 0;
  v_count_posted_ded int := 0; v_count_posted_susp int := 0;
  v_count_errored int := 0;
  v_total_revenue numeric := 0; v_total_deductions numeric := 0;
  v_errors jsonb := '[]'::jsonb;
BEGIN
  SELECT setting_value INTO v_clearing_acct_code FROM settings
    WHERE agency_id = p_agency_id AND setting_key = 'gl_comp_clearing_account_code';
  IF v_clearing_acct_code IS NULL THEN v_clearing_acct_code := '0005'; END IF;

  SELECT id INTO v_clearing_acct_id FROM chart_of_accounts
    WHERE agency_id = p_agency_id AND business_entity_id = v_pss_entity
      AND account_code = v_clearing_acct_code AND is_active = TRUE LIMIT 1;
  IF v_clearing_acct_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'clearing_account_not_found', 'clearing_code_tried', v_clearing_acct_code);
  END IF;

  SELECT id INTO v_catchall_inc_id FROM chart_of_accounts
    WHERE agency_id = p_agency_id AND business_entity_id = v_pss_entity
      AND account_code = '0002' AND account_type = 'income' AND is_active = TRUE LIMIT 1;
  IF v_catchall_inc_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'catchall_income_account_not_found');
  END IF;

  SELECT id INTO v_catchall_ded_id FROM chart_of_accounts
    WHERE agency_id = p_agency_id AND business_entity_id = v_pss_entity
      AND account_code = '0003' AND account_type = 'expense' AND is_active = TRUE LIMIT 1;
  IF v_catchall_ded_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'catchall_deduction_account_not_found');
  END IF;

  FOR v_id, v_period_year, v_period_month, v_period_day, v_comp_type, v_comp_category,
      v_amount, v_description IN
    SELECT id, period_year, period_month, period_day, comp_type, comp_category, amount, description
    FROM comp_recap
    WHERE agency_id = p_agency_id AND posted_at IS NULL
      AND amount IS NOT NULL AND amount != 0
      AND period_year IS NOT NULL AND period_month IS NOT NULL
    ORDER BY period_year, period_month, period_day NULLS LAST, id LIMIT 1000
  LOOP
    v_count_eligible := v_count_eligible + 1;
    v_target_account_id := NULL; v_target_account_name := NULL;
    v_classification_status := NULL; v_suspense_reason := NULL;
    v_entry_date := MAKE_DATE(v_period_year, v_period_month, COALESCE(v_period_day, 1));

    v_is_deduction := (v_comp_category IS NOT NULL AND v_comp_category LIKE 'deduction_%');

    IF v_is_deduction THEN
      SELECT coa.id, coa.account_name INTO v_target_account_id, v_target_account_name
      FROM comp_deduction_map m
      JOIN chart_of_accounts coa
        ON coa.agency_id = m.agency_id AND coa.business_entity_id = m.source_business_entity_id
       AND coa.account_code = m.source_account_code AND coa.is_active = TRUE
      WHERE m.agency_id = p_agency_id AND m.comp_category = v_comp_category AND m.is_active = TRUE
        AND m.source_account_code IS NOT NULL AND m.source_business_entity_id IS NOT NULL
        AND (m.description_pattern IS NULL OR (v_description IS NOT NULL AND v_description ~* m.description_pattern))
      ORDER BY m.priority ASC, m.description_pattern NULLS LAST LIMIT 1;
    ELSE
      SELECT coa.id, coa.account_name INTO v_target_account_id, v_target_account_name
      FROM comp_category_map m
      JOIN chart_of_accounts coa
        ON coa.agency_id = m.agency_id AND coa.business_entity_id = m.source_business_entity_id
       AND coa.account_code = m.source_account_code AND coa.is_active = TRUE
      WHERE m.agency_id = p_agency_id AND m.comp_category = v_comp_category AND m.is_active = TRUE
        AND m.source_account_code IS NOT NULL AND m.source_business_entity_id IS NOT NULL
        AND (m.description_pattern IS NULL OR (v_description IS NOT NULL AND v_description ~* m.description_pattern))
      ORDER BY m.priority ASC, m.description_pattern NULLS LAST LIMIT 1;
    END IF;

    IF v_target_account_id IS NULL THEN
      IF v_is_deduction THEN
        v_target_account_id := v_catchall_ded_id;
        v_target_account_name := '*Unclassified Expense — Business';
      ELSE
        v_target_account_id := v_catchall_inc_id;
        v_target_account_name := '*Unclassified Income';
      END IF;
      v_classification_status := 'pending_review';
      v_suspense_reason := CASE
        WHEN v_is_deduction THEN 'deduction unresolved: ' || COALESCE(v_comp_category, 'null') || ' / ' || LEFT(COALESCE(v_description, ''), 50)
        ELSE 'revenue unresolved: ' || COALESCE(v_comp_category, 'null') || ' / ' || LEFT(COALESCE(v_description, ''), 50)
      END;
    ELSE
      v_classification_status := 'classified';
    END IF;

    DECLARE
      v_dr_account_id uuid; v_cr_account_id uuid;
      v_je_desc text;
      v_abs_amount numeric := abs(v_amount);
      v_ref text;
    BEGIN
      IF v_is_deduction THEN
        v_dr_account_id := v_target_account_id; v_cr_account_id := v_clearing_acct_id;
      ELSE
        IF v_amount > 0 THEN
          v_dr_account_id := v_clearing_acct_id; v_cr_account_id := v_target_account_id;
        ELSE
          v_dr_account_id := v_target_account_id; v_cr_account_id := v_clearing_acct_id;
        END IF;
      END IF;

      v_je_desc := COALESCE(v_description, COALESCE(v_comp_type, '') || ' ' || COALESCE(v_comp_category, ''));
      v_ref := 'comp_recap:' || v_id::text;

      IF p_dry_run THEN
        IF v_classification_status = 'pending_review' THEN v_count_posted_susp := v_count_posted_susp + 1;
        ELSIF v_is_deduction THEN
          v_count_posted_ded := v_count_posted_ded + 1;
          v_total_deductions := v_total_deductions + v_abs_amount;
        ELSE
          v_count_posted_rev := v_count_posted_rev + 1;
          v_total_revenue := v_total_revenue + v_abs_amount;
        END IF;
        CONTINUE;
      END IF;

      INSERT INTO ledger (
        agency_id, entry_date, account_id, debit, credit, description,
        source, reference_number, comp_recap_id, classification_status,
        classified_by, classified_at, entry_type
      ) VALUES (
        p_agency_id, v_entry_date, v_dr_account_id, v_abs_amount, 0, LEFT(v_je_desc, 200),
        'comp_gl_writer', v_ref, v_id, v_classification_status,
        CASE WHEN v_classification_status = 'classified' THEN 'comp_map' ELSE NULL END,
        CASE WHEN v_classification_status = 'classified' THEN NOW() ELSE NULL END,
        CASE WHEN v_is_deduction THEN 'comp_deduction' ELSE 'comp_revenue' END
      );
      INSERT INTO ledger (
        agency_id, entry_date, account_id, debit, credit, description,
        source, reference_number, comp_recap_id, classification_status,
        classified_by, classified_at, entry_type
      ) VALUES (
        p_agency_id, v_entry_date, v_cr_account_id, 0, v_abs_amount, LEFT(v_je_desc, 200),
        'comp_gl_writer', v_ref, v_id, v_classification_status,
        CASE WHEN v_classification_status = 'classified' THEN 'comp_map' ELSE NULL END,
        CASE WHEN v_classification_status = 'classified' THEN NOW() ELSE NULL END,
        CASE WHEN v_is_deduction THEN 'comp_deduction' ELSE 'comp_revenue' END
      );

      UPDATE comp_recap
      SET posted_at = NOW(),
          notes = COALESCE(notes, '') || ' [posted by comp_gl_writer ' || NOW()::text || ']'
      WHERE id = v_id;

      IF v_classification_status = 'pending_review' THEN v_count_posted_susp := v_count_posted_susp + 1;
      ELSIF v_is_deduction THEN
        v_count_posted_ded := v_count_posted_ded + 1;
        v_total_deductions := v_total_deductions + v_abs_amount;
      ELSE
        v_count_posted_rev := v_count_posted_rev + 1;
        v_total_revenue := v_total_revenue + v_abs_amount;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_count_errored := v_count_errored + 1;
      v_errors := v_errors || jsonb_build_object('comp_recap_id', v_id, 'error', SQLERRM, 'sqlstate', SQLSTATE);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', TRUE, 'dry_run', p_dry_run,
    'eligible', v_count_eligible,
    'posted_revenue', v_count_posted_rev,
    'posted_deduction', v_count_posted_ded,
    'posted_pending_review', v_count_posted_susp,
    'errors', v_count_errored, 'error_details', v_errors,
    'total_revenue', v_total_revenue,
    'total_deductions', v_total_deductions,
    'net_cash_impact', v_total_revenue - v_total_deductions
  );
END;
$function$;

-- 2-arg wrapper for run_internal_recipe's dynamic dispatch.
CREATE OR REPLACE FUNCTION public.comp_gl_writer(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN public.comp_gl_writer(p_agency_id, FALSE);
END;
$function$;