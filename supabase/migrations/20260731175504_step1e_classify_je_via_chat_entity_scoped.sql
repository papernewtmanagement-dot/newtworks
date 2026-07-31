-- =========================================================================
-- Migration: step1e_classify_je_via_chat_entity_scoped
-- Applied: 2026-07-31 via Supabase MCP (session: pipeline_repair_step1)
-- =========================================================================
-- Rewrite classify_je_via_chat so __SOURCE__ resolves from the JE's other
-- line (not reference-number parsing), and target lookups prefer same-entity
-- copies. Removes fallback to non-existent COA-007.
-- =========================================================================

-- Fix: derive '__SOURCE__' resolution from the JE's other line (not by parsing
-- reference_number), and prefer same-entity lookups on the target code.
CREATE OR REPLACE FUNCTION public.classify_je_via_chat(
  p_agency_id uuid, p_je_id uuid, p_debit_code text, p_credit_code text,
  p_classified_by text, p_create_rule boolean DEFAULT false,
  p_rule_name text DEFAULT NULL::text, p_rule_priority integer DEFAULT 100,
  p_rule_payee_regex text DEFAULT NULL::text, p_rule_memo_regex text DEFAULT NULL::text,
  p_rule_direction text DEFAULT NULL::text, p_rule_sub_label text DEFAULT NULL::text,
  p_rule_confidence text DEFAULT NULL::text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_je              record;
  v_debit_id        uuid;
  v_credit_id       uuid;
  v_debit_amount    numeric;
  v_credit_amount   numeric;
  v_debit_line_id   uuid;
  v_credit_line_id  uuid;
  v_rule_id         uuid := NULL;
  v_closed_tasks    int := 0;
  v_resolved_code   text;
  v_source_acct     text;
  v_source_entity_id uuid;
  v_placeholder_line_id uuid;
  v_other_account_id uuid;
BEGIN
  SELECT je.id, je.classification_status, je.entry_date, je.description, je.memo,
         je.source, je.document_id, je.reference_number
    INTO v_je
  FROM journal_entries je
  WHERE je.agency_id = p_agency_id AND je.id = p_je_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'je_not_found', 'je_id', p_je_id);
  END IF;

  IF v_je.classification_status <> 'pending_review' THEN
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'already_classified',
      'je_id', p_je_id, 'current_status', v_je.classification_status
    );
  END IF;

  -- Locate the placeholder (unclassified) line and the OTHER (real) line.
  -- __SOURCE__ resolves to the real line's account_code, and entity comes from there too.
  SELECT jl.id, jl.debit, jl.credit
    INTO v_placeholder_line_id, v_debit_amount, v_credit_amount
  FROM journal_lines jl
  JOIN chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.journal_entry_id = p_je_id
    AND (coa.account_name LIKE '*Unclassified%' OR coa.account_subtype = 'suspense'
         OR coa.account_code IN ('0001','0002','0003','0004','0005'))
  ORDER BY jl.id LIMIT 1;

  SELECT jl.account_id, coa.account_code, coa.business_entity_id
    INTO v_other_account_id, v_source_acct, v_source_entity_id
  FROM journal_lines jl
  JOIN chart_of_accounts coa ON coa.id = jl.account_id
  WHERE jl.journal_entry_id = p_je_id
    AND (v_placeholder_line_id IS NULL OR jl.id != v_placeholder_line_id)
  ORDER BY jl.id LIMIT 1;

  IF v_source_acct IS NULL THEN v_source_acct := ''; END IF;

  -- Resolve debit target
  v_resolved_code := CASE WHEN p_debit_code = '__SOURCE__' THEN v_source_acct ELSE p_debit_code END;
  SELECT id INTO v_debit_id FROM chart_of_accounts
   WHERE agency_id = p_agency_id AND account_code = v_resolved_code AND is_active = TRUE
     AND (business_entity_id = v_source_entity_id OR business_entity_id IS NULL)
   ORDER BY (business_entity_id = v_source_entity_id) DESC NULLS LAST
   LIMIT 1;
  IF v_debit_id IS NULL THEN
    SELECT id INTO v_debit_id FROM chart_of_accounts
      WHERE agency_id = p_agency_id AND account_code = v_resolved_code AND is_active = TRUE
      LIMIT 1;
  END IF;
  IF v_debit_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'debit_account_not_found', 'code', v_resolved_code);
  END IF;

  -- Resolve credit target
  v_resolved_code := CASE WHEN p_credit_code = '__SOURCE__' THEN v_source_acct ELSE p_credit_code END;
  SELECT id INTO v_credit_id FROM chart_of_accounts
   WHERE agency_id = p_agency_id AND account_code = v_resolved_code AND is_active = TRUE
     AND (business_entity_id = v_source_entity_id OR business_entity_id IS NULL)
   ORDER BY (business_entity_id = v_source_entity_id) DESC NULLS LAST
   LIMIT 1;
  IF v_credit_id IS NULL THEN
    SELECT id INTO v_credit_id FROM chart_of_accounts
      WHERE agency_id = p_agency_id AND account_code = v_resolved_code AND is_active = TRUE
      LIMIT 1;
  END IF;
  IF v_credit_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'credit_account_not_found', 'code', v_resolved_code);
  END IF;

  SELECT id, debit INTO v_debit_line_id, v_debit_amount
  FROM journal_lines
  WHERE journal_entry_id = p_je_id AND debit > 0
  ORDER BY id LIMIT 1;

  SELECT id, credit INTO v_credit_line_id, v_credit_amount
  FROM journal_lines
  WHERE journal_entry_id = p_je_id AND credit > 0
  ORDER BY id LIMIT 1;

  IF v_debit_line_id IS NULL OR v_credit_line_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'journal_lines_malformed', 'je_id', p_je_id);
  END IF;

  UPDATE journal_lines SET account_id = v_debit_id  WHERE id = v_debit_line_id;
  UPDATE journal_lines SET account_id = v_credit_id WHERE id = v_credit_line_id;

  UPDATE journal_entries
     SET classification_status = 'classified',
         suspense_reason       = NULL,
         classified_by         = p_classified_by,
         classified_at         = NOW()
   WHERE id = p_je_id;

  IF p_create_rule AND p_rule_name IS NOT NULL THEN
    INSERT INTO gl_classification_rules (
      agency_id, rule_name, match_priority,
      match_payee_regex, match_memo_regex, match_direction,
      debit_account_code, credit_account_code,
      sub_category_label, confidence, is_active,
      source, created_at
    )
    VALUES (
      p_agency_id, p_rule_name, p_rule_priority,
      p_rule_payee_regex, p_rule_memo_regex, COALESCE(p_rule_direction, 'both'),
      p_debit_code, p_credit_code,
      p_rule_sub_label, COALESCE(p_rule_confidence, 'high'), true,
      'classify_je_via_chat:' || p_classified_by, NOW()
    )
    RETURNING id INTO v_rule_id;

    UPDATE journal_entries SET rule_id_used = v_rule_id WHERE id = p_je_id;
  END IF;

  UPDATE tasks
     SET status        = 'completed',
         completed_at  = NOW(),
         updated_at    = NOW()
   WHERE agency_id    = p_agency_id
     AND related_id   = p_je_id
     AND status = 'open';
  GET DIAGNOSTICS v_closed_tasks = ROW_COUNT;

  RETURN jsonb_build_object(
    'ok', true,
    'je_id', p_je_id,
    'debit_account_code', p_debit_code,
    'credit_account_code', p_credit_code,
    'amount', GREATEST(COALESCE(v_debit_amount, 0), COALESCE(v_credit_amount, 0)),
    'rule_created', v_rule_id IS NOT NULL,
    'rule_id', v_rule_id,
    'tasks_closed', v_closed_tasks,
    'classified_by', p_classified_by,
    'classified_at', NOW()
  );
END;
$function$;
