-- Peter rulings 2026-09-11 and 2026-09-13 on appointments, two of which the
-- 2026-09-14 build did not carry:
--   1. "An appointment record must capture ... what product it is scheduled
--      to discuss." There was no product field at all.
--   2. "The setter CANNOT mark it kept or sold - only the host can."
--      rp_set_appointment_state guarded on the setter, so the person who
--      earns the marketing points was marking their own money.
-- Point pricing is unchanged: rp_week_scoreboard_for already pays the
-- escalator, never the host. Only who may press the button changes.

ALTER TABLE public.appointment_log ADD COLUMN IF NOT EXISTS line_of_business text;
ALTER TABLE public.appointment_log ADD COLUMN IF NOT EXISTS product_type text;

COMMENT ON COLUMN public.appointment_log.line_of_business IS
  'What product the appointment is set to discuss (Peter 2026-09-11). Required on new appointments; rows logged before 2026-09-15 may be blank.';
COMMENT ON COLUMN public.appointment_log.product_type IS
  'The specific type under line_of_business, validated against product_types.';

-- ---------------------------------------------------------------------
-- Logging an appointment now takes the product.
-- ---------------------------------------------------------------------
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
  v_id uuid;
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
  INSERT INTO public.appointment_log (agency_id, team_member_id, escalated_to_team_member_id,
    customer_first_name, customer_last_initial, customer_label, phone_last4,
    line_of_business, product_type,
    set_on, week_end_date, note, ecrm_url, created_by)
  VALUES (a.agency_id, a.team_member_id, v_to, v_first, v_init,
    public.rp_customer_label(v_first, v_init), regexp_replace(p->>'phone_last4','\D','','g'),
    v_lob, v_type,
    v_on, public.rp_week_end(v_on),
    NULLIF(btrim(COALESCE(p->>'note','')),''), NULLIF(btrim(COALESCE(p->>'ecrm_url','')),''),
    auth.uid())
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'customer', public.rp_customer_label(v_first, v_init));
END $function$;

-- ---------------------------------------------------------------------
-- Editing an appointment can change the product.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rp_edit_appointment(p_id uuid, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb); v_on date;
        v_lob text; v_type text;
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
  v_lob  := CASE WHEN c ? 'line_of_business' THEN lower(btrim(COALESCE(c->>'line_of_business',''))) ELSE r.line_of_business END;
  v_type := CASE WHEN c ? 'product_type' THEN NULLIF(btrim(COALESCE(c->>'product_type','')),'')
                 WHEN c ? 'line_of_business' THEN NULL ELSE r.product_type END;
  IF c ? 'line_of_business' OR c ? 'product_type' THEN
    IF v_lob NOT IN ('auto','fire','life','health','variable','bank') THEN
      RAISE EXCEPTION 'what product is the appointment about?';
    END IF;
    PERFORM public.rp_check_product_type(r.agency_id, v_lob, v_type);
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
    line_of_business = v_lob,
    product_type     = v_type,
    set_on = v_on,
    week_end_date = public.rp_week_end(v_on),
    note     = CASE WHEN c ? 'note' THEN NULLIF(btrim(COALESCE(c->>'note','')),'') ELSE note END,
    ecrm_url = CASE WHEN c ? 'ecrm_url' THEN NULLIF(btrim(COALESCE(c->>'ecrm_url','')),'') ELSE ecrm_url END,
    updated_at = now()
  WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;

-- ---------------------------------------------------------------------
-- Only the host moves an appointment along.
-- The person the appointment was handed to marks it kept, a no show, or
-- sold. The setter cannot: they are the one who gets paid for it, so
-- letting them mark their own appointment sold is marking their own pay.
-- An appointment nobody handed over belongs to the person who set it, so
-- they mark that one themselves.
-- rp_guard_change is still the one permission rule; it is simply asked
-- about the host instead of the setter.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rp_set_appointment_state(p_id uuid, p_state text, p_on date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; v_state text := lower(btrim(COALESCE(p_state,'')));
        v_on date := COALESCE(p_on, public.rp_today_central());
        v_host uuid;
BEGIN
  SELECT * INTO r FROM public.appointment_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that appointment was removed. Log it again instead.'; END IF;
  v_host := COALESCE(NULLIF(r.escalated_to_team_member_id, r.team_member_id), r.team_member_id);
  BEGIN
    SELECT * INTO a FROM public.rp_guard_change(v_host, r.week_end_date, r.created_at);
  EXCEPTION WHEN insufficient_privilege THEN
    IF v_host <> r.team_member_id THEN
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
