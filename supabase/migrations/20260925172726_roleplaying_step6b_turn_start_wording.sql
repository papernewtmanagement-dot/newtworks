-- Roleplaying step 6b: at the start of a turn, only Knocked down reads "gets up"; any other effect that clears then
-- (Defending, Dug in) reads "is no longer …". In-place edit of rpg_session_next_turn at one anchor.
DO $do$
DECLARE v_src text; a text; n text;
BEGIN
  v_src := pg_get_functiondef('public.rpg_session_next_turn'::regproc);
  a := 'v_next.name || '' gets up. No longer '' || v_a.ename || ''.''';
  n := 'v_next.name || CASE WHEN v_a.ename = ''Knocked down'' THEN '' gets up. No longer Knocked down.'' ELSE '' is no longer '' || v_a.ename || ''.'' END';
  IF position('is no longer '' || v_a.ename' IN v_src) > 0 THEN RETURN; END IF;
  IF (length(v_src) - length(replace(v_src, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'next_turn anchor not unique'; END IF;
  EXECUTE replace(v_src, a, n);
END $do$;
