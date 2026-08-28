-- The statement writer has two rule-selection blocks, so patch both. A rule
-- marked register-only must not fire on statements.
DO $mig$
DECLARE
  v_src text;
  v_old text := 'WHERE r.agency_id = p_agency_id AND r.is_active = TRUE';
  v_new text := 'WHERE r.agency_id = p_agency_id AND r.is_active = TRUE
        AND r.rule_scope IN (''both'',''statement'')';
  v_hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'statement_gl_writer';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'statement_gl_writer not found';
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old);
  IF v_hits <> 2 THEN
    RAISE EXCEPTION 'expected 2 rule-selection blocks in statement_gl_writer, found % -- aborting', v_hits;
  END IF;

  IF position('rule_scope' in v_src) > 0 THEN
    RAISE EXCEPTION 'statement_gl_writer already references rule_scope -- aborting to avoid double patch';
  END IF;

  EXECUTE replace(v_src, v_old, v_new);
END
$mig$;
