-- Step 1f of pipeline repair (2026-07-31): rewrite reclassify_pending_je so
-- the placeholder-line lookup matches the real entity-scoped unclassified
-- account names (*Unclassified Income/Expense — Business/Personal), and target
-- account lookup prefers same-entity copies. Removes obsolete COA-SUSP filter.

CREATE OR REPLACE FUNCTION public.reclassify_pending_je(
  p_agency_id uuid,
  p_source_account_code text DEFAULT NULL::text,
  p_je_id uuid DEFAULT NULL::uuid,
  p_dry_run boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_je RECORD; v_placeholder_line RECORD; v_other_line RECORD;
  v_source_account_code text; v_source_account_type text; v_source_entity_id uuid;
  v_amount numeric; v_direction text; v_rule_id uuid; v_target_code text;
  v_new_account_id uuid; v_je_description text;
  v_count_reclassified int := 0; v_count_still_pending int := 0;
  v_count_error int := 0; v_count_scanned int := 0;
BEGIN
  FOR v_je IN
    SELECT je.id, je.entry_date, je.description FROM public.journal_entries je
    WHERE je.agency_id = p_agency_id AND je.classification_status = 'pending_review'
      AND (p_je_id IS NULL OR je.id = p_je_id)
    ORDER BY je.entry_date, je.id
  LOOP
    v_count_scanned := v_count_scanned + 1;

    SELECT jl.id AS line_id, jl.debit, jl.credit, jl.account_id, coa.account_type AS placeholder_type
    INTO v_placeholder_line
    FROM public.journal_lines jl
    JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
    WHERE jl.journal_entry_id = v_je.id
      AND coa.agency_id = p_agency_id
      AND (coa.account_name LIKE '*Unclassified%'
           OR coa.account_subtype = 'suspense'
           OR coa.account_code IN ('0001','0002','0003','0004','0005'))
    LIMIT 1;

    IF NOT FOUND THEN
      v_count_still_pending := v_count_still_pending + 1; CONTINUE;
    END IF;

    SELECT jl.account_id, coa.account_code, coa.account_type, coa.business_entity_id
      INTO v_other_line
    FROM public.journal_lines jl
    JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
    WHERE jl.journal_entry_id = v_je.id AND jl.id != v_placeholder_line.line_id
    LIMIT 1;

    IF NOT FOUND THEN
      v_count_still_pending := v_count_still_pending + 1; CONTINUE;
    END IF;

    IF p_source_account_code IS NOT NULL AND v_other_line.account_code != p_source_account_code THEN
      v_count_scanned := v_count_scanned - 1; CONTINUE;
    END IF;

    v_source_account_code := v_other_line.account_code;
    v_source_account_type := v_other_line.account_type;
    v_source_entity_id := v_other_line.business_entity_id;

    IF v_placeholder_line.debit > 0 THEN
      v_amount := v_placeholder_line.debit; v_direction := 'debit';
    ELSE
      v_amount := v_placeholder_line.credit; v_direction := 'credit';
    END IF;

    v_je_description := v_je.description; v_rule_id := NULL; v_target_code := NULL;

    SELECT r.id,
      CASE WHEN v_direction = 'credit' THEN r.credit_account_code ELSE r.debit_account_code END
    INTO v_rule_id, v_target_code
    FROM public.gl_classification_rules r
    LEFT JOIN public.chart_of_accounts target_coa
      ON target_coa.agency_id = p_agency_id
     AND target_coa.account_code =
         (CASE WHEN v_direction = 'credit' THEN r.credit_account_code ELSE r.debit_account_code END)
     AND (target_coa.business_entity_id = v_source_entity_id OR target_coa.business_entity_id IS NULL)
    WHERE r.agency_id = p_agency_id AND r.is_active = TRUE
      AND (r.match_payee_regex IS NOT NULL OR r.match_memo_regex IS NOT NULL
           OR r.match_source_account IS NOT NULL)
      AND (r.match_payee_regex IS NULL OR v_je_description ~* r.match_payee_regex)
      AND (r.match_memo_regex IS NULL OR v_je_description ~* r.match_memo_regex)
      AND (r.match_source_account IS NULL OR r.match_source_account = v_source_account_code)
      AND (r.match_amount_min IS NULL OR abs(v_amount) >= r.match_amount_min)
      AND (r.match_amount_max IS NULL OR abs(v_amount) <= r.match_amount_max)
      AND (r.match_direction IS NULL OR r.match_direction = v_direction OR r.match_direction = 'both')
      AND (CASE WHEN v_direction = 'credit' THEN r.credit_account_code ELSE r.debit_account_code END)
          IS NOT NULL
      AND (CASE WHEN v_direction = 'credit' THEN r.credit_account_code ELSE r.debit_account_code END)
          NOT IN ('__SOURCE__')
      AND (v_source_account_type != 'liability' OR target_coa.account_type != 'income')
    ORDER BY r.match_priority ASC NULLS LAST LIMIT 1;

    IF v_rule_id IS NULL OR v_target_code IS NULL THEN
      v_count_still_pending := v_count_still_pending + 1; CONTINUE;
    END IF;

    SELECT id INTO v_new_account_id FROM public.chart_of_accounts
      WHERE agency_id = p_agency_id AND account_code = v_target_code AND is_active = TRUE
        AND (business_entity_id = v_source_entity_id OR business_entity_id IS NULL)
      ORDER BY (business_entity_id = v_source_entity_id) DESC NULLS LAST
      LIMIT 1;
    IF v_new_account_id IS NULL THEN
      SELECT id INTO v_new_account_id FROM public.chart_of_accounts
        WHERE agency_id = p_agency_id AND account_code = v_target_code AND is_active = TRUE
        LIMIT 1;
    END IF;
    IF v_new_account_id IS NULL THEN
      v_count_error := v_count_error + 1; CONTINUE;
    END IF;

    IF NOT p_dry_run THEN
      UPDATE public.journal_lines SET account_id = v_new_account_id
      WHERE id = v_placeholder_line.line_id;

      UPDATE public.journal_entries
      SET classification_status = 'classified', suspense_reason = NULL, rule_id_used = v_rule_id,
          classified_by = 'reclassify_pending_je', classified_at = NOW()
      WHERE id = v_je.id;

      UPDATE public.gl_classification_rules
      SET historical_uses = COALESCE(historical_uses, 0) + 1, last_used_at = NOW()
      WHERE id = v_rule_id;
    END IF;

    v_count_reclassified := v_count_reclassified + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', TRUE, 'dry_run', p_dry_run,
    'source_account_code_filter', p_source_account_code,
    'scanned', v_count_scanned, 'reclassified', v_count_reclassified,
    'still_pending', v_count_still_pending, 'errors', v_count_error
  );
END;
$function$;
