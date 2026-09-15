-- fit_scorecards carries phone_last4 and the edit form shows it, but rp_edit_scorecard
-- had no key for it, so a corrected phone would have been accepted and silently dropped.
DO $migrate$
DECLARE v_def text; v_new text; v_old text; v_ins text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rp_edit_scorecard';
  IF v_def IS NULL THEN RAISE EXCEPTION 'rp_edit_scorecard not found'; END IF;

  v_old := E'    updated_at = now()\n  WHERE id = p_id;';
  v_ins := E'    phone_last4 = CASE WHEN c ? ''phone_last4''\n'
        || E'                       THEN NULLIF(regexp_replace(COALESCE(c->>''phone_last4'',''''), ''\\D'', '''', ''g''), '''')\n'
        || E'                       ELSE phone_last4 END,\n'
        || E'    updated_at = now()\n  WHERE id = p_id;';

  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'rp_edit_scorecard update anchor not found - re-read it before patching';
  END IF;
  IF position('phone_last4 = CASE WHEN c ?' in v_def) > 0 THEN
    RAISE NOTICE 'already patched, nothing to do';
    RETURN;
  END IF;

  v_new := replace(v_def, v_old, v_ins);
  IF v_new = v_def THEN RAISE EXCEPTION 'replacement made no change'; END IF;
  EXECUTE v_new;
END $migrate$;