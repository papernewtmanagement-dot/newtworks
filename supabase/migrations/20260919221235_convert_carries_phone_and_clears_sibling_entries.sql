-- Peter 2026-09-19, from converting the first of the flagged entries:
--
-- 1. Stephanie R. 6771 had the same cancelation typed three times as a Policy
--    Change. Converting one left the other two sitting there still paid. The
--    conversion now takes the household's other entries with it, as chosen on
--    the screen.
--
-- 2. The cancelations the conversion wrote came out with no phone last four,
--    because the conversion passed the name but not the phone. Without it the
--    household key is only half there. Fixed going forward, and put onto the
--    ones already written today from the entry each came from.

CREATE OR REPLACE FUNCTION public.rp_convert_activity_to_cancelation(
  p_activity_id uuid,
  p_policies jsonb,
  p_ecrm_url text DEFAULT NULL::text,
  p_also_void uuid[] DEFAULT '{}'::uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  a RECORD; l RECORD; item jsonb; res jsonb; v_ids uuid[] := '{}'; v_url text;
  v_other uuid; v_also integer := 0; v_reason text;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'only an admin can turn an entry into a cancelation'; END IF;

  SELECT * INTO l FROM public.retention_activity_log
   WHERE id = p_activity_id AND agency_id = a.agency_id AND status = 'credited';
  IF NOT FOUND THEN RAISE EXCEPTION 'that entry is not on file any more'; END IF;

  IF p_policies IS NULL OR jsonb_typeof(p_policies) <> 'array' OR jsonb_array_length(p_policies) = 0 THEN
    RAISE EXCEPTION 'pick at least one policy that canceled';
  END IF;

  v_url := COALESCE(NULLIF(btrim(COALESCE(l.ecrm_url, '')), ''), NULLIF(btrim(COALESCE(p_ecrm_url, '')), ''));

  FOR item IN SELECT * FROM jsonb_array_elements(p_policies) LOOP
    res := public.rp_log_cancelation(jsonb_build_object(
      'team_member_id', l.team_member_id,
      'canceled_on', l.occurred_on,
      'customer_first', l.customer_first_name,
      'customer_last_initial', l.customer_last_initial,
      'phone_last4', l.phone_last4,
      'policy_line', item->>'policy_line',
      'product_type', item->>'product_type',
      'premium', item->>'premium',
      'vehicle_count', item->>'vehicle_count',
      'matched_sale_product_id', item->>'matched_sale_product_id',
      'reason', COALESCE(NULLIF(btrim(COALESCE(item->>'reason','')), ''), 'other'),
      'note', l.note,
      'ecrm_url', v_url
    ));
    v_ids := v_ids || (res->>'cancelation_id')::uuid;
  END LOOP;

  -- The household key is the name plus the last four. rp_log_cancelation does
  -- not take the phone, so it is put on here, on the cancelation and on the
  -- logging credit the trigger wrote from it.
  IF l.phone_last4 IS NOT NULL THEN
    UPDATE public.cancelation_log SET phone_last4 = l.phone_last4
     WHERE id = ANY(v_ids) AND phone_last4 IS NULL;
    UPDATE public.retention_activity_log SET phone_last4 = l.phone_last4
     WHERE source = 'cancelation_log' AND source_id = ANY(v_ids) AND phone_last4 IS NULL;
  END IF;

  v_reason := 'spot-check: this was a cancelation, not a ' ||
    COALESCE((SELECT v.label FROM public.retention_point_values v
               WHERE v.agency_id = a.agency_id AND v.activity_key = l.activity_key), l.activity_key);

  PERFORM public.rp_void_activity(p_activity_id, v_reason);

  -- The same cancelation typed more than once for one household.
  FOREACH v_other IN ARRAY COALESCE(p_also_void, '{}'::uuid[]) LOOP
    IF v_other = p_activity_id THEN CONTINUE; END IF;
    IF EXISTS (SELECT 1 FROM public.retention_activity_log x
                WHERE x.id = v_other AND x.agency_id = a.agency_id AND x.status = 'credited') THEN
      PERFORM public.rp_void_activity(v_other, v_reason || ', and the same one as another entry');
      v_also := v_also + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'cancelation_ids', to_jsonb(v_ids),
                            'count', array_length(v_ids, 1), 'also_removed', v_also,
                            'customer', l.customer_label);
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_convert_activity_to_cancelation(uuid, jsonb, text, uuid[]) TO authenticated;
DROP FUNCTION IF EXISTS public.rp_convert_activity_to_cancelation(uuid, jsonb, text);

-- Put the phone onto today's conversions, taken from the entry each came from.
WITH src AS (
  SELECT DISTINCT ON (l.customer_label, l.occurred_on)
         l.customer_label, l.occurred_on, l.phone_last4
    FROM public.retention_activity_log l
   WHERE l.agency_id = '126794dd-25ff-47d2-a436-724499733365'
     AND l.status = 'void'
     AND l.void_reason LIKE 'spot-check: this was a cancelation%'
     AND l.phone_last4 IS NOT NULL
)
UPDATE public.cancelation_log c
   SET phone_last4 = src.phone_last4
  FROM src
 WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND c.phone_last4 IS NULL
   AND c.customer_label = src.customer_label
   AND c.canceled_on = src.occurred_on;

UPDATE public.retention_activity_log l
   SET phone_last4 = c.phone_last4
  FROM public.cancelation_log c
 WHERE l.source = 'cancelation_log' AND l.source_id = c.id
   AND l.phone_last4 IS NULL AND c.phone_last4 IS NOT NULL;
