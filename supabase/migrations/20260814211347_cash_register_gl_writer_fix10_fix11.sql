CREATE OR REPLACE FUNCTION public.cash_register_gl_writer(
  p_agency_id uuid,
  p_dry_run boolean DEFAULT true,
  p_from date DEFAULT '2026-08-01'::date,
  p_settle_minutes int DEFAULT 90
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_reg_id uuid; v_txn_date date; v_direction text; v_amount numeric;
  v_account_last4 text; v_merchant text; v_account_label text; v_coding_status text;
  v_peter_debit text; v_peter_credit text; v_sugg_debit text; v_sugg_credit text;
  v_reg_entity_id uuid;
  v_account_id uuid; v_account_kind text; v_business_entity_id uuid; v_source_account_code text;
  v_code text; v_target_account_id uuid; v_target_account_type text;
  v_classification_status text; v_suspense_reason text; v_description text;
  v_count_seen int:=0; v_count_posted int:=0; v_count_suppressed int:=0;
  v_count_skipped_unresolved int:=0; v_count_skipped_already_posted int:=0;
  v_count_classified int:=0; v_count_unclassified int:=0;
  v_count_skipped_balance_sheet int:=0;
  v_count_skipped_rule_not_pnl int:=0;
  v_count_skipped_card_payment int:=0;
  v_total_classified numeric:=0; v_total_unclassified numeric:=0;
  v_errors jsonb := '[]'::jsonb;
  v_suppressed_ids uuid[];
  -- FIX 7 rule-matching state
  v_rule_id uuid; v_rule_debit_code text; v_rule_credit_code text; v_rule_target_entity uuid;
  v_rule_resolved_code text;
  -- FIX 10 card-payment guard state
  v_card_payment_match boolean;
  -- FIX 11 entity mismatch tracking
  v_entity_mismatches jsonb := '[]'::jsonb;
  v_count_entity_mismatch int := 0;
  v_reg_entity_name text; v_acct_entity_name text;
BEGIN
  -- D8: transfer detection over the eligible candidate set (gaps-and-islands by amount, chained ±1 day)
  WITH candidates AS (
    SELECT c.id, c.txn_date, c.amount, c.direction, c.account_last4
    FROM cash_register_preliminary c
    WHERE c.agency_id = p_agency_id
      AND c.txn_date >= p_from
      AND c.created_at < now() - (p_settle_minutes || ' minutes')::interval
      AND c.status IS DISTINCT FROM 'possible_transfer'
      AND NOT EXISTS (SELECT 1 FROM ledger l WHERE l.cash_register_id = c.id)
  ),
  ordered AS (
    SELECT *, txn_date - LAG(txn_date) OVER (PARTITION BY amount ORDER BY txn_date, id) AS gap
    FROM candidates
  ),
  grouped AS (
    SELECT *,
      SUM(CASE WHEN gap IS NULL OR gap > 1 THEN 1 ELSE 0 END)
        OVER (PARTITION BY amount ORDER BY txn_date, id) AS grp
    FROM ordered
  ),
  clusters AS (
    SELECT amount, grp,
      array_agg(id ORDER BY id) AS ids,
      array_agg(direction ORDER BY id) AS directions,
      array_agg(account_last4 ORDER BY id) AS last4s,
      count(*) AS n
    FROM grouped
    GROUP BY amount, grp
  )
  SELECT COALESCE(array_agg(cid), ARRAY[]::uuid[])
  INTO v_suppressed_ids
  FROM clusters, unnest(clusters.ids) AS cid
  WHERE (clusters.n = 2 AND clusters.directions[1] <> clusters.directions[2] AND clusters.last4s[1] <> clusters.last4s[2])
     OR clusters.n >= 3;

  IF NOT p_dry_run AND array_length(v_suppressed_ids,1) > 0 THEN
    UPDATE cash_register_preliminary
    SET status = 'possible_transfer',
        coding_question = 'Looks like a transfer between two of our own accounts — waiting for the statement to confirm.',
        updated_at = now()
    WHERE id = ANY(v_suppressed_ids);
  END IF;

  v_count_suppressed := COALESCE(array_length(v_suppressed_ids,1), 0);

  -- Posting pass over remaining eligible rows
  FOR v_reg_id, v_txn_date, v_direction, v_amount, v_account_last4, v_merchant,
      v_account_label, v_coding_status, v_peter_debit, v_peter_credit, v_sugg_debit, v_sugg_credit, v_reg_entity_id IN
    SELECT c.id, c.txn_date, c.direction, c.amount, c.account_last4, c.merchant,
           c.account_label, c.coding_status, c.peter_debit_account, c.peter_credit_account,
           c.suggested_debit_account, c.suggested_credit_account, c.business_entity_id
    FROM cash_register_preliminary c
    WHERE c.agency_id = p_agency_id
      AND c.txn_date >= p_from
      AND c.created_at < now() - (p_settle_minutes || ' minutes')::interval
      AND c.status IS DISTINCT FROM 'possible_transfer'
      AND NOT EXISTS (SELECT 1 FROM ledger l WHERE l.cash_register_id = c.id)
      AND NOT (v_suppressed_ids IS NOT NULL AND c.id = ANY(v_suppressed_ids))
    ORDER BY c.txn_date, c.id
  LOOP
    v_count_seen := v_count_seen + 1;
    v_target_account_id := NULL; v_target_account_type := NULL; v_classification_status := NULL;
    v_suspense_reason := NULL; v_account_id := NULL; v_account_kind := NULL; v_business_entity_id := NULL;
    v_code := NULL; v_description := NULL;
    v_source_account_code := NULL; v_rule_id := NULL; v_rule_debit_code := NULL; v_rule_credit_code := NULL;
    v_rule_target_entity := NULL; v_rule_resolved_code := NULL; v_card_payment_match := FALSE;

    IF v_amount <= 0 THEN
      v_count_skipped_unresolved := v_count_skipped_unresolved + 1;
      v_errors := v_errors || jsonb_build_object('cash_register_id', v_reg_id, 'reason', 'non_positive_amount: '||v_amount::text);
      CONTINUE;
    END IF;

    -- D4: resolve the register row's account (kind, entity, and chart-of-accounts code)
    SELECT a.id, a.business_entity_id, a.account_kind, coa.account_code
    INTO v_account_id, v_business_entity_id, v_account_kind, v_source_account_code
    FROM accounts a
    LEFT JOIN chart_of_accounts coa ON coa.id = a.chart_account_id
    WHERE a.agency_id = p_agency_id AND a.is_active = TRUE
      AND (a.account_number_last4 = v_account_last4 OR v_account_last4 = ANY(a.alternate_last4s))
    LIMIT 1;

    IF v_account_id IS NULL THEN
      v_count_skipped_unresolved := v_count_skipped_unresolved + 1;
      v_errors := v_errors || jsonb_build_object('cash_register_id', v_reg_id, 'reason', 'unresolved_last4: '||v_account_last4);
      CONTINUE;
    END IF;

    -- FIX 11: entity disagreement between the register row and its bank account.
    -- Still post using the account's entity (unchanged behavior) — just report it.
    IF v_reg_entity_id IS NOT NULL AND v_reg_entity_id IS DISTINCT FROM v_business_entity_id THEN
      v_count_entity_mismatch := v_count_entity_mismatch + 1;
      SELECT name INTO v_reg_entity_name FROM business_entities WHERE id = v_reg_entity_id;
      SELECT name INTO v_acct_entity_name FROM business_entities WHERE id = v_business_entity_id;
      v_entity_mismatches := v_entity_mismatches || jsonb_build_object(
        'cash_register_id', v_reg_id, 'date', v_txn_date, 'amount', v_amount,
        'register_entity', COALESCE(v_reg_entity_name, v_reg_entity_id::text),
        'account_entity', COALESCE(v_acct_entity_name, v_business_entity_id::text)
      );
    END IF;

    -- FIX 10: probable credit-card-payment guard. Runs before rule matching
    -- and before the unclassified fallback. Only for bank-account debits with
    -- no merchant, and only an exact-to-the-penny match against a recent
    -- credit card statement's closing balance.
    IF v_direction = 'debit' AND v_account_kind = 'bank'
       AND (v_merchant IS NULL OR length(trim(v_merchant)) = 0) THEN
      SELECT EXISTS (
        SELECT 1 FROM statement_balances sb
        WHERE sb.agency_id = p_agency_id
          AND sb.account_kind = 'credit'
          AND sb.closing_balance = v_amount
          AND sb.statement_period_end <= v_txn_date
          AND sb.statement_period_end >= v_txn_date - 45
      ) INTO v_card_payment_match;

      IF v_card_payment_match THEN
        v_count_skipped_card_payment := v_count_skipped_card_payment + 1;
        IF NOT p_dry_run THEN
          UPDATE cash_register_preliminary
          SET status = 'possible_transfer',
              coding_question = 'Looks like a payment to one of our credit cards — waiting for the statement to confirm.',
              updated_at = now()
          WHERE id = v_reg_id;
        END IF;
        CONTINUE;
      END IF;
    END IF;

    -- D7 step 1/2: peter- or auto-classified code already on the row
    IF v_coding_status IN ('auto_classified','peter_classified') THEN
      v_code := CASE WHEN v_direction = 'debit'
                     THEN COALESCE(NULLIF(v_peter_debit,''), NULLIF(v_sugg_debit,''))
                     ELSE COALESCE(NULLIF(v_peter_credit,''), NULLIF(v_sugg_credit,''))
                END;
      IF v_code = '__SOURCE__' THEN v_code := NULL; END IF;
    END IF;

    -- FIX 7 step 3: gl_classification_rules match against the merchant, same
    -- rules the statement writer uses, only when step 1/2 didn't already resolve
    -- a code and the row actually carries a merchant to match on.
    IF v_code IS NULL AND v_merchant IS NOT NULL AND length(trim(v_merchant)) > 0 THEN
      SELECT r.id, r.debit_account_code, r.credit_account_code, r.target_business_entity_id
      INTO v_rule_id, v_rule_debit_code, v_rule_credit_code, v_rule_target_entity
      FROM gl_classification_rules r
      WHERE r.agency_id = p_agency_id AND r.is_active = TRUE
        AND (r.match_payee_regex IS NULL OR v_merchant ~* r.match_payee_regex)
        AND (r.match_source_account IS NULL OR r.match_source_account = v_source_account_code)
        AND (r.match_amount_min IS NULL OR v_amount >= r.match_amount_min)
        AND (r.match_amount_max IS NULL OR v_amount <= r.match_amount_max)
        AND (r.match_direction IS NULL OR r.match_direction = v_direction OR r.match_direction = 'both')
      ORDER BY r.match_priority ASC NULLS LAST
      LIMIT 1;

      IF v_rule_id IS NOT NULL THEN
        IF v_rule_debit_code = '__SKIP__' AND v_rule_credit_code = '__SKIP__' THEN
          v_count_skipped_rule_not_pnl := v_count_skipped_rule_not_pnl + 1;
          CONTINUE;
        END IF;

        v_rule_resolved_code := CASE WHEN v_direction = 'credit' THEN v_rule_credit_code ELSE v_rule_debit_code END;

        IF v_rule_resolved_code IS NOT NULL AND v_rule_resolved_code <> '__SOURCE__' THEN
          IF v_rule_target_entity IS NOT NULL THEN
            SELECT id INTO v_target_account_id FROM chart_of_accounts
            WHERE agency_id = p_agency_id AND account_code = v_rule_resolved_code AND is_active = TRUE
              AND business_entity_id = v_rule_target_entity
            LIMIT 1;
          END IF;

          IF v_target_account_id IS NULL THEN
            SELECT id INTO v_target_account_id FROM chart_of_accounts
            WHERE agency_id = p_agency_id AND account_code = v_rule_resolved_code AND is_active = TRUE
              AND (business_entity_id = v_business_entity_id OR business_entity_id IS NULL)
            ORDER BY (business_entity_id = v_business_entity_id) DESC NULLS LAST
            LIMIT 1;
          END IF;

          IF v_target_account_id IS NULL THEN
            SELECT id INTO v_target_account_id FROM chart_of_accounts
            WHERE agency_id = p_agency_id AND account_code = v_rule_resolved_code AND is_active = TRUE
            ORDER BY business_entity_id::text NULLS FIRST
            LIMIT 1;
          END IF;

          IF v_target_account_id IS NOT NULL THEN
            SELECT account_type INTO v_target_account_type FROM chart_of_accounts WHERE id = v_target_account_id;
            IF v_target_account_type NOT IN ('income','expense') THEN
              v_count_skipped_balance_sheet := v_count_skipped_balance_sheet + 1;
              CONTINUE;
            END IF;
            v_classification_status := 'classified';
          END IF;
        END IF;
      END IF;
    END IF;

    -- Legacy D7 step 1/2 code (peter/auto), if it resolved one
    IF v_target_account_id IS NULL AND v_code IS NOT NULL THEN
      SELECT id, account_type INTO v_target_account_id, v_target_account_type
      FROM chart_of_accounts
      WHERE agency_id = p_agency_id AND account_code = v_code AND is_active = TRUE
        AND business_entity_id = v_business_entity_id
      LIMIT 1;

      IF v_target_account_id IS NULL THEN
        SELECT id, account_type INTO v_target_account_id, v_target_account_type
        FROM chart_of_accounts
        WHERE agency_id = p_agency_id AND account_code = v_code AND is_active = TRUE
        ORDER BY business_entity_id::text NULLS FIRST
        LIMIT 1;
      END IF;

      IF v_target_account_id IS NOT NULL THEN
        IF v_target_account_type NOT IN ('income','expense') THEN
          v_count_skipped_balance_sheet := v_count_skipped_balance_sheet + 1;
          CONTINUE;
        ELSE
          v_classification_status := 'classified';
        END IF;
      END IF;
    END IF;

    -- D7 step 4: entity unclassified holding account
    IF v_target_account_id IS NULL THEN
      v_target_account_id := get_entity_unclassified_account(
        p_agency_id, v_business_entity_id,
        CASE WHEN v_direction = 'credit' THEN 'income' ELSE 'expense' END
      );
      IF v_target_account_id IS NULL THEN
        v_count_skipped_unresolved := v_count_skipped_unresolved + 1;
        v_errors := v_errors || jsonb_build_object('cash_register_id', v_reg_id, 'reason', 'no_unclassified_account_for_entity', 'business_entity_id', v_business_entity_id);
        CONTINUE;
      END IF;
      v_classification_status := 'unclassified';
      v_suspense_reason := 'awaiting_statement';
    END IF;

    IF v_classification_status = 'classified' THEN
      v_count_classified := v_count_classified + 1;
      v_total_classified := v_total_classified + v_amount;
    ELSE
      v_count_unclassified := v_count_unclassified + 1;
      v_total_unclassified := v_total_unclassified + v_amount;
    END IF;

    v_description := COALESCE(NULLIF(trim(v_merchant), ''),
                               COALESCE(v_account_label, 'US Bank account ...'||v_account_last4)
                                 || ' — ' || (CASE WHEN v_direction='debit' THEN 'money out' ELSE 'money in' END)
                                 || ' (awaiting statement)');

    v_count_posted := v_count_posted + 1;

    IF NOT p_dry_run THEN
      INSERT INTO ledger (
        agency_id, entry_date, account_id, debit, credit, description,
        source, entry_type, cash_register_id, statement_id,
        classification_status, suspense_reason, rule_id_used, classified_by, classified_at
      ) VALUES (
        p_agency_id, v_txn_date, v_target_account_id,
        CASE WHEN v_direction = 'debit' THEN v_amount ELSE 0 END,
        CASE WHEN v_direction = 'credit' THEN v_amount ELSE 0 END,
        v_description, 'cash_register_gl_writer', 'cash_register_txn', v_reg_id, NULL,
        v_classification_status, v_suspense_reason,
        CASE WHEN v_classification_status = 'classified' THEN v_rule_id ELSE NULL END,
        CASE WHEN v_classification_status = 'classified' AND v_rule_id IS NOT NULL THEN 'rule:' || v_rule_id::text
             WHEN v_classification_status = 'classified' THEN 'register_direct'
             ELSE NULL END,
        CASE WHEN v_classification_status = 'classified' THEN NOW() ELSE NULL END
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', TRUE, 'dry_run', p_dry_run,
    'rows_seen', v_count_seen,
    'posted', v_count_posted,
    'suppressed_transfer', v_count_suppressed,
    'skipped_unresolved_account', v_count_skipped_unresolved,
    'skipped_already_posted', v_count_skipped_already_posted,
    'skipped_balance_sheet_target', v_count_skipped_balance_sheet,
    'skipped_rule_says_not_pnl', v_count_skipped_rule_not_pnl,
    'skipped_probable_card_payment', v_count_skipped_card_payment,
    'classified', v_count_classified, 'classified_amount', v_total_classified,
    'unclassified', v_count_unclassified, 'unclassified_amount', v_total_unclassified,
    'entity_mismatch_count', v_count_entity_mismatch, 'entity_mismatch', v_entity_mismatches,
    'errors', v_errors
  );
END;
$function$;
