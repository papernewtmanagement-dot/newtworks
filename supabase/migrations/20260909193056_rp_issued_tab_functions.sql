-- Policies that have been submitted but not yet marked issued.
CREATE OR REPLACE FUNCTION public.rp_pending_issue()
 RETURNS TABLE(sale_product_id uuid, sale_id uuid, submitted_date date, days_waiting integer,
               customer_label text, team_member_id uuid, seller text,
               line_of_business text, product_type text, premium numeric, vehicle_count integer)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1)
  SELECT p.id, s.id, s.submitted_date,
         (public.rp_today_central() - s.submitted_date)::int,
         s.customer_label, s.team_member_id, t.first_name || ' ' || t.last_name,
         p.line_of_business, p.product_type, p.premium, p.vehicle_count
  FROM public.sales_log s
  JOIN me ON me.agency_id = s.agency_id
  JOIN public.sales_log_products p ON p.sales_log_id = s.id
  LEFT JOIN public.team t ON t.id = s.team_member_id
  WHERE auth.uid() IS NOT NULL AND s.status = 'active' AND p.issued_date IS NULL
  ORDER BY s.submitted_date, s.customer_label, p.line_of_business;
$function$;

-- Mark one or more policies issued. Payload: [{"sale_product_id":"...","issued_date":"YYYY-MM-DD"}, ...]
CREATE OR REPLACE FUNCTION public.rp_mark_issued(p_items jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  a RECORD; it jsonb; v_id uuid; v_on date; v_sub date; v_n integer := 0;
  v_today date := public.rp_today_central();
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'pick at least one policy to mark issued';
  END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_id := NULLIF(it->>'sale_product_id','')::uuid;
    v_on := COALESCE(NULLIF(it->>'issued_date','')::date, v_today);
    IF v_on > v_today THEN RAISE EXCEPTION 'the issue date cannot be in the future'; END IF;
    SELECT s.submitted_date INTO v_sub
      FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
     WHERE p.id = v_id AND s.agency_id = a.agency_id AND s.status = 'active';
    IF v_sub IS NULL THEN RAISE EXCEPTION 'that policy was not found'; END IF;
    IF v_on < v_sub THEN RAISE EXCEPTION 'a policy cannot issue before it was submitted (submitted %)', v_sub; END IF;
    UPDATE public.sales_log_products SET issued_date = v_on WHERE id = v_id;
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'marked', v_n);
END $function$;

-- Undo, for a mis-click.
CREATE OR REPLACE FUNCTION public.rp_unmark_issued(p_sale_product_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE a RECORD; v_n integer;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  UPDATE public.sales_log_products p SET issued_date = NULL
    FROM public.sales_log s
   WHERE p.id = p_sale_product_id AND s.id = p.sales_log_id AND s.agency_id = a.agency_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('ok', v_n > 0);
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_pending_issue() TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_mark_issued(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rp_unmark_issued(uuid) TO authenticated;
