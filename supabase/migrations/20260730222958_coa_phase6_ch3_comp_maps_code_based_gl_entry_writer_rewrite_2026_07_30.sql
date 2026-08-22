-- Phase 6 Chunk 3 — code-based routing for gl_entry_writer

ALTER TABLE public.comp_category_map
  ADD COLUMN IF NOT EXISTS source_account_code text,
  ADD COLUMN IF NOT EXISTS source_business_entity_id uuid REFERENCES public.business_entities(id);

ALTER TABLE public.comp_deduction_map
  ADD COLUMN IF NOT EXISTS source_account_code text,
  ADD COLUMN IF NOT EXISTS source_business_entity_id uuid REFERENCES public.business_entities(id);

-- Backfill comp_category_map — 25 active rows

UPDATE public.comp_category_map SET source_account_code='4200', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='d97d6155-85c2-46fe-a8bd-4c7f57797c28';
UPDATE public.comp_category_map SET source_account_code='4200', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='3163a34b-4a79-4044-90af-58c98e0eddaa';
UPDATE public.comp_category_map SET source_account_code='4131', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='6885eaa4-7b15-4ca2-9a4d-cb387508afe2';
UPDATE public.comp_category_map SET source_account_code='4131', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='ac3e10ba-9ef8-4256-86f1-e1b29eda386c';
UPDATE public.comp_category_map SET source_account_code='4021', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='d2a28088-8148-4782-b535-5d8d44952534';
UPDATE public.comp_category_map SET source_account_code='4022', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='da28e801-7ddd-4cc7-99c9-188a5029e5a2';
UPDATE public.comp_category_map SET source_account_code='4023', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='95ff4109-2da2-4b84-b08a-ef587964d22a';
UPDATE public.comp_category_map SET source_account_code='4021', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='c8ab87b0-7804-41bc-9d77-c6cb0b6a1484';
UPDATE public.comp_category_map SET source_account_code='4020', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='6b01e8f5-a959-4b08-b45b-dd368fa5d4cc';
UPDATE public.comp_category_map SET source_account_code='4021', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='7343f16f-be06-40f3-b2d2-1107c028a119';
UPDATE public.comp_category_map SET source_account_code='4100', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='60760af8-415d-44dd-80a6-579982c03132';
UPDATE public.comp_category_map SET source_account_code='4101', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='16564427-5639-48a7-bd45-5d479c5e8d2b';
UPDATE public.comp_category_map SET source_account_code='4100', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='f10061e5-f2ad-44d1-9d9f-0c36c5d646c0';
UPDATE public.comp_category_map SET source_account_code='4101', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='738bcabf-21dd-45b9-9bce-701869ff25cf';
UPDATE public.comp_category_map SET source_account_code='4110', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='91479f9a-8159-42ee-af66-5a69b42cfade';
UPDATE public.comp_category_map SET source_account_code='4111', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='c22ed070-4b75-41e9-995e-b3e1cdbcceb1';
UPDATE public.comp_category_map SET source_account_code='4120', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='9f9ebba4-379c-46d7-be04-d9afc8cfdf7f';
UPDATE public.comp_category_map SET source_account_code='4121', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='127cb6ef-d875-4e8c-8abe-43e6db1e7dab';
UPDATE public.comp_category_map SET source_account_code='4100', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='62df6f24-4b8a-4c7d-9ff3-b84308f05673';
UPDATE public.comp_category_map SET source_account_code='4101', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='ba1aebee-5483-4a12-a321-787932df73ba';
UPDATE public.comp_category_map SET source_account_code='4100', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='1c8a3a6b-c240-4de7-be96-dde87679625f';
UPDATE public.comp_category_map SET source_account_code='4100', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='8c1d2d04-141c-4b35-bcd5-6107fb52a630';
UPDATE public.comp_category_map SET source_account_code='4140', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='78031f57-d034-463b-a736-c20b859dbdb8';
UPDATE public.comp_category_map SET source_account_code='4140', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='451a9a1e-6133-4272-9a4c-8dee792740c4';
UPDATE public.comp_category_map SET source_account_code='4140', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='a1c95649-abde-458e-86bc-ab68a9fafc32';

-- Backfill comp_deduction_map — 12 active rows

UPDATE public.comp_deduction_map SET source_account_code='6400', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='b253abef-f228-4209-a2cc-94702d065106';
UPDATE public.comp_deduction_map SET source_account_code='6400', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='e46874ee-127b-402b-b7ca-3b055c2950ff';
UPDATE public.comp_deduction_map SET source_account_code='6110', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='1570124c-a29d-4ee7-8b9f-4c01608ceaf7';
UPDATE public.comp_deduction_map SET source_account_code='6710', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='e779aaa2-3448-4266-aea4-df18bdc10e49';
UPDATE public.comp_deduction_map SET source_account_code='6710', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='e3d832c6-24fc-49b1-a93c-226963a6e569';
UPDATE public.comp_deduction_map SET source_account_code='6950', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='6cf980b2-7583-41ec-832c-998e446c905f';
UPDATE public.comp_deduction_map SET source_account_code='6750', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='ca6af81d-4336-43e9-8264-b9adc93655d8';
UPDATE public.comp_deduction_map SET source_account_code='6910', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='1d42e573-0fd2-42f3-9f5f-7525b5ecd7c6';
UPDATE public.comp_deduction_map SET source_account_code='6210', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='20b95d95-742d-4198-aa38-a6640ecd66ef';
UPDATE public.comp_deduction_map SET source_account_code='6470', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='7001e1d8-69a4-4163-b65d-f869a0a80ecd';
UPDATE public.comp_deduction_map SET source_account_code='6330', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='db7a3d11-0925-4402-b02c-e2df6aab734a';
UPDATE public.comp_deduction_map SET source_account_code='6720', source_business_entity_id='b2222222-2222-2222-2222-222222222222'
WHERE id='d7ac7af8-70c2-41d9-9af9-ed0bbac54628';

-- Rewrite gl_entry_writer

CREATE OR REPLACE FUNCTION public.gl_entry_writer(p_agency_id uuid, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cash_acct_name text;
  v_cash_acct_id uuid;
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
  SELECT setting_value INTO v_cash_acct_name FROM settings
    WHERE agency_id = p_agency_id AND setting_key = 'gl_default_cash_account_name';
  IF v_cash_acct_name IS NULL THEN v_cash_acct_name := 'US Bank - Income'; END IF;

  SELECT id INTO v_cash_acct_id FROM chart_of_accounts
    WHERE agency_id = p_agency_id AND account_name = v_cash_acct_name LIMIT 1;
  IF v_cash_acct_id IS NULL THEN
    RETURN jsonb_build_object('ok', FALSE, 'error', 'cash_account_not_found');
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
