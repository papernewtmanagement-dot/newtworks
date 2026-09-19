-- Peter 2026-09-19: the flagged entries on the spot-check are cancelations
-- that were filed as something else. This turns one into the real thing from
-- that tab: it writes a cancelation per policy that went, credited to the
-- person who logged the activity, then removes the misnamed activity.
--
-- It calls rp_log_cancelation and rp_void_activity rather than writing rows
-- itself, so the chargeback, the save voiding, the 90-day limit and the 0.50
-- logging credit all behave exactly as they do everywhere else.
--
-- The policy line has to come from the screen. A note saying "cancelled both
-- auto and home" names two lines and no premium, and the database will not
-- guess either.

CREATE OR REPLACE FUNCTION public.rp_convert_activity_to_cancelation(
  p_activity_id uuid,
  p_policies jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; l RECORD; item jsonb; res jsonb; v_ids uuid[] := '{}'; v_void jsonb;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'only an admin can turn an entry into a cancelation'; END IF;

  SELECT * INTO l FROM public.retention_activity_log
   WHERE id = p_activity_id AND agency_id = a.agency_id AND status = 'credited';
  IF NOT FOUND THEN RAISE EXCEPTION 'that entry is not on file any more'; END IF;

  IF p_policies IS NULL OR jsonb_typeof(p_policies) <> 'array' OR jsonb_array_length(p_policies) = 0 THEN
    RAISE EXCEPTION 'pick at least one policy that canceled';
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_policies) LOOP
    res := public.rp_log_cancelation(jsonb_build_object(
      'team_member_id', l.team_member_id,
      'canceled_on', l.occurred_on,
      'customer_first', l.customer_first_name,
      'customer_last_initial', l.customer_last_initial,
      'policy_line', item->>'policy_line',
      'product_type', item->>'product_type',
      'premium', item->>'premium',
      'vehicle_count', item->>'vehicle_count',
      'matched_sale_product_id', item->>'matched_sale_product_id',
      'reason', COALESCE(NULLIF(btrim(COALESCE(item->>'reason','')), ''), 'other'),
      'note', l.note
    ));
    v_ids := v_ids || (res->>'cancelation_id')::uuid;
  END LOOP;

  v_void := public.rp_void_activity(p_activity_id, 'spot-check: this was a cancelation, not a ' ||
    COALESCE((SELECT v.label FROM public.retention_point_values v
               WHERE v.agency_id = a.agency_id AND v.activity_key = l.activity_key), l.activity_key));

  RETURN jsonb_build_object('ok', true, 'cancelation_ids', to_jsonb(v_ids),
                            'count', array_length(v_ids, 1), 'customer', l.customer_label);
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_convert_activity_to_cancelation(uuid, jsonb) TO authenticated;
