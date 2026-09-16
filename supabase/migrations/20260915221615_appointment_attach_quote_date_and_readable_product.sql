-- Two fixes to the pass just applied:
--   quote_log dates its rows in quote_date, not quoted_on.
--   the calendar title read the product KEY (private_passenger) rather than
--   the label a person would recognise (Private Passenger).
CREATE OR REPLACE FUNCTION public.rp_attach_entry_to_appointment(
  p_appointment_id uuid, p_sale_id uuid DEFAULT NULL, p_quote_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; v_on date; v_qon date; v_state text; v_marked boolean := false; v_why text;
BEGIN
  SELECT * INTO r FROM public.appointment_log WHERE id = p_appointment_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that appointment was removed'; END IF;
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;

  IF p_sale_id IS NOT NULL THEN
    UPDATE public.sales_log SET appointment_id = p_appointment_id, updated_at = now()
    WHERE id = p_sale_id AND agency_id = a.agency_id
    RETURNING submitted_date INTO v_on;
    IF v_on IS NOT NULL THEN v_state := 'sold'; END IF;
  END IF;
  IF p_quote_id IS NOT NULL THEN
    UPDATE public.quote_log SET appointment_id = p_appointment_id, updated_at = now()
    WHERE id = p_quote_id AND agency_id = a.agency_id
    RETURNING quote_date INTO v_qon;
    IF v_state IS NULL AND v_qon IS NOT NULL THEN v_state := 'kept'; v_on := v_qon; END IF;
  END IF;
  IF v_state IS NULL THEN RETURN jsonb_build_object('ok', true, 'marked', false); END IF;

  BEGIN
    PERFORM public.rp_set_appointment_state(p_appointment_id, v_state,
      LEAST(public.rp_today_central(), GREATEST(COALESCE(v_on, public.rp_today_central()), r.set_on)));
    v_marked := true;
  EXCEPTION WHEN OTHERS THEN
    v_why := SQLERRM;
  END;
  RETURN jsonb_build_object('ok', true, 'marked', v_marked, 'state', v_state, 'why_not', v_why);
END $function$;

CREATE OR REPLACE FUNCTION public.rp_log_appointment(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; p jsonb := COALESCE(p_payload, '{}'::jsonb);
  v_on date := COALESCE(NULLIF(p->>'set_on','')::date, public.rp_today_central());
  v_to uuid := NULLIF(p->>'escalated_to_team_member_id','')::uuid;
  v_first text := btrim(COALESCE(p->>'customer_first',''));
  v_init  text := upper(btrim(COALESCE(p->>'customer_last_initial','')));
  v_lob  text := lower(btrim(COALESCE(p->>'line_of_business','')));
  v_type text := NULLIF(btrim(COALESCE(p->>'product_type','')),'');
  v_starts timestamptz := NULLIF(p->>'starts_at','')::timestamptz;
  v_mins int := GREATEST(15, LEAST(240, COALESCE(NULLIF(p->>'duration_minutes','')::int, 30)));
  v_video boolean := COALESCE((p->>'is_video')::boolean, false);
  v_host uuid; v_label text; v_where text; v_prod text;
  v_emails text[]; v_cal jsonb; v_id uuid;
  OFFICE constant text := '28120 US Hwy 281 N, Suite 125, San Antonio, TX 78260';
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULLIF(p->>'team_member_id','')::uuid);
  IF v_on > public.rp_today_central() THEN RAISE EXCEPTION 'the date cannot be in the future'; END IF;
  IF v_first = '' THEN RAISE EXCEPTION 'who is the appointment with'; END IF;
  IF regexp_replace(COALESCE(p->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;
  IF v_lob NOT IN ('auto','fire','life','health','variable','bank') THEN
    RAISE EXCEPTION 'what product is the appointment about?';
  END IF;
  PERFORM public.rp_check_product_type(a.agency_id, v_lob, v_type);
  IF v_starts IS NULL THEN RAISE EXCEPTION 'when is the appointment?'; END IF;

  v_label := public.rp_customer_label(v_first, v_init);
  v_host  := COALESCE(NULLIF(v_to, a.team_member_id), a.team_member_id);
  v_where := CASE WHEN v_video THEN 'Google Meet' ELSE OFFICE END;
  SELECT pt.label INTO v_prod FROM public.product_types pt
   WHERE pt.agency_id = a.agency_id AND pt.line_of_business = v_lob
     AND pt.type_key = v_type AND pt.is_active;
  v_prod := COALESCE(v_prod, initcap(v_lob));

  INSERT INTO public.appointment_log (agency_id, team_member_id, escalated_to_team_member_id,
    customer_first_name, customer_last_initial, customer_label, phone_last4,
    line_of_business, product_type, starts_at, duration_minutes, is_video, location,
    set_on, week_end_date, note, ecrm_url, created_by)
  VALUES (a.agency_id, a.team_member_id, v_to, v_first, v_init, v_label,
    regexp_replace(p->>'phone_last4','\D','','g'), v_lob, v_type,
    v_starts, v_mins, v_video, v_where,
    v_on, public.rp_week_end(v_on),
    NULLIF(btrim(COALESCE(p->>'note','')),''), NULLIF(btrim(COALESCE(p->>'ecrm_url','')),''),
    auth.uid())
  RETURNING id INTO v_id;

  -- Whoever is running it, plus whoever set it, get the invite. The customer
  -- does not: we hold a first name, a last initial and four digits of a phone
  -- number, never an email address.
  SELECT array_agg(e) INTO v_emails FROM (
    SELECT DISTINCT COALESCE(t.email_sf, t.email_personal) AS e
    FROM public.team t
    WHERE t.id IN (v_host, a.team_member_id) AND COALESCE(t.email_sf, t.email_personal) IS NOT NULL
  ) s;

  v_cal := public.calendar_create_event_now(
    a.agency_id, 'primary',
    'Appointment — ' || v_label || ' (' || v_prod || ')',
    'Set in Newtworks.' || E'\n' ||
      'Customer: ' || v_label || ' ·' || regexp_replace(p->>'phone_last4','\D','','g') || E'\n' ||
      'About: ' || v_prod || E'\n' ||
      'Where: ' || v_where ||
      COALESCE(E'\n\n' || NULLIF(btrim(COALESCE(p->>'note','')),''), ''),
    v_starts, v_starts + make_interval(mins => v_mins),
    v_emails, v_where, v_video, true);

  UPDATE public.appointment_log SET
    calendar_event_id = v_cal->>'event_id',
    meet_url          = v_cal->>'meet_url',
    calendar_error    = CASE WHEN COALESCE((v_cal->>'ok')::boolean, false) THEN NULL ELSE v_cal->>'error' END
  WHERE id = v_id;

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'customer', v_label,
    'on_calendar', COALESCE((v_cal->>'ok')::boolean, false),
    'meet_url', v_cal->>'meet_url',
    'calendar_error', CASE WHEN COALESCE((v_cal->>'ok')::boolean, false) THEN NULL ELSE v_cal->>'error' END);
END $function$;
