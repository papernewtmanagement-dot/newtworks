-- rp_guard_change raises the same error code for "not your row" and for
-- "that week is closed". Only swap in the host wording when the person
-- pressing the button really is not the host; otherwise let the closed-week
-- message through unchanged.
CREATE OR REPLACE FUNCTION public.rp_set_appointment_state(p_id uuid, p_state text, p_on date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; act RECORD; v_state text := lower(btrim(COALESCE(p_state,'')));
        v_on date := COALESCE(p_on, public.rp_today_central());
        v_host uuid;
BEGIN
  SELECT * INTO r FROM public.appointment_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that appointment was removed. Log it again instead.'; END IF;

  -- The host is whoever the appointment was handed to. Nobody handed it
  -- over, it belongs to the person who set it.
  v_host := COALESCE(NULLIF(r.escalated_to_team_member_id, r.team_member_id), r.team_member_id);
  BEGIN
    SELECT * INTO a FROM public.rp_guard_change(v_host, r.week_end_date, r.created_at);
  EXCEPTION WHEN insufficient_privilege THEN
    SELECT * INTO act FROM public.rp_resolve_actor(NULL);
    IF NOT act.is_admin AND act.actor_id IS DISTINCT FROM v_host THEN
      RAISE EXCEPTION 'only the person the appointment was handed to can mark it' USING ERRCODE='42501';
    END IF;
    RAISE;
  END;
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
  IF v_on > public.rp_today_central() THEN RAISE EXCEPTION 'the date cannot be in the future'; END IF;
  IF v_on < r.set_on THEN RAISE EXCEPTION 'that is before the appointment was set (%)', r.set_on; END IF;

  IF v_state = 'kept' THEN
    UPDATE public.appointment_log SET kept_on = v_on, no_show_on = NULL, updated_at = now() WHERE id = p_id;
  ELSIF v_state = 'no_show' THEN
    UPDATE public.appointment_log SET no_show_on = v_on, kept_on = NULL, sold_on = NULL, updated_at = now() WHERE id = p_id;
  ELSIF v_state = 'sold' THEN
    UPDATE public.appointment_log SET sold_on = v_on, kept_on = COALESCE(kept_on, v_on),
           no_show_on = NULL, updated_at = now() WHERE id = p_id;
  ELSIF v_state = 'open' THEN
    UPDATE public.appointment_log SET kept_on = NULL, no_show_on = NULL, sold_on = NULL, updated_at = now() WHERE id = p_id;
  ELSE
    RAISE EXCEPTION 'unknown state: %', p_state;
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id, 'state', v_state);
END $function$;
