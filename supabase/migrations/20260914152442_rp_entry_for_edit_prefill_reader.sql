-- One record, shaped for the entry form to open prefilled. The page reads this, changes what
-- it needs, and hands the changed keys back to the matching rp_edit_* function. Keeping the
-- read here means the browser never needs its own row-level access to the seven Production
-- tables, and the agency scope is checked in one place.
CREATE OR REPLACE FUNCTION public.rp_entry_for_edit(p_kind text, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; v_kind text := lower(btrim(COALESCE(p_kind, ''))); v_out jsonb;
  v_week date := public.rp_week_end(public.rp_today_central());
  v_today timestamptz := public.rp_today_central()::timestamptz;
  s RECORD; q RECORD; c RECORD; l RECORD; f RECORD;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);

  IF v_kind = 'sale' THEN
    SELECT * INTO s FROM public.sales_log WHERE id = p_id AND agency_id = a.agency_id AND status = 'active';
    IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
    v_out := jsonb_build_object(
      'kind', 'sale', 'id', s.id, 'team_member_id', s.team_member_id,
      'customer_first', s.customer_first_name, 'customer_last_initial', s.customer_last_initial,
      'phone_last4', s.phone_last4, 'date', s.submitted_date,
      'relationship', s.household_status, 'marketing_source', s.marketing_source,
      'sourced_by_team_member_id', s.sourced_by_team_member_id,
      'ecrm_url', s.ecrm_opportunity_url, 'note', s.note,
      'entry_source', COALESCE(s.entry_source, 'manual'),
      'week_end_date', s.week_end_date, 'created_at', s.created_at,
      'products', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', p.id, 'line_of_business', p.line_of_business,
                 'product_type', p.product_type, 'premium', p.premium, 'policy_count', p.policy_count,
                 'vehicle_count', p.vehicle_count, 'is_new_line', p.is_new_line,
                 'issued_date', p.issued_date, 'issued_premium', p.issued_premium,
                 'autopay', p.autopay_enrolled) ORDER BY p.created_at, p.id)
          FROM public.sales_log_products p WHERE p.sales_log_id = s.id), '[]'::jsonb));

  ELSIF v_kind = 'quote' THEN
    SELECT * INTO q FROM public.quote_log WHERE id = p_id AND agency_id = a.agency_id AND status = 'active';
    IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
    v_out := jsonb_build_object(
      'kind', 'quote', 'id', q.id, 'team_member_id', q.team_member_id,
      'customer_first', q.customer_first_name, 'customer_last_initial', q.customer_last_initial,
      'phone_last4', q.phone_last4, 'date', q.quote_date,
      'relationship', q.relationship_type, 'marketing_source', q.marketing_source,
      'sourced_by_team_member_id', q.sourced_by_team_member_id,
      'ecrm_url', q.ecrm_opportunity_url, 'note', q.note,
      'entry_source', 'manual', 'week_end_date', q.week_end_date, 'created_at', q.created_at,
      'products', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', p.id, 'line_of_business', p.line_of_business,
                 'product_type', p.product_type) ORDER BY p.created_at, p.id)
          FROM public.quote_log_products p WHERE p.quote_log_id = q.id), '[]'::jsonb));

  ELSIF v_kind = 'cancelation' THEN
    SELECT * INTO c FROM public.cancelation_log WHERE id = p_id AND agency_id = a.agency_id AND status = 'active';
    IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
    v_out := jsonb_build_object(
      'kind', 'cancelation', 'id', c.id, 'team_member_id', c.team_member_id,
      'customer_first', c.customer_first_name, 'customer_last_initial', c.customer_last_initial,
      'phone_last4', c.phone_last4, 'date', c.canceled_on,
      'policy_line', c.policy_line, 'product_type', c.product_type,
      'premium', c.premium, 'vehicle_count', c.vehicle_count, 'reason', c.reason, 'note', c.note,
      'entry_source', 'manual', 'week_end_date', c.week_end_date, 'created_at', c.created_at,
      'products', '[]'::jsonb);

  ELSIF v_kind = 'activity' THEN
    SELECT * INTO l FROM public.retention_activity_log WHERE id = p_id AND agency_id = a.agency_id AND status <> 'void';
    IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
    v_out := jsonb_build_object(
      'kind', 'activity', 'id', l.id, 'team_member_id', l.team_member_id,
      'customer_first', l.customer_first_name, 'customer_last_initial', l.customer_last_initial,
      'phone_last4', l.phone_last4, 'date', l.occurred_on,
      'activity_key', l.activity_key, 'note', l.note, 'ecrm_url', l.ecrm_url,
      'save_line', l.save_line, 'save_reason', l.save_reason,
      'policy_line', l.policy_line, 'product_type', l.product_type, 'premium', l.premium,
      'points', l.points,
      'entry_source', 'manual', 'week_end_date', l.week_end_date, 'created_at', l.created_at,
      'products', '[]'::jsonb);

  ELSIF v_kind = 'scorecard' THEN
    SELECT * INTO f FROM public.fit_scorecards WHERE id = p_id AND agency_id = a.agency_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'not found'; END IF;
    v_out := jsonb_build_object(
      'kind', 'scorecard', 'id', f.id, 'team_member_id', f.team_member_id,
      'customer_first', f.customer_first_name, 'customer_last_initial', NULL,
      'phone_last4', f.phone_last4, 'date', f.scorecard_date,
      'recording_turned_in', f.recording_turned_in, 'recording_url', f.recording_url,
      'note', f.notes, 'entry_source', 'manual',
      'week_end_date', public.rp_week_end(f.scorecard_date), 'created_at', f.created_at,
      'scores', jsonb_build_object(
        'demeanor_score', f.demeanor_score, 'frogs_score', f.frogs_score, 'intro_score', f.intro_score,
        'eligibility_score', f.eligibility_score, 'setup_gnc_score', f.setup_gnc_score,
        'uncover_gap_score', f.uncover_gap_score, 'bridge_gap_score', f.bridge_gap_score,
        'customize_close_score', f.customize_close_score, 'set_followup_score', f.set_followup_score,
        'review_referral_score', f.review_referral_score),
      'products', '[]'::jsonb);
  ELSE
    RAISE EXCEPTION 'unknown record type: %', p_kind;
  END IF;

  RETURN v_out || jsonb_build_object('can_change',
    (a.is_admin OR ((v_out->>'team_member_id')::uuid = a.actor_id
                    AND ((v_out->>'week_end_date')::date >= v_week
                         OR (v_out->>'created_at')::timestamptz >= v_today))));
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_entry_for_edit(text, uuid) TO anon, authenticated;
