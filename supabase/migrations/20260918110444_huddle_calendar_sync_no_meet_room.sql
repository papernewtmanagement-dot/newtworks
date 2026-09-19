DO $mig$
DECLARE
  v_def text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'huddle_calendar_sync'
    AND pg_get_function_identity_arguments(p.oid) = 'p_agency_id uuid';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'huddle_calendar_sync(p_agency_id uuid) not found';
  END IF;

  v_new := replace(v_def, '''create_meeting_room'',    true', '''create_meeting_room'',    false');

  IF v_new = v_def THEN
    RAISE EXCEPTION 'create_meeting_room flag not found — nothing changed';
  END IF;

  EXECUTE v_new;
END
$mig$;
