-- A save carries the policy line at risk and the reason the customer gave in
-- save_line and save_reason. rp_edit_activity could not touch either, so the edit
-- form would show them, accept a change, and quietly save nothing. Both keys now
-- go through, same merge rule as every other key: only what is sent is applied.
CREATE OR REPLACE FUNCTION public.rp_edit_activity(p_id uuid, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb);
        v_today date := public.rp_today_central(); v_on date;
BEGIN
  SELECT * INTO r FROM public.retention_activity_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status = 'void' THEN RAISE EXCEPTION 'that entry was removed. Log it again instead.'; END IF;
  IF r.source <> 'manual' THEN RAISE EXCEPTION 'this credit came from a sale entry — change the sale instead'; END IF;
  IF c ? 'activity_key' AND c->>'activity_key' IS DISTINCT FROM r.activity_key THEN
    RAISE EXCEPTION 'to change which activity it was, remove this one and log the right one';
  END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;

  v_on := COALESCE(NULLIF(c->>'occurred_on','')::date, r.occurred_on);
  IF v_on > v_today THEN RAISE EXCEPTION 'the date cannot be in the future'; END IF;
  IF c ? 'phone_last4' AND regexp_replace(COALESCE(c->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;

  UPDATE public.retention_activity_log SET
    customer_first_name   = CASE WHEN c ? 'customer_first'        THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN c ? 'customer_last_initial' THEN upper(btrim(c->>'customer_last_initial')) ELSE customer_last_initial END,
    customer_label        = CASE WHEN c ? 'customer_first' OR c ? 'customer_last_initial'
                                 THEN public.rp_customer_label(COALESCE(c->>'customer_first', customer_first_name),
                                                               COALESCE(c->>'customer_last_initial', customer_last_initial))
                                 ELSE customer_label END,
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
    updated_at = now()
  WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;