-- Fix the "Off by" figure: the trailing '-' in the format printed as a literal.
DO $$
DECLARE v_def text;
  v_old text := $q$to_char(v_stated - (v_comp - v_ded), 'FM$999,999,990.00-')$q$;
  v_new text := $q$to_char(abs(v_stated - (v_comp - v_ded)), 'FM$999,999,990.00')$q$;
BEGIN
  v_def := pg_get_functiondef('public.comp_net_deposit_notice(uuid,int,int,int,boolean)'::regprocedure);
  IF strpos(v_def, v_old) = 0 THEN RAISE EXCEPTION 'anchor not found'; END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $$;