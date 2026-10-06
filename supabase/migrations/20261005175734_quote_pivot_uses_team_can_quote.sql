CREATE OR REPLACE FUNCTION public.rp_derive_quote_pivot(p_quote_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  q public.quote_log; v_pts numeric; v_line text; v_type text; v_label text; v_note text; v_cur RECORD; v_want boolean := false;
BEGIN
  /* Peter 2026-10-05: quoting an Existing customer is the pivot for authorized team (team_can_quote). The quote writes
     one Pivot credit, to the first product quoted. Team who are not authorized log a Pivot by hand. One pivot per
     household per day, so none is written when one is already on file for that household and day.
     Weeks already paid are left alone. The one place a quote turns into a pivot. */
  SELECT * INTO q FROM public.quote_log WHERE id = p_quote_id;
  IF NOT FOUND THEN
    DELETE FROM public.retention_activity_log WHERE source = 'quote_log' AND source_id = p_quote_id AND activity_key = 'pivot';
    RETURN;
  END IF;
  IF public.week_locked_at(q.agency_id, q.week_end_date) IS NOT NULL THEN RETURN; END IF;

  v_label := public.rp_customer_label_format(q.customer_first_name, q.customer_last_initial, q.customer_kind);
  SELECT p.line_of_business, p.product_type INTO v_line, v_type
    FROM public.quote_log_products p WHERE p.quote_log_id = p_quote_id ORDER BY p.created_at, p.id LIMIT 1;
  SELECT points INTO v_pts FROM public.retention_point_values
   WHERE agency_id = q.agency_id AND activity_key = 'pivot' AND is_active;

  v_want := q.status = 'active' AND COALESCE(q.relationship_type, '') = 'existing'
    AND v_line IS NOT NULL AND v_pts IS NOT NULL
    AND public.team_can_quote(q.team_member_id)
    AND NOT EXISTS (SELECT 1 FROM public.retention_activity_log l
                     WHERE l.agency_id = q.agency_id AND l.activity_key = 'pivot' AND l.status = 'credited'
                       AND l.occurred_on = q.quote_date
                       AND NOT (l.source = 'quote_log' AND l.source_id = p_quote_id)
                       AND public.rp_customer_label_format(l.customer_first_name, l.customer_last_initial, l.customer_kind) = v_label
                       AND (l.phone_last4 IS NULL OR q.phone_last4 IS NULL OR l.phone_last4 = q.phone_last4));

  SELECT * INTO v_cur FROM public.retention_activity_log
   WHERE source = 'quote_log' AND source_id = p_quote_id AND activity_key = 'pivot' LIMIT 1;

  IF NOT v_want THEN
    IF v_cur.id IS NOT NULL THEN DELETE FROM public.retention_activity_log WHERE id = v_cur.id; END IF;
    RETURN;
  END IF;

  v_note := 'From the quote: pivoted to ' || COALESCE((SELECT pt.label FROM public.product_types pt
             WHERE pt.agency_id = q.agency_id AND pt.line_of_business = v_line AND pt.type_key = v_type), initcap(v_line));
  IF v_cur.id IS NULL THEN
    INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
      customer_first_name, customer_last_initial, customer_kind, phone_last4, ecrm_url, note, points, source, source_id, created_by,
      policy_line, product_type)
    VALUES (q.agency_id, q.team_member_id, 'pivot', q.quote_date, public.rp_week_end(q.quote_date), public.rp_week_end(q.quote_date),
      q.customer_first_name, q.customer_last_initial, q.customer_kind, q.phone_last4, q.ecrm_opportunity_url, v_note, v_pts,
      'quote_log', p_quote_id, q.created_by, v_line, v_type);
  ELSE
    UPDATE public.retention_activity_log SET
      team_member_id = q.team_member_id, occurred_on = q.quote_date,
      week_end_date = public.rp_week_end(q.quote_date), credited_week_end_date = public.rp_week_end(q.quote_date),
      customer_first_name = q.customer_first_name, customer_last_initial = q.customer_last_initial, customer_kind = q.customer_kind,
      phone_last4 = q.phone_last4, note = v_note, policy_line = v_line, product_type = v_type, updated_at = now()
     WHERE id = v_cur.id
       AND (team_member_id, occurred_on, customer_first_name, customer_last_initial, customer_kind, phone_last4, note, policy_line, product_type)
           IS DISTINCT FROM
           (q.team_member_id, q.quote_date, q.customer_first_name, q.customer_last_initial, q.customer_kind, q.phone_last4, v_note, v_line, v_type);
  END IF;
END $function$;
