-- 1. Pivot: tracked, unpaid. The attempt has no retention value of its own;
--    the value arrives when it becomes a Policy Review or a Multiline, and
--    those pay on their own. Tracking the attempt gives a leading indicator
--    for coaching. Jasmand, Blazevic & de Ruyter 2012 (J. Marketing 76(1)):
--    cross-selling inside service calls raises sales growth; later work
--    (Gabler 2017, Vieira 2020) finds it also raises role conflict, so the
--    attempt is worth watching, not worth paying.
INSERT INTO public.retention_point_values (agency_id, activity_key, label, points, category, requires_note, sort_order, is_active, description)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'pivot', 'Pivot', 0.00, 'logged', false, 5, true,
        'You steered the conversation to a product the household does not have with us. Tracking only. The retention value shows up when it becomes a Policy Review or a Multiline, and those pay on their own.')
ON CONFLICT (agency_id, activity_key) DO UPDATE
  SET label = EXCLUDED.label, points = EXCLUDED.points, sort_order = EXCLUDED.sort_order,
      description = EXCLUDED.description, is_active = true, updated_at = now();

-- 2. Added Car off the activity list: it is commissioned like any other sale.
UPDATE public.retention_point_values SET is_active = false, updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND activity_key = 'service_task_added_car';

-- 3. Customer name suggestions for the entry page. Eight matches at most per
--    call, so the page never holds a customer list in memory.
CREATE OR REPLACE FUNCTION public.rp_customer_suggest(p_prefix text)
 RETURNS TABLE(customer_first_name text, customer_last_initial text, customer_label text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  names AS (
    SELECT l.customer_first_name, l.customer_last_initial, l.customer_label, l.agency_id FROM public.retention_activity_log l
    UNION SELECT s.customer_first_name, s.customer_last_initial, s.customer_label, s.agency_id FROM public.sales_log s
    UNION SELECT q.customer_first_name, q.customer_last_initial, q.customer_label, q.agency_id FROM public.quote_log q
    UNION SELECT c.customer_first_name, c.customer_last_initial, c.customer_label, c.agency_id FROM public.cancelation_log c
  )
  SELECT DISTINCT n.customer_first_name, n.customer_last_initial, n.customer_label
  FROM names n JOIN me ON me.agency_id = n.agency_id
  WHERE auth.uid() IS NOT NULL
    AND length(btrim(COALESCE(p_prefix, ''))) >= 2
    AND n.customer_label ILIKE btrim(p_prefix) || '%'
  ORDER BY n.customer_label
  LIMIT 8;
$function$;
REVOKE ALL ON FUNCTION public.rp_customer_suggest(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_customer_suggest(text) TO authenticated;
