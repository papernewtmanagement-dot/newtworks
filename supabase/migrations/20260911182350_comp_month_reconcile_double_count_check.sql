-- Check 6 for the comp reconcile bot: a comp deposit counted twice.
-- Income is booked from the comp statement lines; the bank deposit itself must
-- stay out of income. If the cash register posts the deposit to income anyway
-- (it did on 2026-08-29: $19,105.98 to *Unclassified Income, because the
-- statement's printed deposit was missing, so the deposit guard could not
-- match it), the paycheck lands in the books twice.
DO $$
DECLARE v_def text;
  v_old text := $q$  IF array_length(v_problems, 1) IS NULL THEN$q$;
  v_new text := $q$  -- 6. A comp deposit also booked as income from the bank side (counted twice).
  SELECT count(*), COALESCE(sum(l.credit),0) INTO v_n, v_amt
  FROM ledger l JOIN chart_of_accounts a ON a.id = l.account_id
  WHERE l.agency_id = p_agency_id AND l.comp_recap_id IS NULL AND l.credit > 0
    AND a.account_type ILIKE '%income%'
    AND l.entry_date >= make_date(p_year, p_month, 1)
    AND l.entry_date < make_date(p_year, p_month, 1) + INTERVAL '1 month 5 days'
    AND l.credit IN (
      SELECT d.stated_net_payable FROM documents d
      WHERE d.stated_net_payable IS NOT NULL AND d.id IN (
        SELECT x.source_document_id FROM comp_recap x WHERE x.agency_id = p_agency_id
          AND x.period_year = p_year AND x.period_month = p_month AND x.source_document_id IS NOT NULL));
  IF v_n > 0 THEN
    v_problems := v_problems || format('%s bank deposit(s) matching a comp statement were also booked as income (%s counted twice).', v_n, to_char(v_amt, 'FM$999,999,990.00'));
  END IF;

  IF array_length(v_problems, 1) IS NULL THEN$q$;
BEGIN
  v_def := pg_get_functiondef('public.comp_month_reconcile(uuid,int,int)'::regprocedure);
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'comp_month_reconcile anchor not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;