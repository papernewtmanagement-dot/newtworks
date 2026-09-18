-- Recategorizing a transaction on the P&L now teaches the classification rules.
-- gl_pattern_from_description turns a raw bank/card description into a reusable
-- match pattern by stripping the parts that change every time (reference ids,
-- store numbers, digit runs).

CREATE OR REPLACE FUNCTION public.gl_pattern_from_description(p_description text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v text;
  v_tokens text[];
  v_keep text[] := ARRAY[]::text[];
  t text;
BEGIN
  IF p_description IS NULL OR length(trim(p_description)) = 0 THEN
    RETURN NULL;
  END IF;

  v := upper(trim(p_description));

  -- channel prefixes that vary between statements for the same merchant
  v := regexp_replace(v, '^(POS |PURCHASE |DEBIT CARD |CHECKCARD |RECURRING PAYMENT |RECURRING |SQ \*|TST\* |PP\*|PAYPAL \*|WWW\.)', '', 'g');
  -- store numbers and reference ids
  v := regexp_replace(v, '#\s*[0-9]+', ' ', 'g');
  -- any token containing a digit (order numbers, dates, auth codes)
  v := regexp_replace(v, '\m[A-Z0-9]*[0-9][A-Z0-9]*\M', ' ', 'g');
  -- anything that is not a letter, ampersand, hyphen or space
  v := regexp_replace(v, '[^A-Z&\- ]', ' ', 'g');
  v := regexp_replace(v, '\s+', ' ', 'g');
  v := trim(v);

  IF length(v) = 0 THEN
    RETURN NULL;
  END IF;

  v_tokens := string_to_array(v, ' ');
  FOREACH t IN ARRAY v_tokens LOOP
    IF length(t) >= 2 THEN
      v_keep := v_keep || t;
    END IF;
    EXIT WHEN COALESCE(array_length(v_keep, 1), 0) >= 3;
  END LOOP;

  IF COALESCE(array_length(v_keep, 1), 0) = 0 THEN
    RETURN NULL;
  END IF;

  -- hyphens are literal inside the pattern, escape them
  RETURN '(?i)' || replace(array_to_string(v_keep, '\s+'), '-', '\-');
END;
$$;

COMMENT ON FUNCTION public.gl_pattern_from_description(text) IS
  'Turns a raw statement description into a reusable merchant match pattern for gl_classification_rules. Strips digits, store numbers and channel prefixes, then keeps the first three words of two letters or more.';


-- learn_gl_rule_from_ledger: called after Peter changes the account on a P&L
-- transaction. Amends the rule that already covers that merchant if one exists,
-- otherwise writes a new one, so the next matching transaction lands in the
-- right place without him touching it.

CREATE OR REPLACE FUNCTION public.learn_gl_rule_from_ledger(
  p_ledger_id uuid,
  p_actor text DEFAULT 'pnl_reclassify'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_agency uuid; v_desc text; v_account_id uuid;
  v_debit numeric; v_credit numeric;
  v_statement_id uuid; v_register_id uuid;
  v_code text; v_entity uuid; v_type text; v_acct_name text;
  v_src_code text; v_direction text; v_pattern text;
  v_existing uuid; v_rule_id uuid; v_action text; v_rule_name text;
BEGIN
  SELECT l.agency_id, l.description, l.account_id,
         COALESCE(l.debit, 0), COALESCE(l.credit, 0),
         l.statement_id, l.cash_register_id
    INTO v_agency, v_desc, v_account_id, v_debit, v_credit, v_statement_id, v_register_id
  FROM ledger l
  WHERE l.id = p_ledger_id;

  IF v_agency IS NULL THEN
    RETURN jsonb_build_object('learned', false, 'reason', 'ledger_row_not_found');
  END IF;

  SELECT coa.account_code, coa.business_entity_id, coa.account_type, coa.account_name
    INTO v_code, v_entity, v_type, v_acct_name
  FROM chart_of_accounts coa
  WHERE coa.id = v_account_id;

  IF v_code IS NULL THEN
    RETURN jsonb_build_object('learned', false, 'reason', 'account_not_found');
  END IF;

  -- never teach a rule that points at the holding bucket
  IF v_code IN ('0002', '0003', '0004') OR v_acct_name ILIKE '*Unclassified%' THEN
    RETURN jsonb_build_object('learned', false, 'reason', 'target_is_unclassified');
  END IF;

  v_pattern := gl_pattern_from_description(v_desc);
  IF v_pattern IS NULL THEN
    RETURN jsonb_build_object('learned', false, 'reason', 'description_too_generic');
  END IF;

  -- which card or bank account paid, so the rule can be scoped to it
  IF v_statement_id IS NOT NULL THEN
    SELECT coa2.account_code INTO v_src_code
    FROM statements s
    JOIN accounts a ON a.id = s.account_id
    JOIN chart_of_accounts coa2 ON coa2.id = a.chart_account_id
    WHERE s.id = v_statement_id;
  END IF;

  IF v_src_code IS NULL AND v_register_id IS NOT NULL THEN
    SELECT coa2.account_code INTO v_src_code
    FROM cash_register_preliminary c
    JOIN accounts a ON (a.account_number_last4 = c.account_last4
                     OR c.account_last4 = ANY(a.alternate_last4s))
    JOIN chart_of_accounts coa2 ON coa2.id = a.chart_account_id
    WHERE c.id = v_register_id
      AND a.is_active = TRUE
    LIMIT 1;
  END IF;

  v_direction := CASE WHEN v_debit > 0 THEN 'debit'
                      WHEN v_credit > 0 THEN 'credit'
                      ELSE 'both' END;

  -- amend an existing rule for the same merchant and same paying account
  SELECT r.id INTO v_existing
  FROM gl_classification_rules r
  WHERE r.agency_id = v_agency
    AND r.is_active = TRUE
    AND r.debit_account_code <> '__SKIP__'
    AND r.match_payee_regex IS NOT NULL
    AND v_desc ~* r.match_payee_regex
    AND r.match_source_account IS NOT DISTINCT FROM v_src_code
    AND (r.match_direction IS NULL OR r.match_direction IN (v_direction, 'both'))
    AND (r.match_amount_min IS NULL OR abs(GREATEST(v_debit, v_credit)) >= r.match_amount_min)
    AND (r.match_amount_max IS NULL OR abs(GREATEST(v_debit, v_credit)) <= r.match_amount_max)
  ORDER BY r.match_priority ASC NULLS LAST, r.historical_uses DESC NULLS LAST
  LIMIT 1;

  IF v_existing IS NOT NULL THEN
    UPDATE gl_classification_rules
       SET debit_account_code  = CASE WHEN v_direction = 'credit' THEN debit_account_code  ELSE v_code END,
           credit_account_code = CASE WHEN v_direction = 'credit' THEN v_code ELSE credit_account_code END,
           target_business_entity_id = v_entity,
           override_reason = 'Repointed from the P&L on '
                             || to_char(now() AT TIME ZONE 'America/Chicago', 'YYYY-MM-DD')
                             || ' by ' || p_actor || ' to ' || v_code || ' ' || v_acct_name,
           updated_at = now()
     WHERE id = v_existing
    RETURNING id INTO v_rule_id;
    v_action := 'updated';
  ELSE
    v_rule_name := 'From the P&L: ' || left(regexp_replace(coalesce(v_desc, ''), '\s+', ' ', 'g'), 60)
                   || ' -> ' || v_code || ' ' || v_acct_name;

    INSERT INTO gl_classification_rules (
      agency_id, rule_name, match_priority,
      match_payee_regex, match_source_account, match_direction,
      debit_account_code, credit_account_code,
      target_business_entity_id, confidence, source, rule_scope, is_active
    ) VALUES (
      v_agency, v_rule_name, 55,
      v_pattern, v_src_code, v_direction,
      CASE WHEN v_direction = 'credit' THEN '__SOURCE__' ELSE v_code END,
      CASE WHEN v_direction = 'credit' THEN v_code ELSE '__SOURCE__' END,
      v_entity, 'high', p_actor, 'both', TRUE
    )
    RETURNING id INTO v_rule_id;
    v_action := 'created';
  END IF;

  RETURN jsonb_build_object(
    'learned', true,
    'action', v_action,
    'rule_id', v_rule_id,
    'pattern', v_pattern,
    'paid_from_account', v_src_code,
    'account_code', v_code,
    'account_name', v_acct_name
  );
END;
$$;

COMMENT ON FUNCTION public.learn_gl_rule_from_ledger(uuid, text) IS
  'Writes Peter''s P&L recategorization back into gl_classification_rules so the next transaction from the same merchant on the same card classifies itself. Amends the existing rule when one already covers that merchant, otherwise creates one at priority 55.';

GRANT EXECUTE ON FUNCTION public.gl_pattern_from_description(text) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.learn_gl_rule_from_ledger(uuid, text) TO authenticated, anon;
