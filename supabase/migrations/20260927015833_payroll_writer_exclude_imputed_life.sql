-- "LIFE *" on SurePayroll pay stubs is imputed income (the taxable value of group life insurance):
-- it is added to gross for taxes but never paid out. It was being booked as wages.
DO $$
DECLARE d text;
  a1 text := E'          WHEN ''LIFE *'' THEN v_hourly := v_hourly + v_val;\n';
  a2 text := E'        v_gap := GREATEST(0, v_gross - v_recognized);\n';
  a3 text := E'  v_reimb numeric;\n';
  a4 text := E'      v_commission := 0; v_other := 0; v_reimb := 0;\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p
   WHERE p.pronamespace='public'::regnamespace AND p.proname='payroll_gl_writer' AND length(pg_get_functiondef(p.oid)) > 5000;
  IF position('v_noncash' IN d) > 0 THEN RETURN; END IF;
  IF position(a1 IN d)=0 OR position(a2 IN d)=0 OR position(a3 IN d)=0 OR position(a4 IN d)=0 THEN RAISE EXCEPTION 'body not as expected'; END IF;
  d := replace(d, a3, a3 || E'  v_noncash numeric;\n');
  d := replace(d, a4, a4 || E'      v_noncash := 0;\n');
  d := replace(d, a1, E'          -- Imputed group life income: taxed, never paid in cash (Peter 2026-09-27).\n          WHEN ''LIFE *'' THEN v_noncash := v_noncash + v_val;\n');
  d := replace(d, a2, E'        v_gap := GREATEST(0, v_gross - v_recognized - v_noncash);\n');
  EXECUTE d;
END $$;
