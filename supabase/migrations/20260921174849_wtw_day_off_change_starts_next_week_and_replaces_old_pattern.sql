-- A WtW day off change is a replacement, not an addition, and it never touches
-- the week it is approved in. On approval: the new pattern starts the next
-- Sunday-anchored week, and every other active preference for that teammate
-- ends the Saturday before. The form no longer asks for a start date.
CREATE OR REPLACE FUNCTION public.tg_tor_materialize_standing_pref()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_day JSONB;
  v_new_pref_id UUID;
  v_pref_ids UUID[] := ARRAY[]::UUID[];
  v_decided date := (COALESCE(NEW.decided_at, now()) AT TIME ZONE 'America/Chicago')::date;
  v_starts date;
BEGIN
  IF NEW.request_type <> 'standing_time_off_preference' THEN RETURN NEW; END IF;
  IF NEW.status <> 'approved' THEN RETURN NEW; END IF;
  IF OLD.status = 'approved' THEN RETURN NEW; END IF;
  IF NEW.resulting_standing_pref_ids IS NOT NULL
     AND array_length(NEW.resulting_standing_pref_ids, 1) > 0 THEN
    RETURN NEW;
  END IF;

  -- First day of the next Sunday-to-Saturday week after the decision.
  v_starts := v_decided - EXTRACT(dow FROM v_decided)::int + 7;

  -- The old pattern keeps running through the current week, then stops.
  UPDATE public.standing_time_off_preferences p
     SET effective_until = v_starts - 1,
         updated_at = now()
   WHERE p.team_member_id = NEW.requester_team_id
     AND p.agency_id = NEW.agency_id
     AND p.archived_at IS NULL
     AND (p.effective_until IS NULL OR p.effective_until >= v_starts);

  FOR v_day IN SELECT jsonb_array_elements(NEW.standing_pref_days) LOOP
    INSERT INTO public.standing_time_off_preferences (
      agency_id, team_member_id, day_of_week, day_part, pattern, is_paid,
      trigger_type, effective_from, approved_by_team_id, approved_at,
      source_request_id, notes
    ) VALUES (
      NEW.agency_id, NEW.requester_team_id,
      v_day->>'day_of_week', v_day->>'day_part', v_day->>'pattern',
      NEW.standing_pref_is_paid, NEW.standing_pref_trigger,
      v_starts,
      NEW.decided_by_team_id, COALESCE(NEW.decided_at, NOW()),
      NEW.id, NEW.notes
    )
    RETURNING id INTO v_new_pref_id;
    v_pref_ids := array_append(v_pref_ids, v_new_pref_id);
  END LOOP;

  UPDATE public.time_off_requests
     SET resulting_standing_pref_ids = v_pref_ids
   WHERE id = NEW.id;

  RETURN NEW;
END $function$;

-- Stephanie (Peter 2026-09-21): Fridays full day from next week on; this week
-- keeps her Monday and Wednesday afternoons.
UPDATE public.standing_time_off_preferences
   SET effective_from = DATE '2026-09-27', updated_at = now()
 WHERE id = '05535a2e-e6cf-42a5-8bdd-1f88b08cb7ff';
UPDATE public.standing_time_off_preferences
   SET effective_until = DATE '2026-09-26', updated_at = now()
 WHERE id IN ('41c352cb-3732-4215-88e9-679dc460f52d', '15b73c13-05aa-4c53-8726-5521ffcac155');
