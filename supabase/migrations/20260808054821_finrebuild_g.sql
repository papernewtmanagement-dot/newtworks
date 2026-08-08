CREATE OR REPLACE FUNCTION public.comp_gl_writer(p_agency_id uuid, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_pss_entity uuid := 'b2222222-2222-2222-2222-222222222222'::uuid;
  v_id uuid; v_period_year int; v_period_month int; v_period_day int;
  v_comp_type text; v_comp_category text; v_amount numeric; v_description text;
  v_entry_date date; v_is_deduction boolean;
  v_map_source_account_code text; v_map_source_business_entity_id uuid;
  v_target_account_id uuid;
  v_classification_status text; v_suspense_reason text;
  v_count_eligible int := 0; v_count_posted_rev int := 0;
  v_count_posted_ded int := 0; v_count_posted_susp int := 0;
  v_count_errored int := 0; v_count_skipped_no_pl int := 0;
  v_total_revenue numeric := 0; v_total_deductions numeric := 0;
  v_errors jsonb := '[]'::jsonb;
BEGIN
  FOR v_id, v_period_year, v_period_month, v_period_day, v_comp_type, v_comp_category,
      v_amount, v_description IN
    SELECT id, period_year, period_month, period_day, comp_type, comp_category, amount, description
    FROM comp_recap
    WHERE agency_id = p_agency_id AND posted_at IS NULL
      AND amount IS NOT NULL AND amount != 0
      AND period_year IS NOT NULL AND period_month IS NOT NULL
      AND period_year >= 2026
    ORDER BY period_year, period_month, period_day NULLS LAST, id LIMIT 5000
  LOOP
    v_count_eligible := v_count_eligible + 1;
    v_target_account_id := NULL;
    v_classification_status := NULL; v_suspense_reason := NULL;
    v_map_source_account_code := NULL; v_map_source_business_entity_id := NULL;
    v_entry_date := MAKE_DATE(v_period_year, v_period_month, COALESCE(v_period_day, 1));

    v_is_deduction := (v_comp_category IS NOT NULL AND v_comp_category LIKE 'deduction_%');

    -- Phase 4b-iii: resolve source_account_code / source_business_entity_id only, no chart_of_accounts join
    IF v_is_deduction THEN
      SELECT m.source_account_code, m.source_business_entity_id
      INTO v_map_source_account_code, v_map_source_business_entity_id
      FROM comp_deduction_map m
      WHERE m.agency_id = p_agency_id AND m.comp_category = v_comp_category AND m.is_active = TRUE
        AND m.source_account_code IS NOT NULL AND m.source_business_entity_id IS NOT NULL
        AND (m.description_pattern IS NULL OR (v_description IS NOT NULL AND v_description ~* m.description_pattern))
      ORDER BY m.priority ASC, m.description_pattern NULLS LAST LIMIT 1;
    ELSE
      SELECT m.source_account_code, m.source_business_entity_id
      INTO v_map_source_account_code, v_map_source_business_entity_id
      FROM comp_category_map m
      WHERE m.agency_id = p_agency_id AND m.comp_category = v_comp_category AND m.is_active = TRUE
        AND m.source_account_code IS NOT NULL AND m.source_business_entity_id IS NOT NULL
        AND (m.description_pattern IS NULL OR (v_description IS NOT NULL AND v_description ~* m.description_pattern))
      ORDER BY m.priority ASC, m.description_pattern NULLS LAST LIMIT 1;
    END IF;

    IF v_map_source_account_code = '__SKIP__' THEN
      v_count_skipped_no_pl := v_count_skipped_no_pl + 1;
      IF NOT p_dry_run THEN
        UPDATE comp_recap SET posted_at = NOW() WHERE id = v_id;
      END IF;
      CONTINUE;
    END IF;

    IF v_map_source_account_code IS NOT NULL AND v_map_source_business_entity_id IS NOT NULL THEN
      SELECT id INTO v_target_account_id FROM chart_of_accounts
      WHERE agency_id = p_agency_id AND business_entity_id = v_map_source_business_entity_id
        AND account_code = v_map_source_account_code AND is_active = TRUE
      LIMIT 1;
    END IF;

    IF v_target_account_id IS NULL THEN
      -- Phase 4b-v: unresolved fallback via get_entity_unclassified_account
      v_target_account_id := get_entity_unclassified_account(
        p_agency_id, v_pss_entity,
        CASE WHEN v_is_deduction THEN 'expense' ELSE 'income' END
      );
      v_classification_status := 'unclassified';
      v_suspense_reason := CASE
        WHEN v_is_deduction THEN 'deduction unresolved: ' || COALESCE(v_comp_category, 'null') || ' / ' || LEFT(COALESCE(v_description, ''), 50)
        ELSE 'revenue unresolved: ' || COALESCE(v_comp_category, 'null') || ' / ' || LEFT(COALESCE(v_description, ''), 50)
      END;
    ELSE
      v_classification_status := 'classified';
    END IF;

    DECLARE
      v_je_desc text;
      v_abs_amount numeric := abs(v_amount);
      v_ref text;
      v_debit numeric; v_credit numeric;
    BEGIN
      IF v_target_account_id IS NULL THEN
        v_count_errored := v_count_errored + 1;
        v_errors := v_errors || jsonb_build_object('comp_recap_id', v_id, 'error', 'no_target_account_resolved');
        CONTINUE;
      END IF;

      -- Phase 4b-iv: single-line posting
      IF v_is_deduction THEN
        IF v_amount > 0 THEN v_debit := v_abs_amount; v_credit := 0;
        ELSE v_debit := 0; v_credit := v_abs_amount;
        END IF;
      ELSE
        IF v_amount > 0 THEN v_debit := 0; v_credit := v_abs_amount;
        ELSE v_debit := v_abs_amount; v_credit := 0;
        END IF;
      END IF;

      v_je_desc := COALESCE(v_description, COALESCE(v_comp_type, '') || ' ' || COALESCE(v_comp_category, ''));
      v_ref := 'comp_recap:' || v_id::text;

      IF p_dry_run THEN
        IF v_classification_status = 'unclassified' THEN v_count_posted_susp := v_count_posted_susp + 1;
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
        p_agency_id, v_entry_date, v_target_account_id, v_debit, v_credit, LEFT(v_je_desc, 200),
        'comp_gl_writer', v_ref, v_id, v_classification_status,
        CASE WHEN v_classification_status = 'classified' THEN 'comp_map' ELSE NULL END,
        CASE WHEN v_classification_status = 'classified' THEN NOW() ELSE NULL END,
        CASE WHEN v_is_deduction THEN 'comp_deduction' ELSE 'comp_revenue' END
      );

      UPDATE comp_recap
      SET posted_at = NOW(),
          notes = COALESCE(notes, '') || ' [posted by comp_gl_writer ' || NOW()::text || ']'
      WHERE id = v_id;

      IF v_classification_status = 'unclassified' THEN v_count_posted_susp := v_count_posted_susp + 1;
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
    'skipped_no_pl_effect', v_count_skipped_no_pl,
    'errors', v_count_errored, 'error_details', v_errors,
    'total_revenue', v_total_revenue,
    'total_deductions', v_total_deductions,
    'net_cash_impact', v_total_revenue - v_total_deductions
  );
END;
$function$;