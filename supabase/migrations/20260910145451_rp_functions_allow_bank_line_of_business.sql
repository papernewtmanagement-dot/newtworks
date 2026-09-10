-- Let the entry functions accept the new bank line. Same list in each place, so a
-- source-level substitution keeps every other line of these functions untouched.
DO $do$
DECLARE
  fn text;
  v_src text;
  v_new text;
BEGIN
  FOREACH fn IN ARRAY ARRAY['rp_log_sale','rp_log_quote','rp_log_cancelation','rp_log_activity'] LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = fn;

    IF v_src IS NULL THEN
      RAISE EXCEPTION '% not found', fn;
    END IF;

    v_new := replace(v_src,
      '(''auto'',''fire'',''life'',''health'',''variable'')',
      '(''auto'',''fire'',''life'',''health'',''variable'',''bank'')');

    IF v_new = v_src THEN
      RAISE EXCEPTION 'line-of-business list not found in %', fn;
    END IF;

    EXECUTE v_new;
  END LOOP;
END
$do$;