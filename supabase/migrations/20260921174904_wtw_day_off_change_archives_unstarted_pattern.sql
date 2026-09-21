DO $mig$
DECLARE
  v_def text := pg_get_functiondef('public.tg_tor_materialize_standing_pref()'::regprocedure);
  v_old text := $o$     AND p.archived_at IS NULL
     AND (p.effective_until IS NULL OR p.effective_until >= v_starts);$o$;
  v_new text := $n$     AND p.archived_at IS NULL
     AND p.effective_from < v_starts
     AND (p.effective_until IS NULL OR p.effective_until >= v_starts);

  -- A pattern approved earlier that has not started yet is replaced outright.
  UPDATE public.standing_time_off_preferences p
     SET archived_at = now(),
         updated_at = now(),
         notes = concat_ws(' | ', p.notes, 'Replaced before it started by request ' || NEW.id::text)
   WHERE p.team_member_id = NEW.requester_team_id
     AND p.agency_id = NEW.agency_id
     AND p.archived_at IS NULL
     AND p.effective_from >= v_starts;$n$;
BEGIN
  IF position(v_old IN v_def) = 0 THEN RAISE EXCEPTION 'anchor not found'; END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$mig$;
