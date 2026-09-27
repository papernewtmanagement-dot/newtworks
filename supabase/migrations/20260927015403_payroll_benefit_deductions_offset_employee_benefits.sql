-- Peter 2026-09-27: the agency pays the team's benefit premiums in full and takes the employee's
-- share out of their pay. Newtworks booked full gross pay AND the full premium, never the share
-- coming back. One function says how much of a paycheck was benefit premiums; the payroll writer
-- books it back against Employee Benefits and the payroll draft (owed to PaperNewt) shrinks by it.
CREATE OR REPLACE FUNCTION public.payroll_benefit_deduction(p_payroll_detail_id uuid)
RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public' AS $$
  WITH pd AS (SELECT * FROM payroll_detail WHERE id = p_payroll_detail_id),
  keys AS (SELECT k.key, (k.value->>'period')::numeric v
             FROM pd, jsonb_each(COALESCE(pd.raw_deductions->'items', pd.raw_deductions)) k
            WHERE pd.raw_deductions IS NOT NULL AND jsonb_typeof(k.value) = 'object')
  SELECT CASE
    -- Itemized deductions: only the benefit premium lines.
    WHEN (SELECT raw_deductions FROM pd) IS NOT NULL THEN
      COALESCE((SELECT sum(v) FROM keys WHERE key IN ('HEALTH','MEDICAL','DENTAL','VISION')), 0)
    -- Older imports carry one lump. Count it as premiums only for someone whose itemized runs show
    -- benefit premiums and never a garnishment or child support line.
    WHEN EXISTS (SELECT 1 FROM payroll_detail p2, jsonb_each(COALESCE(p2.raw_deductions->'items', p2.raw_deductions)) k
                  WHERE p2.team_member_id = (SELECT team_member_id FROM pd) AND p2.raw_deductions IS NOT NULL
                    AND jsonb_typeof(k.value)='object' AND k.key IN ('HEALTH','MEDICAL','DENTAL','VISION'))
     AND NOT EXISTS (SELECT 1 FROM payroll_detail p2, jsonb_each(COALESCE(p2.raw_deductions->'items', p2.raw_deductions)) k
                  WHERE p2.team_member_id = (SELECT team_member_id FROM pd) AND p2.raw_deductions IS NOT NULL
                    AND jsonb_typeof(k.value)='object' AND (k.key ~* 'GARNISH|CHILD' OR k.key ~* '^VA'))
    THEN COALESCE((SELECT other_deductions FROM pd), 0)
    ELSE 0 END;
$$;

DO $$
DECLARE d text;
  a_decl text := E'  v_reimb_lines jsonb;\n';
  a_lookup text := E'  SELECT id INTO v_intercompany_acct FROM chart_of_accounts';
  a_init text := E'    v_reimb_lines := ''[]''::jsonb;\n';
  a_acc text := E'        v_reimb_total := v_reimb_total + v_reimb;\n';
  a_ic text := E'                 + v_reimb_total;';
  a_row text := E'      END LOOP;\n\n      INSERT INTO ledger (agency_id, entry_date, account_id, debit, credit, description,\n        source, reference_number, payroll_run_id, entry_type)\n      VALUES (p_agency_id, v_pay_date, v_intercompany_acct, 0, v_ic_credit,';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='payroll_gl_writer' AND length(pg_get_functiondef(p.oid)) > 5000;
  IF position('payroll_benefit_deduction' IN d) > 0 THEN RETURN; END IF;
  IF position(a_decl IN d)=0 OR position(a_lookup IN d)=0 OR position(a_init IN d)=0 OR position(a_acc IN d)=0
     OR position(a_ic IN d)=0 OR position(a_row IN d)=0 THEN RAISE EXCEPTION 'payroll_gl_writer body not as expected'; END IF;
  d := replace(d, a_decl, a_decl || E'  v_ben numeric;\n  v_ben_total numeric;\n  v_ben_acct uuid;\n');
  d := replace(d, a_lookup, E'  SELECT id INTO v_ben_acct FROM chart_of_accounts\n    WHERE agency_id=p_agency_id AND account_code=''6110''\n      AND business_entity_id=v_agency_entity AND is_active=true;\n' || a_lookup);
  d := replace(d, a_init, a_init || E'    v_ben_total := 0;\n');
  d := replace(d, a_acc, a_acc || E'        v_ben := COALESCE(payroll_benefit_deduction(v_pd_id), 0);\n        v_ben_total := v_ben_total + v_ben;\n');
  d := replace(d, a_ic, E'                 + v_reimb_total\n                 - v_ben_total;');
  d := replace(d, a_row, E'      END LOOP;\n\n' ||
    E'      -- Team benefit premiums taken out of pay: the agency paid the full premium, this share came back.\n' ||
    E'      IF v_ben_total > 0 THEN\n' ||
    E'        INSERT INTO ledger (agency_id, entry_date, account_id, debit, credit, description,\n' ||
    E'          source, reference_number, payroll_run_id, entry_type, classification_status)\n' ||
    E'        VALUES (p_agency_id, v_pay_date, v_ben_acct, 0, v_ben_total,\n' ||
    E'                ''Team share of benefit premiums taken out of pay — '' || v_desc,\n' ||
    E'                ''payroll_gl_writer'', v_agency_ref, v_run_id, ''payroll'', ''classified'');\n' ||
    E'      END IF;\n\n' ||
    E'      INSERT INTO ledger (agency_id, entry_date, account_id, debit, credit, description,\n        source, reference_number, payroll_run_id, entry_type)\n      VALUES (p_agency_id, v_pay_date, v_intercompany_acct, 0, v_ic_credit,');
  EXECUTE d;
END $$;
