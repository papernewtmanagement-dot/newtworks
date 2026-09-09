-- Offboarding gap: nothing retired a teammate's standing time-off preferences
-- when they left. John Kostov's Friday row outlived his 2026-09-01 departure by
-- eight days and had to be archived by hand. Gate 0 in
-- materialize_standing_time_off stops the day off being created, but the stale
-- row still shows on any screen listing active preferences, and any already
-- materialized future days off sit on the calendar.
--
-- This closes it at the source. Departure is read from all three signals the
-- team record uses together (archived_at, is_active, end_date):
--   * a FUTURE end date only shortens the preferences, via effective_until, so
--     the person keeps their arrangement through their last day
--   * archived, deactivated, or an end date already reached archives them
--   * approved days off already materialized past the last day are canceled
CREATE OR REPLACE FUNCTION public.team_departure_archives_standing_prefs()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_last_day date := NEW.end_date;
  v_departed boolean;
  v_prefs int := 0;
  v_days int := 0;
BEGIN
  v_departed := NEW.archived_at IS NOT NULL
                OR NEW.is_active IS NOT TRUE
                OR (v_last_day IS NOT NULL AND v_last_day <= CURRENT_DATE);

  -- Future last day: shorten the preferences, do not retire them yet.
  IF NOT v_departed AND v_last_day IS NOT NULL THEN
    UPDATE public.standing_time_off_preferences p
       SET effective_until = v_last_day, updated_at = NOW()
     WHERE p.team_member_id = NEW.id
       AND p.archived_at IS NULL
       AND (p.effective_until IS NULL OR p.effective_until > v_last_day);
    RETURN NEW;
  END IF;

  IF NOT v_departed THEN
    RETURN NEW;
  END IF;

  UPDATE public.standing_time_off_preferences p
     SET archived_at = NOW(),
         notes = COALESCE(p.notes || ' | ', '')
                 || 'Archived automatically on offboarding '
                 || COALESCE(v_last_day::text, CURRENT_DATE::text) || '.',
         updated_at = NOW()
   WHERE p.team_member_id = NEW.id
     AND p.archived_at IS NULL;
  GET DIAGNOSTICS v_prefs = ROW_COUNT;

  -- Days off already generated from those preferences for dates after the
  -- person's last day are not theirs to keep.
  UPDATE public.time_off_requests r
     SET status = 'canceled',
         decided_at = NOW(),
         decision_note = 'Canceled automatically on offboarding: date falls after the last day.',
         updated_at = NOW()
   WHERE r.requester_team_id = NEW.id
     AND r.derived_from_standing_pref_id IS NOT NULL
     AND r.status = 'approved'
     AND r.start_date > COALESCE(v_last_day, CURRENT_DATE);
  GET DIAGNOSTICS v_days = ROW_COUNT;

  IF v_prefs > 0 OR v_days > 0 THEN
    RAISE NOTICE 'Offboarding %: archived % standing time-off preference(s), canceled % future day(s) off.',
      NEW.id, v_prefs, v_days;
  END IF;

  RETURN NEW;
END $function$;

REVOKE EXECUTE ON FUNCTION public.team_departure_archives_standing_prefs() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.team_departure_archives_standing_prefs() FROM anon;
REVOKE EXECUTE ON FUNCTION public.team_departure_archives_standing_prefs() FROM authenticated;

DROP TRIGGER IF EXISTS trg_team_departure_archives_standing_prefs ON public.team;
CREATE TRIGGER trg_team_departure_archives_standing_prefs
  AFTER UPDATE OF is_active, end_date, archived_at ON public.team
  FOR EACH ROW
  WHEN (
    (NEW.archived_at IS NOT NULL AND OLD.archived_at IS NULL)
    OR (NEW.is_active IS NOT TRUE AND OLD.is_active IS TRUE)
    OR (NEW.end_date IS NOT NULL AND OLD.end_date IS DISTINCT FROM NEW.end_date)
  )
  EXECUTE FUNCTION public.team_departure_archives_standing_prefs();
