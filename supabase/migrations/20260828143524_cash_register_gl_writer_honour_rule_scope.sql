-- Make the cash register writer honour rule_scope, and belt-and-braces, refuse
-- any rule that has no merchant condition it can actually test. Two guards
-- rather than one, because a future rule added with a memo condition and no
-- payee condition would otherwise become a wildcard again the moment someone
-- forgets to set rule_scope.
DO $mig$
DECLARE
  v_src text;
  v_old text := $old$      WHERE r.agency_id = p_agency_id AND r.is_active = TRUE
        AND (r.match_payee_regex IS NULL OR v_merchant ~* r.match_payee_regex)$old$;
  v_new text := $new$      WHERE r.agency_id = p_agency_id AND r.is_active = TRUE
        AND r.rule_scope IN ('both','register')
        AND NOT (r.match_payee_regex IS NULL AND r.match_memo_regex IS NOT NULL)
        AND (r.match_payee_regex IS NULL OR v_merchant ~* r.match_payee_regex)$new$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'cash_register_gl_writer';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'cash_register_gl_writer not found';
  END IF;

  IF position(v_old in v_src) = 0 THEN
    RAISE EXCEPTION 'anchor not found in cash_register_gl_writer -- aborting rather than guessing';
  END IF;

  IF (length(v_src) - length(replace(v_src, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'anchor is not unique in cash_register_gl_writer -- aborting';
  END IF;

  EXECUTE replace(v_src, v_old, v_new);
END
$mig$;
