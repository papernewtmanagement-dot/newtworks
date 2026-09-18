-- Point the huddle guest list at the calendar-invite roster so a new teammate
-- lands on the Daily Kickoff up to a week before their start date, instead of
-- on the morning itself. Both references swapped; nothing else in the function
-- changes.
DO $mig$
DECLARE
  v_src text;
  v_hits int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'huddle_calendar_sync' AND p.pronargs = 1;

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'huddle_calendar_sync(uuid) not found';
  END IF;

  v_hits := (length(v_src) - length(replace(v_src, '''agency_active_all''', ''))) / length('''agency_active_all''');
  IF v_hits <> 2 THEN
    RAISE EXCEPTION 'expected 2 agency_active_all references, found %', v_hits;
  END IF;

  EXECUTE replace(v_src, '''agency_active_all''', '''agency_calendar_invite''');
END
$mig$;
