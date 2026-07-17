-- On approval of a request_type=standing_time_off_preference request,
-- materialize one standing_time_off_preferences row per day in
-- standing_pref_days.

CREATE OR REPLACE FUNCTION public.tg_tor_materialize_standing_pref()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_day JSONB;
  v_new_pref_id UUID;
  v_pref_ids UUID[] := ARRAY[]::UUID[];
BEGIN
  -- Only act on transitions to approved for standing pref requests
  IF NEW.request_type <> 'standing_time_off_preference' THEN
    RETURN NEW;
  END IF;
  IF NEW.status <> 'approved' THEN
    RETURN NEW;
  END IF;
  IF OLD.status = 'approved' THEN
    RETURN NEW;  -- already processed
  END IF;
  IF NEW.resulting_standing_pref_ids IS NOT NULL
     AND array_length(NEW.resulting_standing_pref_ids, 1) > 0 THEN
    RETURN NEW;  -- already materialized
  END IF;

  -- Materialize each day
  FOR v_day IN SELECT jsonb_array_elements(NEW.standing_pref_days) LOOP
    INSERT INTO public.standing_time_off_preferences (
      agency_id,
      team_member_id,
      day_of_week,
      day_part,
      pattern,
      is_paid,
      trigger_type,
      effective_from,
      approved_by_team_id,
      approved_at,
      source_request_id,
      notes
    ) VALUES (
      NEW.agency_id,
      NEW.requester_team_id,
      v_day->>'day_of_week',
      v_day->>'day_part',
      v_day->>'pattern',
      NEW.standing_pref_is_paid,
      NEW.standing_pref_trigger,
      COALESCE(NEW.start_date, CURRENT_DATE),
      NEW.decided_by_team_id,
      COALESCE(NEW.decided_at, NOW()),
      NEW.id,
      NEW.notes
    )
    RETURNING id INTO v_new_pref_id;
    v_pref_ids := array_append(v_pref_ids, v_new_pref_id);
  END LOOP;

  -- Stamp the request with the resulting pref ids (without re-firing this trigger — set is idempotent via early-return guard above)
  UPDATE public.time_off_requests
     SET resulting_standing_pref_ids = v_pref_ids
   WHERE id = NEW.id;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS tor_materialize_standing_pref ON public.time_off_requests;
CREATE TRIGGER tor_materialize_standing_pref
  AFTER UPDATE ON public.time_off_requests
  FOR EACH ROW
  WHEN (NEW.status = 'approved' AND (OLD.status IS DISTINCT FROM NEW.status))
  EXECUTE FUNCTION public.tg_tor_materialize_standing_pref();

COMMENT ON FUNCTION public.tg_tor_materialize_standing_pref IS
  'On approval of a standing_time_off_preference request, inserts one standing_time_off_preferences row per day in standing_pref_days and stamps resulting_standing_pref_ids on the request.';;