-- Tripwire: when State Farm's printed deposit differs from the comp statement
-- lines minus deductions, raise a high alert in financials. Would have caught
-- the Aug 16-31 2026 $450 cash award the day it landed. Never blocks the send.
DO $$
DECLARE v_def text;
  v_anchor text := $q$  BEGIN
    v_res := public.telegram_send('admin', v_text, p_agency_id);$q$;
  v_add text := $q$  BEGIN
    IF v_stated IS NOT NULL AND abs(v_stated - (v_comp - v_ded)) >= 0.01 THEN
      INSERT INTO alerts (agency_id, alert_type, severity, title, message, module_reference)
      VALUES (p_agency_id, 'reconciliation_mismatch', 'high',
        'Comp records do not match the ' || v_label || ' deposit',
        'State Farm deposited ' || to_char(v_stated, 'FM$999,999,990.00')
          || '. Comp statement lines minus deductions come to ' || to_char(v_comp - v_ded, 'FM$999,999,990.00')
          || '. Off by ' || to_char(v_stated - (v_comp - v_ded), 'FM$999,999,990.00-')
          || '. A line on the statement was not captured.',
        'financials');
    END IF;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

$q$;
BEGIN
  v_def := pg_get_functiondef('public.comp_net_deposit_notice(uuid,int,int,int,boolean)'::regprocedure);
  IF strpos(v_def, v_anchor) = 0 OR strpos(v_def, 'reconciliation_mismatch') > 0 THEN
    RAISE EXCEPTION 'comp_net_deposit_notice changed since read; anchor not found or alert already present';
  END IF;
  EXECUTE replace(v_def, v_anchor, v_add || v_anchor);
END $$;