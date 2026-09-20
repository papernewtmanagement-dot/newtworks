-- Editing a record can switch it between a person and an organization. When it
-- switches, the initial and the label are rebuilt by the same two functions the
-- logging path uses. Nothing here builds a label of its own.

CREATE OR REPLACE FUNCTION public.rp_edit_activity(p_id uuid, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb);
        v_today date := public.rp_today_central(); v_on date; v_kind text; v_who boolean;
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

  v_kind := CASE WHEN c ? 'customer_kind' THEN public.rp_customer_kind(c->>'customer_kind') ELSE r.customer_kind END;
  v_who  := (c ? 'customer_first') OR (c ? 'customer_last_initial') OR (c ? 'customer_kind');

  v_on := COALESCE(NULLIF(c->>'occurred_on','')::date, r.occurred_on);
  IF v_on > v_today THEN RAISE EXCEPTION 'the date cannot be in the future'; END IF;
  IF c ? 'phone_last4' AND regexp_replace(COALESCE(c->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;

  UPDATE public.retention_activity_log SET
    customer_kind         = v_kind,
    customer_first_name   = CASE WHEN c ? 'customer_first' THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN v_who
                                 THEN public.rp_customer_initial(COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind)
                                 ELSE customer_last_initial END,
    customer_label        = CASE WHEN v_who
                                 THEN public.rp_customer_label(COALESCE(c->>'customer_first', r.customer_first_name),
                                                               COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind)
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
    review_platform = CASE WHEN c ? 'review_platform' THEN NULLIF(lower(btrim(COALESCE(c->>'review_platform',''))),'') ELSE review_platform END,
    updated_at = now()
  WHERE id = p_id;
  -- The link cannot be cleared off something that requires it.
  IF EXISTS (SELECT 1 FROM public.retention_activity_log l
               JOIN public.retention_point_values v
                 ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
              WHERE l.id = p_id AND v.requires_ecrm AND l.ecrm_url IS NULL) THEN
    RAISE EXCEPTION 'this one needs the ECRM link, so it cannot be cleared';
  END IF;
  IF EXISTS (SELECT 1 FROM public.retention_activity_log l
               JOIN public.retention_point_values v
                 ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
              WHERE l.id = p_id AND v.requires_platform AND l.review_platform IS NULL) THEN
    RAISE EXCEPTION 'this one needs the site the review was left on, so it cannot be cleared';
  END IF;
  -- Same for the note. It is required when the entry is logged, so an edit
  -- must not be able to empty it out afterwards (Peter 2026-09-20).
  IF EXISTS (SELECT 1 FROM public.retention_activity_log l
               JOIN public.retention_point_values v
                 ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
              WHERE l.id = p_id AND v.requires_note
                AND l.note IS NULL AND l.save_reason IS NULL) THEN
    RAISE EXCEPTION 'this one needs a note on what you covered, so it cannot be cleared';
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;


CREATE OR REPLACE FUNCTION public.rp_edit_quote(p_id uuid, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb);
        v_today date := public.rp_today_central(); v_on date; prod jsonb; v_lob text;
        v_kind text; v_who boolean;
BEGIN
  SELECT * INTO r FROM public.quote_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that quote was removed. Log it again instead.'; END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;

  v_kind := CASE WHEN c ? 'customer_kind' THEN public.rp_customer_kind(c->>'customer_kind') ELSE r.customer_kind END;
  v_who  := (c ? 'customer_first') OR (c ? 'customer_last_initial') OR (c ? 'customer_kind');

  v_on := COALESCE(NULLIF(c->>'quote_date','')::date, r.quote_date);
  IF v_on > v_today THEN RAISE EXCEPTION 'quote date cannot be in the future'; END IF;
  IF c ? 'relationship_type' AND lower(COALESCE(c->>'relationship_type','')) NOT IN ('new','existing','winback') THEN
    RAISE EXCEPTION 'pick the relationship type: new, existing, or winback';
  END IF;
  IF c ? 'marketing_source' AND NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources
      WHERE agency_id=r.agency_id AND source_key=c->>'marketing_source' AND is_active) THEN
    RAISE EXCEPTION 'pick the marketing source';
  END IF;
  IF c ? 'phone_last4' AND regexp_replace(COALESCE(c->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;

  UPDATE public.quote_log SET
    customer_kind         = v_kind,
    customer_first_name   = CASE WHEN c ? 'customer_first' THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN v_who
                                 THEN public.rp_customer_initial(COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind)
                                 ELSE customer_last_initial END,
    customer_label        = CASE WHEN v_who
                                 THEN public.rp_customer_label(COALESCE(c->>'customer_first', r.customer_first_name),
                                                               COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind)
                                 ELSE customer_label END,
    phone_last4           = CASE WHEN c ? 'phone_last4' THEN regexp_replace(c->>'phone_last4','\D','','g') ELSE phone_last4 END,
    quote_date            = v_on,
    week_end_date         = public.rp_week_end(v_on),
    relationship_type     = CASE WHEN c ? 'relationship_type' THEN lower(c->>'relationship_type') ELSE relationship_type END,
    marketing_source      = CASE WHEN c ? 'marketing_source' THEN c->>'marketing_source' ELSE marketing_source END,
    sourced_by_team_member_id = CASE WHEN c ? 'sourced_by_team_member_id' THEN NULLIF(c->>'sourced_by_team_member_id','')::uuid ELSE sourced_by_team_member_id END,
    ecrm_opportunity_url  = CASE WHEN c ? 'ecrm_opportunity_url' THEN NULLIF(btrim(COALESCE(c->>'ecrm_opportunity_url','')),'') ELSE ecrm_opportunity_url END,
    note                  = CASE WHEN c ? 'note' THEN NULLIF(btrim(COALESCE(c->>'note','')),'') ELSE note END,
    updated_at            = now()
  WHERE id = p_id;

  IF c ? 'products' THEN
    IF jsonb_typeof(c->'products') <> 'array' OR jsonb_array_length(c->'products') = 0 THEN
      RAISE EXCEPTION 'a quote needs at least one product';
    END IF;
    FOR prod IN SELECT * FROM jsonb_array_elements(c->'products') LOOP
      v_lob := lower(COALESCE(prod->>'line_of_business',''));
      IF v_lob NOT IN ('auto','fire','life','health','variable','bank') THEN RAISE EXCEPTION 'unknown product: %', v_lob; END IF;
      PERFORM public.rp_check_product_type(r.agency_id, v_lob, prod->>'product_type');
    END LOOP;
    DELETE FROM public.quote_log_products WHERE quote_log_id = p_id;
    INSERT INTO public.quote_log_products (quote_log_id, agency_id, line_of_business, product_type)
    SELECT p_id, r.agency_id, lower(x->>'line_of_business'),
           public.rp_check_product_type(r.agency_id, lower(x->>'line_of_business'), x->>'product_type')
      FROM jsonb_array_elements(c->'products') x;
    UPDATE public.quote_log SET products_discussed = (
      SELECT array_agg(DISTINCT lower(x->>'line_of_business')) FROM jsonb_array_elements(c->'products') x
    ) WHERE id = p_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;


CREATE OR REPLACE FUNCTION public.rp_edit_cancelation(p_id uuid, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb); v_kind text; v_who boolean;
BEGIN
  SELECT * INTO r FROM public.cancelation_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that cancelation was removed. Log it again instead.'; END IF;
  IF (c ? 'canceled_on' AND NULLIF(c->>'canceled_on','')::date IS DISTINCT FROM r.canceled_on)
     OR (c ? 'policy_line' AND lower(c->>'policy_line') IS DISTINCT FROM r.policy_line) THEN
    RAISE EXCEPTION 'to change the cancelation date or the policy line, remove this one and log it again — the chargeback is worked out from both';
  END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;

  v_kind := CASE WHEN c ? 'customer_kind' THEN public.rp_customer_kind(c->>'customer_kind') ELSE r.customer_kind END;
  v_who  := (c ? 'customer_first') OR (c ? 'customer_last_initial') OR (c ? 'customer_kind');

  UPDATE public.cancelation_log SET
    customer_kind         = v_kind,
    customer_first_name   = CASE WHEN c ? 'customer_first' THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN v_who
                                 THEN public.rp_customer_initial(COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind)
                                 ELSE customer_last_initial END,
    customer_label        = CASE WHEN v_who
                                 THEN public.rp_customer_label(COALESCE(c->>'customer_first', r.customer_first_name),
                                                               COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind)
                                 ELSE customer_label END,
    phone_last4  = CASE WHEN c ? 'phone_last4' THEN regexp_replace(c->>'phone_last4','\D','','g') ELSE phone_last4 END,
    product_type = CASE WHEN c ? 'product_type' THEN NULLIF(btrim(COALESCE(c->>'product_type','')),'') ELSE product_type END,
    premium      = CASE WHEN c ? 'premium' THEN NULLIF(c->>'premium','')::numeric ELSE premium END,
    vehicle_count= CASE WHEN c ? 'vehicle_count' THEN NULLIF(c->>'vehicle_count','')::integer ELSE vehicle_count END,
    reason       = CASE WHEN c ? 'reason' THEN NULLIF(btrim(COALESCE(c->>'reason','')),'') ELSE reason END,
    note         = CASE WHEN c ? 'note' THEN NULLIF(btrim(COALESCE(c->>'note','')),'') ELSE note END,
    updated_at   = now()
  WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'id', p_id);
END $function$;


CREATE OR REPLACE FUNCTION public.rp_edit_appointment(p_id uuid, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb); v_on date;
        v_lob text; v_type text; v_starts timestamptz; v_mins int; v_video boolean;
        v_where text; v_cal jsonb; v_kind text; v_who boolean;
        OFFICE constant text := '28120 US Hwy 281 N, Suite 125, San Antonio, TX 78260';
BEGIN
  SELECT * INTO r FROM public.appointment_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that appointment was removed. Log it again instead.'; END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;

  v_kind := CASE WHEN c ? 'customer_kind' THEN public.rp_customer_kind(c->>'customer_kind') ELSE r.customer_kind END;
  v_who  := (c ? 'customer_first') OR (c ? 'customer_last_initial') OR (c ? 'customer_kind');

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
  v_starts := CASE WHEN c ? 'starts_at' THEN NULLIF(c->>'starts_at','')::timestamptz ELSE r.starts_at END;
  IF c ? 'starts_at' AND v_starts IS NULL THEN RAISE EXCEPTION 'when is the appointment?'; END IF;
  v_mins  := CASE WHEN c ? 'duration_minutes'
                  THEN GREATEST(15, LEAST(240, COALESCE(NULLIF(c->>'duration_minutes','')::int, 30)))
                  ELSE COALESCE(r.duration_minutes, 30) END;
  v_video := CASE WHEN c ? 'is_video' THEN COALESCE((c->>'is_video')::boolean, false) ELSE COALESCE(r.is_video, false) END;
  v_where := CASE WHEN v_video THEN 'Google Meet' ELSE OFFICE END;

  UPDATE public.appointment_log SET
    customer_kind         = v_kind,
    customer_first_name   = CASE WHEN c ? 'customer_first' THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN v_who
                                 THEN public.rp_customer_initial(COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind)
                                 ELSE customer_last_initial END,
    customer_label        = CASE WHEN v_who
                                 THEN public.rp_customer_label(COALESCE(c->>'customer_first', r.customer_first_name),
                                                               COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind)
                                 ELSE customer_label END,
    phone_last4 = CASE WHEN c ? 'phone_last4' THEN regexp_replace(c->>'phone_last4','\D','','g') ELSE phone_last4 END,
    escalated_to_team_member_id = CASE WHEN c ? 'escalated_to_team_member_id'
                                       THEN NULLIF(c->>'escalated_to_team_member_id','')::uuid
                                       ELSE escalated_to_team_member_id END,
    line_of_business = v_lob,
    product_type     = v_type,
    starts_at        = v_starts,
    duration_minutes = v_mins,
    is_video         = v_video,
    location         = v_where,
    set_on = v_on,
    week_end_date = public.rp_week_end(v_on),
    note     = CASE WHEN c ? 'note' THEN NULLIF(btrim(COALESCE(c->>'note','')),'') ELSE note END,
    ecrm_url = CASE WHEN c ? 'ecrm_url' THEN NULLIF(btrim(COALESCE(c->>'ecrm_url','')),'') ELSE ecrm_url END,
    updated_at = now()
  WHERE id = p_id;

  v_cal := public.rp_appointment_sync_calendar(p_id);
  RETURN jsonb_build_object('ok', true, 'id', p_id) || v_cal;
END $function$;


CREATE OR REPLACE FUNCTION public.rp_edit_sale(p_id uuid, p_changes jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; r RECORD; c jsonb := COALESCE(p_changes, '{}'::jsonb);
  v_today date := public.rp_today_central(); v_on date; prod jsonb; v_keep uuid[] := ARRAY[]::uuid[];
  v_pid uuid; v_lob text; v_type text; v_blocked text; v_was text; v_added boolean; v_new boolean;
  v_ecrm text; v_source text; v_label text; v_phone text; v_note text; v_kind text; v_who boolean;
BEGIN
  SELECT * INTO r FROM public.sales_log WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
  IF r.status <> 'active' THEN RAISE EXCEPTION 'that sale was removed. Put it back first.'; END IF;
  SELECT * INTO a FROM public.rp_guard_change(r.team_member_id, r.week_end_date, r.created_at);
  IF r.agency_id <> a.agency_id THEN RAISE EXCEPTION 'not found'; END IF;
  v_was := COALESCE(r.entry_source, 'manual');

  v_kind := CASE WHEN c ? 'customer_kind' THEN public.rp_customer_kind(c->>'customer_kind') ELSE r.customer_kind END;
  v_who  := (c ? 'customer_first') OR (c ? 'customer_last_initial') OR (c ? 'customer_kind');

  v_on := COALESCE(NULLIF(c->>'submitted_date','')::date, r.submitted_date);
  IF v_on > v_today THEN RAISE EXCEPTION 'submitted date cannot be in the future'; END IF;

  IF c ? 'household_status' AND lower(COALESCE(c->>'household_status','')) NOT IN ('new','existing','winback') THEN
    RAISE EXCEPTION 'pick the relationship type: new, existing, or winback';
  END IF;
  IF c ? 'ecrm_opportunity_url' AND btrim(COALESCE(c->>'ecrm_opportunity_url','')) <> ''
     AND btrim(c->>'ecrm_opportunity_url') !~* '^https?://' THEN
    RAISE EXCEPTION 'the ECRM opportunity link must start with http';
  END IF;
  IF c ? 'marketing_source' AND NOT EXISTS (SELECT 1 FROM public.sales_marketing_sources
      WHERE agency_id=r.agency_id AND source_key=c->>'marketing_source' AND is_active) THEN
    RAISE EXCEPTION 'pick the marketing source';
  END IF;
  IF c ? 'phone_last4' AND regexp_replace(COALESCE(c->>'phone_last4',''), '\D', '', 'g') !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'customer phone, last four digits';
  END IF;

  -- What the row will hold once these changes are applied.
  v_ecrm   := NULLIF(btrim(COALESCE(NULLIF(c->>'ecrm_opportunity_url',''), r.ecrm_opportunity_url, '')), '');
  v_source := NULLIF(COALESCE(NULLIF(c->>'marketing_source',''), r.marketing_source, ''), '');
  v_note   := NULLIF(btrim(COALESCE(NULLIF(btrim(COALESCE(c->>'note','')),''), r.note, '')), '');

  IF v_ecrm IS NULL THEN
    RAISE EXCEPTION '%', CASE WHEN v_was <> 'manual'
      THEN 'Moving this into the production log needs the ECRM opportunity link.'
      ELSE 'A sale needs the ECRM opportunity link.' END;
  END IF;
  IF v_source IS NULL THEN
    RAISE EXCEPTION 'Pick the marketing source.';
  END IF;
  IF v_note IS NULL THEN
    RAISE EXCEPTION 'A sale needs a note on what happened.';
  END IF;

  UPDATE public.sales_log SET
    customer_kind         = v_kind,
    customer_first_name   = CASE WHEN c ? 'customer_first' THEN btrim(c->>'customer_first') ELSE customer_first_name END,
    customer_last_initial = CASE WHEN v_who
                                 THEN public.rp_customer_initial(COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind)
                                 ELSE customer_last_initial END,
    customer_label        = CASE WHEN v_who
                                 THEN public.rp_customer_label(COALESCE(c->>'customer_first', r.customer_first_name),
                                                               COALESCE(c->>'customer_last_initial', r.customer_last_initial), v_kind)
                                 ELSE customer_label END,
    phone_last4           = CASE WHEN c ? 'phone_last4' THEN regexp_replace(c->>'phone_last4','\D','','g') ELSE phone_last4 END,
    submitted_date        = v_on,
    week_end_date         = public.rp_week_end(v_on),
    household_status      = CASE WHEN c ? 'household_status' THEN lower(c->>'household_status') ELSE household_status END,
    ecrm_opportunity_url  = v_ecrm,
    marketing_source      = v_source,
    note                  = v_note,
    entry_source          = 'manual',
    updated_at            = now()
  WHERE id = p_id;

  SELECT customer_label, phone_last4 INTO v_label, v_phone FROM public.sales_log WHERE id = p_id;

  IF c ? 'products' THEN
    IF jsonb_typeof(c->'products') <> 'array' OR jsonb_array_length(c->'products') = 0 THEN
      RAISE EXCEPTION 'a sale needs at least one policy';
    END IF;
    FOR prod IN SELECT * FROM jsonb_array_elements(c->'products') LOOP
      PERFORM public.rp_check_sale_product(r.agency_id, prod);
      IF NULLIF(prod->>'id','') IS NOT NULL THEN v_keep := v_keep || (prod->>'id')::uuid; END IF;
    END LOOP;

    SELECT string_agg(DISTINCT p.line_of_business, ', ') INTO v_blocked
      FROM public.sales_log_products p
     WHERE p.sales_log_id = p_id AND NOT (p.id = ANY (v_keep))
       AND EXISTS (SELECT 1 FROM public.cancelation_log x WHERE x.matched_sale_product_id = p.id AND x.status = 'active');
    IF v_blocked IS NOT NULL THEN
      RAISE EXCEPTION 'the % policy has a cancelation logged against it. Remove the cancelation first.', v_blocked;
    END IF;

    UPDATE public.sales_log_products SET multiline_credit_id = NULL
     WHERE sales_log_id = p_id AND NOT (id = ANY (v_keep));
    DELETE FROM public.sales_log_products WHERE sales_log_id = p_id AND NOT (id = ANY (v_keep));

    FOR prod IN SELECT * FROM jsonb_array_elements(c->'products') LOOP
      v_lob   := lower(prod->>'line_of_business');
      v_type  := public.rp_check_product_type(r.agency_id, v_lob, prod->>'product_type');
      v_pid   := NULLIF(prod->>'id','')::uuid;
      -- ticked by the team, OR the household already has this same auto product on file
      v_added := (v_lob = 'auto' AND (
                    COALESCE((prod->>'added_to_existing')::boolean, false)
                    OR public.rp_auto_on_file(r.agency_id, v_label, v_phone, v_type, v_on, p_id)));
      v_new   := CASE WHEN v_added THEN false ELSE COALESCE((prod->>'is_new_line')::boolean, true) END;
      IF v_pid IS NULL THEN
        INSERT INTO public.sales_log_products (sales_log_id, agency_id, line_of_business, product_type, premium, policy_count, vehicle_count, is_new_line, is_added_to_existing, issued_date, issued_premium, autopay_enrolled)
        VALUES (p_id, r.agency_id, v_lob, v_type, NULLIF(prod->>'premium','')::numeric,
                GREATEST(1, COALESCE(NULLIF(prod->>'policy_count','')::integer, 1)),
                CASE WHEN v_lob='auto' THEN NULLIF(prod->>'vehicle_count','')::integer ELSE NULL END,
                v_new, v_added,
                NULLIF(prod->>'issued_date','')::date, NULLIF(prod->>'issued_premium','')::numeric,
                COALESCE((prod->>'autopay')::boolean, false));
      ELSE
        UPDATE public.sales_log_products SET
          line_of_business = v_lob, product_type = v_type,
          premium = NULLIF(prod->>'premium','')::numeric,
          policy_count = GREATEST(1, COALESCE(NULLIF(prod->>'policy_count','')::integer, 1)),
          vehicle_count = CASE WHEN v_lob='auto' THEN NULLIF(prod->>'vehicle_count','')::integer ELSE NULL END,
          is_added_to_existing = v_added,
          is_new_line = v_new,
          issued_date = CASE WHEN prod ? 'issued_date' THEN NULLIF(prod->>'issued_date','')::date ELSE issued_date END,
          issued_premium = CASE WHEN prod ? 'issued_premium' THEN NULLIF(prod->>'issued_premium','')::numeric ELSE issued_premium END,
          autopay_enrolled = CASE WHEN prod ? 'autopay' THEN COALESCE((prod->>'autopay')::boolean, false) ELSE autopay_enrolled END
        WHERE id = v_pid AND sales_log_id = p_id;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', p_id,
                            'moved_from_historical', (v_was <> 'manual'),
                            'derived', public.rp_derive_sale_credits(p_id));
END $function$;


-- The name suggestions carry the kind, so picking an organization off the list
-- sets the toggle with it instead of leaving the form on person.
DROP FUNCTION IF EXISTS public.rp_customer_suggest2(text);

CREATE FUNCTION public.rp_customer_suggest2(p_prefix text)
 RETURNS TABLE(customer_first_name text, customer_last_initial text, customer_kind text, customer_label text, phone_last4 text, policies_on_file integer, last_seen date)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  seen AS (
    SELECT s.customer_first_name, s.customer_last_initial, s.customer_kind, s.customer_label, s.phone_last4, s.submitted_date AS d, 1 AS pol
      FROM public.sales_log s JOIN me ON me.agency_id = s.agency_id WHERE s.status = 'active'
    UNION ALL
    SELECT q.customer_first_name, q.customer_last_initial, q.customer_kind, q.customer_label, q.phone_last4, q.quote_date, 0
      FROM public.quote_log q JOIN me ON me.agency_id = q.agency_id WHERE q.status = 'active'
    UNION ALL
    SELECT l.customer_first_name, l.customer_last_initial, l.customer_kind, l.customer_label, l.phone_last4, l.occurred_on, 0
      FROM public.retention_activity_log l JOIN me ON me.agency_id = l.agency_id WHERE l.status <> 'void'
    UNION ALL
    SELECT c.customer_first_name, c.customer_last_initial, c.customer_kind, c.customer_label, c.phone_last4, c.canceled_on, 0
      FROM public.cancelation_log c JOIN me ON me.agency_id = c.agency_id WHERE c.status = 'active'
  )
  SELECT customer_first_name, customer_last_initial, customer_kind, customer_label, phone_last4,
         SUM(pol)::int AS policies_on_file, MAX(d) AS last_seen
  FROM seen
  WHERE auth.uid() IS NOT NULL AND customer_label IS NOT NULL AND lower(customer_label) LIKE lower(btrim(p_prefix)) || '%'
  GROUP BY 1, 2, 3, 4, 5
  ORDER BY MAX(d) DESC, customer_label
  LIMIT 8;
$function$;

GRANT EXECUTE ON FUNCTION public.rp_customer_suggest2(text) TO authenticated, service_role;

-- The change record reads plainly: "customer type: Person to Organization".
CREATE OR REPLACE FUNCTION public.change_field_label(p_field text)
 RETURNS text LANGUAGE sql IMMUTABLE
AS $function$
  SELECT COALESCE(
    '{
      "premium":"premium","total_premium":"total premium","issued_premium":"issued premium",
      "issued_date":"issued","status":"status","void_reason":"void reason","note":"note",
      "customer_label":"customer","customer_first_name":"first name","customer_last_initial":"last initial",
      "customer_kind":"customer type",
      "marketing_source":"source","marketing_source_import":"source as imported",
      "household_status":"relationship","relationship_type":"relationship",
      "submitted_date":"submitted","quote_date":"quote date","occurred_on":"date",
      "canceled_on":"canceled on","vehicle_count":"cars","policy_count":"policies",
      "line_of_business":"line","policy_line":"line","save_line":"line","product_type":"product",
      "is_new_line":"new line","points":"points","activity_key":"activity",
      "save_reason":"save reason","reason":"reason","week_end_date":"week",
      "credited_week_end_date":"credited week","credit_available_on":"clears on",
      "products_discussed":"products discussed","is_existing_customer":"existing customer",
      "ecrm_opportunity_url":"ECRM link","ecrm_url":"ECRM link","team_member_id":"person",
      "sourced_by_team_member_id":"sourced by","saves_voided":"saves voided",
      "chargeback_points":"chargeback","is_added_to_existing":"added to a policy they had",
      "window_fraction_left":"window left","verified_at":"verified","spot_check_note":"spot-check note",
      "scorecard_date":"date","average_score":"average","recording_turned_in":"recording turned in",
      "recording_url":"recording","opportunity_ref":"opportunity","phone_last4":"phone",
      "review_platform":"review site","autopay_enrolled":"autopay","on_file_answer":"already on file",
      "referred_by_customer":"referred by","appointment_id":"appointment"
    }'::jsonb ->> p_field,
    btrim(replace(regexp_replace(p_field, '_score$', ''), '_', ' '))
  );
$function$;

CREATE OR REPLACE FUNCTION public.change_value_text(p_agency uuid, p_field text, p_value jsonb)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v text; n numeric;
BEGIN
  IF p_value IS NULL OR jsonb_typeof(p_value) = 'null' THEN RETURN 'blank'; END IF;

  IF jsonb_typeof(p_value) = 'boolean' THEN
    RETURN CASE WHEN (p_value)::text = 'true' THEN 'yes' ELSE 'no' END;
  END IF;

  IF jsonb_typeof(p_value) = 'array' THEN
    SELECT string_agg(initcap(replace(x, '_', ' ')), ', ')
      INTO v FROM jsonb_array_elements_text(p_value) AS t(x);
    RETURN COALESCE(NULLIF(v, ''), 'blank');
  END IF;

  v := CASE WHEN jsonb_typeof(p_value) = 'string' THEN p_value #>> '{}' ELSE p_value::text END;
  IF btrim(COALESCE(v, '')) = '' THEN RETURN 'blank'; END IF;

  IF p_field = 'customer_kind' THEN
    RETURN CASE WHEN lower(v) = 'org' THEN 'Organization' ELSE 'Person' END;
  END IF;

  IF p_field LIKE '%team_member_id' THEN
    RETURN COALESCE((SELECT btrim(concat_ws(' ', t.first_name, t.last_name))
                       FROM public.team_directory t WHERE t.id = v::uuid), v);
  END IF;

  IF p_field = 'activity_key' THEN
    RETURN COALESCE((SELECT pv.label FROM public.retention_point_values pv
                      WHERE pv.agency_id = p_agency AND pv.activity_key = v), v);
  END IF;

  IF p_field ~ '(premium|points)$' THEN
    BEGIN n := v::numeric; RETURN '$' || trim(to_char(n, 'FM999G999G990D00')); EXCEPTION WHEN others THEN RETURN v; END;
  END IF;

  IF p_field = 'window_fraction_left' THEN
    BEGIN n := v::numeric; RETURN round(n * 100)::text || '%'; EXCEPTION WHEN others THEN RETURN v; END;
  END IF;

  IF p_field ~ '^(line_of_business|policy_line|save_line|product_type|household_status|relationship_type|status|review_platform|marketing_source|on_file_answer)$' THEN
    RETURN initcap(replace(v, '_', ' '));
  END IF;

  IF v ~ '^\d{4}-\d{2}-\d{2}' THEN
    RETURN to_char((left(v, 10))::date, 'FMMon FMDD, YYYY');
  END IF;

  RETURN v;
END $function$;
