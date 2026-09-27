-- Peter 2026-09-27: everything settled needs a rule, even a one-time rule tied to one transaction,
-- so the ledger can be rebuilt from sources + rules. Two new match columns on the existing rules table.
ALTER TABLE public.gl_classification_rules ADD COLUMN IF NOT EXISTS match_statement_id uuid;
ALTER TABLE public.gl_classification_rules ADD COLUMN IF NOT EXISTS match_payroll_run_id uuid;
COMMENT ON COLUMN public.gl_classification_rules.match_statement_id IS 'One-time rule: applies only to this one statement line.';
COMMENT ON COLUMN public.gl_classification_rules.match_payroll_run_id IS 'Payroll reimbursement rule: applies only to this payroll run (with the payee pattern naming the person).';
ALTER TABLE public.gl_classification_rules DROP CONSTRAINT IF EXISTS gl_classification_rules_rule_scope_check;
ALTER TABLE public.gl_classification_rules ADD CONSTRAINT gl_classification_rules_rule_scope_check
  CHECK (rule_scope = ANY (ARRAY['both','statement','register','payroll']));

-- statement writer: a one-time rule only matches its own statement line.
DO $$
DECLARE d text; n int;
BEGIN
  SELECT pg_get_functiondef('public.statement_gl_writer'::regproc) INTO d;
  IF position('match_statement_id' IN d) = 0 THEN
    n := (length(d) - length(replace(d, 'r.rule_scope IN (''both'',''statement'')', ''))) / length('r.rule_scope IN (''both'',''statement'')');
    IF n <> 2 THEN RAISE EXCEPTION 'statement_gl_writer: expected 2 scope clauses, found %', n; END IF;
    d := replace(d, 'r.rule_scope IN (''both'',''statement'')',
                    'r.rule_scope IN (''both'',''statement'') AND (r.match_statement_id IS NULL OR r.match_statement_id = v_stmt_id)');
    EXECUTE d;
  END IF;

  SELECT pg_get_functiondef('public.cash_register_gl_writer'::regproc) INTO d;
  IF position('match_statement_id' IN d) = 0 THEN
    n := (length(d) - length(replace(d, 'r.rule_scope IN (''both'',''register'')', ''))) / length('r.rule_scope IN (''both'',''register'')');
    IF n <> 1 THEN RAISE EXCEPTION 'cash_register_gl_writer: expected 1 scope clause, found %', n; END IF;
    d := replace(d, 'r.rule_scope IN (''both'',''register'')',
                    'r.rule_scope IN (''both'',''register'') AND r.match_statement_id IS NULL AND r.match_payroll_run_id IS NULL');
    EXECUTE d;
  END IF;
END $$;

-- One job: pick the account for one person's payroll reimbursement.
CREATE OR REPLACE FUNCTION public.payroll_reimbursement_account(p_agency_id uuid, p_run_id uuid, p_person text)
RETURNS TABLE (account_id uuid, rule_id uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_rule uuid; v_code text; v_entity uuid;
BEGIN
  SELECT r.id, r.debit_account_code, COALESCE(r.target_business_entity_id, 'b2222222-2222-2222-2222-222222222222')
    INTO v_rule, v_code, v_entity
    FROM gl_classification_rules r
   WHERE r.agency_id = p_agency_id AND r.is_active AND r.rule_scope = 'payroll'
     AND ('Reimbursement — ' || p_person) ~* r.match_payee_regex
     AND (r.match_payroll_run_id IS NULL OR r.match_payroll_run_id = p_run_id)
   ORDER BY (r.match_payroll_run_id IS NULL), r.match_priority ASC NULLS LAST
   LIMIT 1;
  IF v_rule IS NOT NULL THEN
    RETURN QUERY SELECT c.id, v_rule FROM chart_of_accounts c
      WHERE c.agency_id = p_agency_id AND c.account_code = v_code AND c.business_entity_id = v_entity AND c.is_active LIMIT 1;
    IF FOUND THEN RETURN; END IF;
  END IF;
  RETURN QUERY SELECT c.id, NULL::uuid FROM chart_of_accounts c
    WHERE c.agency_id = p_agency_id AND c.account_code = '0003'
      AND c.business_entity_id = 'b2222222-2222-2222-2222-222222222222' AND c.is_active LIMIT 1;
END $$;

-- payroll writer: one reimbursement row per person, classified by rule (unclassified when no rule).
DO $$
DECLARE d text;
  a1 text := E'  v_reimb numeric;\n';
  a2 text := E'    v_person_lines := ''[]''::jsonb;\n    v_wrote_agency := false;';
  a3 text := E'        v_reimb_total := v_reimb_total + v_reimb;\n';
  a4 text := E'      IF v_reimb_total > 0 THEN\n        INSERT INTO ledger (agency_id, entry_date, account_id, debit, credit, description,\n          source, reference_number, payroll_run_id, entry_type)\n        VALUES (p_agency_id, v_pay_date, v_reimb_pending_acct, v_reimb_total, 0,\n                ''Reimbursements (pending categorization — walk into real bucket at year-end) — '' || v_desc,\n                ''payroll_gl_writer'', v_agency_ref, v_run_id, ''payroll'');\n      END IF;\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='payroll_gl_writer' AND length(pg_get_functiondef(p.oid)) > 5000;
  IF position('payroll_reimbursement_account' IN d) > 0 THEN RETURN; END IF;
  IF position(a1 IN d)=0 OR position(a2 IN d)=0 OR position(a3 IN d)=0 OR position(a4 IN d)=0 THEN
    RAISE EXCEPTION 'payroll_gl_writer body not as expected';
  END IF;
  d := replace(d, a1, a1 || E'  v_reimb_lines jsonb;\n  v_rl jsonb;\n  v_ra_acct uuid;\n  v_ra_rule uuid;\n');
  d := replace(d, a2, E'    v_person_lines := ''[]''::jsonb;\n    v_reimb_lines := ''[]''::jsonb;\n    v_wrote_agency := false;');
  d := replace(d, a3, a3 || E'        IF v_reimb > 0 THEN\n          v_reimb_lines := v_reimb_lines || jsonb_build_object(''name'', v_tm_first || '' '' || v_tm_last, ''amount'', v_reimb);\n        END IF;\n');
  d := replace(d, a4,
E'      -- One row per person, classified by a payroll rule (Peter 2026-09-27); no rule = unclassified.\n' ||
E'      FOR v_rl IN SELECT * FROM jsonb_array_elements(v_reimb_lines) LOOP\n' ||
E'        SELECT pa.account_id, pa.rule_id INTO v_ra_acct, v_ra_rule\n' ||
E'          FROM payroll_reimbursement_account(p_agency_id, v_run_id, v_rl->>''name'') pa;\n' ||
E'        INSERT INTO ledger (agency_id, entry_date, account_id, debit, credit, description,\n' ||
E'          source, reference_number, payroll_run_id, entry_type, rule_id_used, classification_status, classified_by, classified_at)\n' ||
E'        VALUES (p_agency_id, v_pay_date, COALESCE(v_ra_acct, v_reimb_pending_acct), (v_rl->>''amount'')::numeric, 0,\n' ||
E'                ''Reimbursement — '' || (v_rl->>''name'') || '' — '' || v_desc,\n' ||
E'                ''payroll_gl_writer'', v_agency_ref, v_run_id, ''payroll'', v_ra_rule,\n' ||
E'                CASE WHEN v_ra_rule IS NULL THEN ''unclassified'' ELSE ''classified'' END,\n' ||
E'                CASE WHEN v_ra_rule IS NULL THEN NULL ELSE ''rule:'' || v_ra_rule::text END,\n' ||
E'                CASE WHEN v_ra_rule IS NULL THEN NULL ELSE now() END);\n' ||
E'      END LOOP;\n');
  EXECUTE d;
END $$;

-- The rules Peter settled 2026-09-27.
INSERT INTO gl_classification_rules (agency_id, rule_name, match_priority, match_payee_regex, match_direction,
   debit_account_code, credit_account_code, target_business_entity_id, rule_scope, source, is_active, confidence,
   match_statement_id, match_payroll_run_id, tax_deductible)
VALUES
 ('126794dd-25ff-47d2-a436-724499733365','One-time: $22.23 mobile deposit 2026-06-12 = personal utility refund', 1, NULL, 'both', '9110','9110','b3333333-3333-3333-3333-333333333333','statement','peter_2026-09-27',true,'exact','ea370ab0-40a4-4857-8792-0e41d7e4da26',NULL,NULL),
 ('126794dd-25ff-47d2-a436-724499733365','One-time: $250 mobile deposit 2026-05-15 = tax-free adoption stipend', 1, NULL, 'both', '8400','8400','b3333333-3333-3333-3333-333333333333','statement','peter_2026-09-27',true,'exact','b5c92fe9-42e9-4d0c-8951-8ac42de83220',NULL,NULL),
 ('126794dd-25ff-47d2-a436-724499733365','One-time: Venmo $1,000 2026-09-17 = gift to people we know (tithe pool, not deductible)', 1, NULL, 'both', '9700','9700','b3333333-3333-3333-3333-333333333333','statement','peter_2026-09-26',true,'exact','6b517d6f-441e-43de-9421-a8259f651f90',NULL,false),
 ('126794dd-25ff-47d2-a436-724499733365','Payroll 2026-03-06: Stephanie reimbursement = licensing', 1, '(?i)Stephanie', 'debit', '6710','6710','b2222222-2222-2222-2222-222222222222','payroll','peter_2026-09-27',true,'exact',NULL,'92f3d1f0-368d-4a26-96af-d49107968bca',NULL),
 ('126794dd-25ff-47d2-a436-724499733365','Payroll 2026-04-10: Stephanie reimbursement = licensing', 1, '(?i)Stephanie', 'debit', '6710','6710','b2222222-2222-2222-2222-222222222222','payroll','peter_2026-09-27',true,'exact',NULL,'23e58cfa-0ca7-4713-91e0-e64d6f87d93b',NULL),
 ('126794dd-25ff-47d2-a436-724499733365','Payroll 2026-06-12: Stephanie reimbursement = licensing', 1, '(?i)Stephanie', 'debit', '6710','6710','b2222222-2222-2222-2222-222222222222','payroll','peter_2026-09-27',true,'exact',NULL,'0b359818-6940-4bfa-8108-672bb594cf87',NULL),
 ('126794dd-25ff-47d2-a436-724499733365','Payroll 2026-06-22: Jason reimbursement = licensing', 1, '(?i)Jason', 'debit', '6710','6710','b2222222-2222-2222-2222-222222222222','payroll','peter_2026-09-27',true,'exact',NULL,'19a243d9-2edf-46c8-8307-b7bd111815d1',NULL),
 ('126794dd-25ff-47d2-a436-724499733365','Payroll 2026-07-17: Stephanie reimbursement = licensing', 1, '(?i)Stephanie', 'debit', '6710','6710','b2222222-2222-2222-2222-222222222222','payroll','peter_2026-09-27',true,'exact',NULL,'f486a219-a827-41d7-82ab-46d4ec02a3bc',NULL),
 ('126794dd-25ff-47d2-a436-724499733365','Payroll 2026-07-31: Tommy reimbursement = business travel', 1, '(?i)Thomas|Tommy', 'debit', '6850','6850','b2222222-2222-2222-2222-222222222222','payroll','peter_2026-09-27',true,'exact',NULL,'0b8749b0-2923-4265-b216-66f72253471b',NULL),
 ('126794dd-25ff-47d2-a436-724499733365','Payroll 2026-07-31: John reimbursement = refund of benefits overcharged earlier in the year', 1, '(?i)John', 'debit', '6110','6110','b2222222-2222-2222-2222-222222222222','payroll','peter_2026-09-27',true,'exact',NULL,'0b8749b0-2923-4265-b216-66f72253471b',NULL);

-- Venmo moves from the statement-line category to its one-time rule (one mechanism, not two).
UPDATE statements SET category = NULL WHERE id = '6b517d6f-441e-43de-9421-a8259f651f90' AND category = 'Tithe & Charitable';
