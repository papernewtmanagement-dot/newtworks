CREATE OR REPLACE FUNCTION public.rp_edit_activity(p_id uuid, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb);
        v_today date := public.rp_today_central(); v_on date; v_kind text; v_who boolean;
BEGIN
  PERFORM public.require_login('staff');
  SELECT * INTO r FROM public.retention_activity_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status = 'void' THEN RAISE EXCEPTION 'that entry was removed. Log it again instead.'; END IF;
  IF r.source <> 'manual' THEN RAISE EXCEPTION 'this credit came from a sale entry — change the sale instead'; END IF;
  IF c ? 'activity_key' AND c->>'activity_key' IS DISTINCT FROM r.activity_key THEN
    RAISE EXCEPTION 'to change which activity it was, remove this one and log the right one';
  END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;

  v_kind := CASE WHEN c ? 'customer_kind' THEN public.rp_customer_kind(c->>'customer_kind') ELSE r.customer_kind END;
  v_who  := (c ? 'customer_first') OR (c ? 'customer_last_initial') OR (c ? 'customer_kind');

  v_on := COALESCE(NULLIF(c->>'occurred_on','')::date, r.occurred_on);
  IF v_on > v_today THEN RAISE EXCEPTION 'the date cannot be in the future'; END IF;
  IF c ? 'phone_last4' AND regexp_replace(COALESCE(c->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;

  IF v_who THEN
    PERFORM public.rp_customer_label(COALESCE(c->>'customer_first', r.customer_first_name), COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind);
  END IF;
  UPDATE public.retention_activity_log SET
    customer_kind         = v_kind,
    customer_first_name   = CASE WHEN c ? 'customer_first' THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN v_who
                                 THEN public.rp_customer_initial(COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind)
                                 ELSE customer_last_initial END,
    phone_last4 = CASE WHEN c ? 'phone_last4' THEN regexp_replace(c->>'phone_last4','\D','','g') ELSE phone_last4 END,
    occurred_on = v_on,
    week_end_date = public.rp_week_end(v_on),
    credited_week_end_date = CASE WHEN credited_week_end_date IS NULL THEN NULL ELSE public.rp_week_end(v_on) END,
    ecrm_url = CASE WHEN c ? 'ecrm_url' THEN NULLIF(btrim(COALESCE(c->>'ecrm_url','')),'') ELSE ecrm_url END,
    note     = CASE WHEN c ? 'note' THEN NULLIF(btrim(COALESCE(c->>'note','')),'') ELSE note END,
    policy_line  = CASE WHEN c ? 'policy_line'  THEN NULLIF(lower(btrim(COALESCE(c->>'policy_line',''))),'') ELSE policy_line END,
    product_type = CASE WHEN c ? 'product_type' THEN NULLIF(btrim(COALESCE(c->>'product_type','')),'') ELSE product_type END,
    premium      = CASE WHEN c ? 'premium' THEN NULLIF(c->>'premium','')::numeric ELSE premium END,
    save_line    = CASE WHEN c ? 'save_line'   THEN NULLIF(lower(btrim(COALESCE(c->>'save_line',''))),'') ELSE save_line END,
    save_reason  = CASE WHEN c ? 'save_reason' THEN NULLIF(btrim(COALESCE(c->>'save_reason','')),'') ELSE save_reason END,
    review_platform = CASE WHEN c ? 'review_platform' THEN NULLIF(lower(btrim(COALESCE(c->>'review_platform',''))),'') ELSE review_platform END,
    updated_at = now()
  WHERE id = p_id;
  -- Peter 2026-10-03: a required field cannot be CLEARED by an edit, but an edit
  -- never demands one the record did not have (older rows logged before a rule).
  -- The link cannot be cleared off something that requires it.
  IF EXISTS (SELECT 1 FROM public.retention_activity_log l
               JOIN public.retention_point_values v
                 ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
              WHERE l.id = p_id AND v.requires_ecrm AND l.ecrm_url IS NULL AND r.ecrm_url IS NOT NULL) THEN
    RAISE EXCEPTION 'this one needs the ECRM link, so it cannot be cleared';
  END IF;
  IF EXISTS (SELECT 1 FROM public.retention_activity_log l
               JOIN public.retention_point_values v
                 ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
              WHERE l.id = p_id AND v.requires_platform AND l.review_platform IS NULL AND r.review_platform IS NOT NULL) THEN
    RAISE EXCEPTION 'this one needs the site the review was left on, so it cannot be cleared';
  END IF;
  -- Same for the note. It is required when the entry is logged, so an edit
  -- must not be able to empty it out afterwards (Peter 2026-09-20).
  IF EXISTS (SELECT 1 FROM public.retention_activity_log l
               JOIN public.retention_point_values v
                 ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
              WHERE l.id = p_id AND v.requires_note
                AND l.note IS NULL AND l.save_reason IS NULL
                AND (r.note IS NOT NULL OR r.save_reason IS NOT NULL)) THEN
    RAISE EXCEPTION 'this one needs a note on what you covered, so it cannot be cleared';
  END IF;
  -- The line on a pivot and the policy on a review cannot be cleared either.
  IF r.activity_key IN ('pivot', 'policy_review') AND EXISTS (SELECT 1 FROM public.retention_activity_log l
       WHERE l.id = p_id AND ((r.policy_line IS NOT NULL AND l.policy_line IS NULL)
                           OR (r.activity_key = 'policy_review' AND r.product_type IS NOT NULL AND l.product_type IS NULL))) THEN
    RAISE EXCEPTION '%', CASE WHEN r.activity_key = 'pivot' THEN 'a pivot needs the line it pivoted to, so it cannot be cleared'
                              ELSE 'a policy review needs the policy reviewed, so it cannot be cleared' END;
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$

