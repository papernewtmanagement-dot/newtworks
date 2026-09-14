-- A teammate with no quote/sales seat now gets no pace emoji (NULL). Without
-- this guard the NULL would swallow the whole message: any || NULL in Postgres
-- makes the entire string NULL, so one seatless teammate would have blanked the
-- status block on every check-in.
DO $migration$
DECLARE
  v_def text;
  v_old text := $x$        || ' ' || v_emoji || v_extra$x$;
  v_new text := $x$        || COALESCE(' ' || v_emoji, '') || v_extra$x$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'render_team_status_block';

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'emoji concat not found in render_team_status_block - reconcile before rerunning';
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
END
$migration$;