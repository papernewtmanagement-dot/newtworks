-- Team Win the Week lines now read "$Q" and "SP" so the two team totals use the
-- same labels as the per-person columns above them. "Sales" next to "$Q" was the
-- only spot still spelling a label out.
DO $migration$
DECLARE
  v_def text;
  v_old text := $x$'• Sales: '$x$;
  v_new text := $x$'• SP: '$x$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'render_team_status_block';

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'Sales label not found in render_team_status_block';
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
END
$migration$;