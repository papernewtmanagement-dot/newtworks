DO $mig$
DECLARE
  v_def text := pg_get_functiondef('public.tg_tor_materialize_standing_pref()'::regprocedure);
  v_old text := $o$  v_starts := v_decided - EXTRACT(dow FROM v_decided)::int + 7;$o$;
  v_new text := $n$  -- The week the teammate asked for (start_date = the first day they want
  -- off), but never earlier than the week after the decision.
  v_starts := GREATEST(
    v_decided - EXTRACT(dow FROM v_decided)::int + 7,
    NEW.start_date - EXTRACT(dow FROM NEW.start_date)::int
  );$n$;
BEGIN
  IF position(v_old IN v_def) = 0 THEN RAISE EXCEPTION 'anchor not found'; END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$mig$;
