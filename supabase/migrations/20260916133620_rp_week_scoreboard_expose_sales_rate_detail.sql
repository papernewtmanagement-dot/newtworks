-- The page has to show "1% base plus 29 steps" without knowing what a base or a
-- step is. Hand it the whole rates block so nothing is hardcoded on the frontend.
DO $mig$
DECLARE
  v_def text;
  v_old text := E'        ''units'', COALESCE(s.cur->''units'', ''{}''::jsonb),\n';
  v_new text := E'        ''units'', COALESCE(s.cur->''units'', ''{}''::jsonb),\n'
             || E'        ''rates'', COALESCE(s.cur->''rates'', ''{}''::jsonb),\n';
  v_old_rep text := E'          ''tiers'', NULL::jsonb, ''units'', NULL::jsonb,\n';
  v_new_rep text := E'          ''tiers'', NULL::jsonb, ''units'', NULL::jsonb, ''rates'', NULL::jsonb,\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';

  IF position(v_new IN v_def) > 0 THEN RAISE NOTICE 'already applied'; RETURN; END IF;
  IF position(v_old IN v_def) = 0 OR position(v_old_rep IN v_def) = 0 THEN
    RAISE EXCEPTION 'expected sales lines not found - another thread changed rp_week_scoreboard_for';
  END IF;

  v_def := replace(v_def, v_old, v_new);
  v_def := replace(v_def, v_old_rep, v_new_rep);
  EXECUTE v_def;
END $mig$;
