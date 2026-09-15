-- Log an appointment. One record; it moves through its states later.
CREATE OR REPLACE FUNCTION public.rp_log_appointment(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_on date := COALESCE(NULLIF(p->>'set_on','')::date, public.rp_today_central());
  v_to uuid := NULLIF(p->>'escalated_to_team_member_id','')::uuid;
  v_first text := btrim(COALESCE(p->>'customer_first',''));
  v_init  text := upper(btrim(COALESCE(p->>'customer_last_initial','')));
  v_id uuid;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  IF v_on > public.rp_today_central() THEN RAISE EXCEPTION 'the date cannot be in the future'; END IF;
  IF v_first = '' THEN RAISE EXCEPTION 'who is the appointment with'; END IF;
  IF regexp_replace(COALESCE(p->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;
  INSERT INTO public.appointment_log (agency_id, team_member_id, escalated_to_team_member_id,
    customer_first_name, customer_last_initial, customer_label, phone_last4,
    set_on, week_end_date, note, ecrm_url, created_by)
  VALUES (a.agency_id, a.team_member_id, v_to, v_first, v_init,
    public.rp_customer_label(v_first, v_init), regexp_replace(p->>'phone_last4','\D','','g'),
    v_on, public.rp_week_end(v_on),
    NULLIF(btrim(COALESCE(p->>'note','')),''), NULLIF(btrim(COALESCE(p->>'ecrm_url','')),''),
    auth.uid())
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'customer', public.rp_customer_label(v_first, v_init));
END $function$;

-- Move it along: kept, no show, sold, or back to just set.
CREATE OR REPLACE FUNCTION public.rp_set_appointment_state(p_id uuid, p_state text, p_on date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; v_state text := lower(btrim(COALESCE(p_state,'')));
        v_on date := COALESCE(p_on, public.rp_today_central());
BEGIN
  SELECT * INTO r FROM public.appointment_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that appointment was removed. Log it again instead.'; END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
  IF v_on > public.rp_today_central() THEN RAISE EXCEPTION 'the date cannot be in the future'; END IF;
  IF v_on < r.set_on THEN RAISE EXCEPTION 'that is before the appointment was set (%)', r.set_on; END IF;

  IF v_state = 'kept' THEN
    UPDATE public.appointment_log SET kept_on = v_on, no_show_on = NULL, updated_at = now() WHERE id = p_id;
  ELSIF v_state = 'no_show' THEN
    UPDATE public.appointment_log SET no_show_on = v_on, kept_on = NULL, sold_on = NULL, updated_at = now() WHERE id = p_id;
  ELSIF v_state = 'sold' THEN
    -- A sold appointment was kept. Fill the kept date if nobody marked it.
    UPDATE public.appointment_log SET sold_on = v_on, kept_on = COALESCE(kept_on, v_on),
           no_show_on = NULL, updated_at = now() WHERE id = p_id;
  ELSIF v_state = 'open' THEN
    UPDATE public.appointment_log SET kept_on = NULL, no_show_on = NULL, sold_on = NULL, updated_at = now() WHERE id = p_id;
  ELSE
    RAISE EXCEPTION 'unknown state: %', p_state;
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id, 'state', v_state);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_edit_appointment(p_id uuid, p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb); v_on date;
BEGIN
  SELECT * INTO r FROM public.appointment_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that appointment was removed. Log it again instead.'; END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
  v_on := COALESCE(NULLIF(c->>'set_on','')::date, r.set_on);
  IF v_on > public.rp_today_central() THEN RAISE EXCEPTION 'the date cannot be in the future'; END IF;
  IF c ? 'phone_last4' AND regexp_replace(COALESCE(c->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;
  UPDATE public.appointment_log SET
    customer_first_name   = CASE WHEN c ? 'customer_first' THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN c ? 'customer_last_initial' THEN upper(btrim(c->>'customer_last_initial')) ELSE customer_last_initial END,
    customer_label        = CASE WHEN c ? 'customer_first' OR c ? 'customer_last_initial'
                                 THEN public.rp_customer_label(COALESCE(c->>'customer_first', customer_first_name),
                                                               COALESCE(c->>'customer_last_initial', customer_last_initial))
                                 ELSE customer_label END,
    phone_last4 = CASE WHEN c ? 'phone_last4' THEN regexp_replace(c->>'phone_last4','\D','','g') ELSE phone_last4 END,
    escalated_to_team_member_id = CASE WHEN c ? 'escalated_to_team_member_id'
                                       THEN NULLIF(c->>'escalated_to_team_member_id','')::uuid
                                       ELSE escalated_to_team_member_id END,
    set_on = v_on,
    week_end_date = public.rp_week_end(v_on),
    note     = CASE WHEN c ? 'note' THEN NULLIF(btrim(COALESCE(c->>'note','')),'') ELSE note END,
    ecrm_url = CASE WHEN c ? 'ecrm_url' THEN NULLIF(btrim(COALESCE(c->>'ecrm_url','')),'') ELSE ecrm_url END,
    updated_at = now()
  WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_void_appointment(p_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD;
BEGIN
  SELECT * INTO r FROM public.appointment_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
  UPDATE public.appointment_log
     SET status = 'void', voided_at = now(), voided_by = auth.uid(), void_reason = p_reason, updated_at = now()
   WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

-- One delete door for every record kind (no parallel delete paths).
CREATE OR REPLACE FUNCTION public.rp_delete_record(p_kind text, p_id uuid, p_reason text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; v_kind text := lower(btrim(COALESCE(p_kind, '')));
BEGIN
  IF v_kind = 'sale'        THEN RETURN public.rp_void_sale(p_id, p_reason); END IF;
  IF v_kind = 'quote'       THEN RETURN public.rp_void_quote(p_id, p_reason); END IF;
  IF v_kind = 'activity'    THEN RETURN public.rp_void_activity(p_id, p_reason); END IF;
  IF v_kind = 'cancelation' THEN RETURN public.rp_void_cancelation(p_id, p_reason); END IF;
  IF v_kind = 'appointment' THEN RETURN public.rp_void_appointment(p_id, p_reason); END IF;
  IF v_kind = 'scorecard'   THEN
    SELECT * INTO r FROM public.fit_scorecards WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
    SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, public.rp_week_end(r.scorecard_date), r.created_at);
    IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
    DELETE FROM public.fit_scorecards WHERE id = p_id;
    RETURN jsonb_build_object('ok', true, 'id', p_id);
  END IF;
  RAISE EXCEPTION 'unknown record type: %', p_kind;
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_log_appointment(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_set_appointment_state(uuid, text, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_edit_appointment(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_void_appointment(uuid, text) TO authenticated;
