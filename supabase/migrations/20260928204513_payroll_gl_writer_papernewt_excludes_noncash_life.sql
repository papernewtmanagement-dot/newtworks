DO $mig$
DECLARE d text; n text;
BEGIN
  d := pg_get_functiondef('public.payroll_gl_writer(uuid,boolean,date)'::regprocedure);
  n := replace(d, 'v_pn_total := v_pn_total + v_gross + COALESCE(v_er_taxes, 0);',
                  'v_pn_total := v_pn_total + v_gross - v_noncash + COALESCE(v_er_taxes, 0);  -- imputed life is never cash (Peter 2026-09-27)');
  n := replace(n, '''pn_expense'', v_gross + COALESCE(v_er_taxes, 0)',
                  '''pn_expense'', v_gross - v_noncash + COALESCE(v_er_taxes, 0)');
  IF n = d OR position('v_gross - v_noncash + COALESCE(v_er_taxes, 0);' in n) = 0
     OR position('''pn_expense'', v_gross - v_noncash' in n) = 0 THEN
    RAISE EXCEPTION 'replace did not apply';
  END IF;
  EXECUTE n;
END $mig$;
