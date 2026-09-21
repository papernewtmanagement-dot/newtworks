-- My cancelation loop declared a variable named x, and the issued-premium query
-- right above it already uses x as a table alias. Postgres refused the whole
-- statement as ambiguous. Renamed the variable to pol; nothing else changed.
DO $mig$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rp_backfill_save';

  v_def := replace(v_def, 'a RECORD; rec jsonb; x jsonb; v_id uuid;', 'a RECORD; rec jsonb; pol jsonb; v_id uuid;');
  v_def := replace(v_def, 'FOR x IN SELECT * FROM jsonb_array_elements(rec->''policies'') LOOP',
                          'FOR pol IN SELECT * FROM jsonb_array_elements(rec->''policies'') LOOP');
  v_def := replace(v_def, 'v_on := NULLIF(btrim(COALESCE(x->>''canceled_on'','''')), '''')::date;',
                          'v_on := NULLIF(btrim(COALESCE(pol->>''canceled_on'','''')), '''')::date;');
  v_def := replace(v_def, 'WHERE p.id = (x->>''id'')::uuid AND p.sales_log_id = v_id AND p.agency_id = a.agency_id;',
                          'WHERE p.id = (pol->>''id'')::uuid AND p.sales_log_id = v_id AND p.agency_id = a.agency_id;');

  IF v_def LIKE '%rec jsonb; x jsonb;%' OR v_def NOT LIKE '%FOR pol IN%' THEN
    RAISE EXCEPTION 'rp_backfill_save did not match the expected shape; not patching blind';
  END IF;
  EXECUTE v_def;
END $mig$;
