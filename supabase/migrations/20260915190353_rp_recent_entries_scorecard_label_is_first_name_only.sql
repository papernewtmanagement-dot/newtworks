-- rp_customer_label refuses a blank first name AND a missing last initial. A conversation
-- score has no last initial at all, so that helper can never label one. Use the first name
-- on its own, which is also all the house rule allows to be shown for a customer.
DO $migrate$
DECLARE v_def text; v_new text; v_old text; v_ins text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rp_recent_entries';
  IF v_def IS NULL THEN RAISE EXCEPTION 'rp_recent_entries not found'; END IF;

  v_old := E'           CASE WHEN NULLIF(btrim(COALESCE(f.customer_first_name, '''')), '''') IS NULL\n'
        || E'                THEN NULL\n'
        || E'                ELSE public.rp_customer_label(f.customer_first_name, NULL) END,\n';
  v_ins := E'           NULLIF(btrim(COALESCE(f.customer_first_name, '''')), ''''),\n';

  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'scorecard label anchor not found - re-read rp_recent_entries before patching';
  END IF;
  v_new := replace(v_def, v_old, v_ins);
  IF v_new = v_def THEN RAISE EXCEPTION 'replacement made no change'; END IF;
  EXECUTE v_new;
END $migrate$;