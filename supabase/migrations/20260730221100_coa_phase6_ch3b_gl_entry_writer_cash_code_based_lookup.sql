-- Phase 6 Chunk 3b — fix cash-account lookup in gl_entry_writer
--
-- Existing setting `gl_default_cash_account_name` = 'US Bank - Income' but Phase 5b renamed the
-- COA to 'PSS — US Bank Income'. Name-based lookup returns null → cash_account_not_found error.
-- Nothing hit today because no unposted comp_recap items, but blocks all future posting.
--
-- Fix: replace name-based setting with code-based. Cash account is account_code=1012 in PSS entity.
-- Codes don't change during renames.

DELETE FROM public.settings
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND setting_key='gl_default_cash_account_name';

INSERT INTO public.settings (agency_id, setting_key, setting_value)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'gl_default_cash_account_code', '1012')
ON CONFLICT (agency_id, setting_key) DO UPDATE SET setting_value = EXCLUDED.setting_value;

-- Rewrite gl_entry_writer with code-based cash lookup
CREATE OR REPLACE FUNCTION public.gl_entry_writer(p_agency_id uuid, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cash_acct_code text;
  v_cash_acct_id uuid;
  v_cash_acct_name text;
  v_catchall_inc_id uuid; v_catchall_ded_id uuid;
  v_id uuid; v_period_year int; v_period_month int; v_period_day int;
  v_comp_type text; v_comp_category text; v_amount numeric; v_description text;
  v_entry_date date; v_is_deduction boolean;
  v_target_account_id uuid; v_target_account_name text;
  v_classification_status text; v_suspense_reason text; v_je_id uuid;
  v_count_eligible int := 0; v_count_posted_rev int := 0;
  v_count_posted_ded int := 0; v_count_posted_susp int := 0;
  v_count_errored int := 0;
  v_total_revenue numeric := 0; v_total_deductions numeric := 0;
  v_errors jsonb := '[]'::jsonb;
BEGIN
  -- Cash account: prefer code-based lookup (rename-resilient)
  SELECT setting_value INTO v_cash_acct_code FROM settings
    WHERE agency_id = p_agency_id AND setting_key = 'gl_default_cash_account_code';
  IF v_cash_acct_code IS NULL THEN v_cash_acct_code := '1012'; END IF;

  SELECT id, account_name INTO v_cash_acct_id, v_cash_acct_name FROM chart_of_accounts
    WHERE agency_id = p_agency_id
      AND business_entity_id = 'b2222222-2222-2222-2222-222222222222'
      AND account_code = v_cash_acct_code
      AND is_active = TRUE LIMIT 1;
  IF v_cash_acct_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'cash_account_not_found', 'cash_code_tried', v_cash_acct_code);
  END IF;

  SELECT id INTO v_catchall_inc_id FROM chart_of_accounts
    WHERE agency_id = p_agency_id AND account_code = 'COA-UNCL-PSS-INC' LIMIT 1;
  IF v_catchall_inc_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'catchall_income_account_not_found');
  END IF;

  SELECT id INTO v_catchall_ded_id FROM chart_of_accounts
    WHERE agency_id = p_agency_id AND account_code = 'COA-UNCL-PSS' LIMIT 1;
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
        ON coa.agency_id = m.agency_id
       AND coa.business_entity_id = m.source_business_entity_id
       AND coa.account_code = m.source_account_code
       AND coa.is_active = TRUE
      WHERE m.agency_id = p_agency_id
        AND m.comp_category = v_comp_category
        AND m.is_active = TRUE
        AND m.source_account_code IS NOT NULL
        AND m.source_business_entity_id IS NOT NULL
        AND (m.description_pattern IS NULL
             OR (v_description IS NOT NULL AND v_description ~* m.description_pattern))
      ORDER BY m.priority ASC, m.description_pattern NULLS LAST LIMIT 1;
    ELSE
      SELECT coa.id, coa.account_name INTO v_target_account_id, v_target_account_name
      FROM comp_category_map m
      JOIN chart_of_accounts coa
        ON coa.agency_id = m.agency_id
       AND coa.business_entity_id = m.source_business_entity_id
       AND coa.account_code = m.source_account_code
       AND coa.is_active = TRUE
      WHERE m.agency_id = p_agency_id
        AND m.comp_category = v_comp_category
        AND m.is_active = TRUE
        AND m.source_account_code IS NOT NULL
        AND m.source_business_entity_id IS NOT NULL
        AND (m.description_pattern IS NULL
             OR (v_description IS NOT NULL AND v_description ~* m.description_pattern))
      ORDER BY m.priority ASC, m.description_pattern NULLS LAST LIMIT 1;
    END IF;

    IF v_target_account_id IS NULL THEN
      IF v_is_deduction THEN
        v_target_account_id := v_catchall_ded_id;
        v_target_account_name := '*Unclassified';
      ELSE
        v_target_account_id := v_catchall_inc_id;
        v_target_account_name := '*Unclassified';
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
      v_dr_name text; v_cr_name text; v_je_desc text;
      v_abs_amount numeric := abs(v_amount);
    BEGIN
      IF v_is_deduction THEN
        v_dr_account_id := v_target_account_id; v_cr_account_id := v_cash_acct_id;
        v_dr_name := v_target_account_name; v_cr_name := v_cash_acct_name;
      ELSE
        IF v_amount > 0 THEN
          v_dr_account_id := v_cash_acct_id; v_cr_account_id := v_target_account_id;
          v_dr_name := v_cash_acct_name; v_cr_name := v_target_account_name;
        ELSE
          v_dr_account_id := v_target_account_id; v_cr_account_id := v_cash_acct_id;
          v_dr_name := v_target_account_name; v_cr_name := v_cash_acct_name;
        END IF;
      END IF;

      v_je_desc := COALESCE(v_description, COALESCE(v_comp_type, '') || ' ' || COALESCE(v_comp_category, ''));

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

      INSERT INTO journal_entries (
        agency_id, entry_date, entry_type, source, description,
        reference_number, classification_status, suspense_reason,
        classified_by, classified_at, created_by, created_at
      ) VALUES (
        p_agency_id, v_entry_date,
        CASE WHEN v_is_deduction THEN 'comp_deduction' ELSE 'comp_revenue' END,
        'gl_entry_writer', v_je_desc, 'comp_recap:' || v_id::text,
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
      SET posted_at = NOW(), journal_entry_id = v_je_id,
          notes = COALESCE(notes, '') || ' [posted by gl_entry_writer ' || NOW()::text || ']'
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
