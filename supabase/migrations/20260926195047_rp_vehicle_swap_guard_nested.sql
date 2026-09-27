-- The swap's own writes never start another swap check while it runs. At commit the Policy Change it
-- wrote is already on vehicle_swaps, so the later check skips it; this guard covers checks that fire at once.
CREATE OR REPLACE FUNCTION public.tg_rp_vehicle_swap_activity()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF COALESCE(current_setting('rp.vehicle_swap', true), '') = '1' THEN RETURN NULL; END IF;
  IF NEW.activity_key = 'service_task' AND NEW.status = 'credited' AND public.rp_note_removes_vehicle(NEW.note) THEN
    PERFORM public.rp_vehicle_swap_check(NEW.agency_id,
      public.rp_customer_label_format(NEW.customer_first_name, NEW.customer_last_initial, NEW.customer_kind),
      NEW.phone_last4);
  END IF;
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.tg_rp_vehicle_swap_product()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE s RECORD;
BEGIN
  IF COALESCE(current_setting('rp.vehicle_swap', true), '') = '1' THEN RETURN NULL; END IF;
  IF NEW.line_of_business = 'auto' AND COALESCE(NEW.is_added_to_existing, false) THEN
    SELECT x.agency_id, x.customer_first_name, x.customer_last_initial, x.customer_kind, x.phone_last4, x.status
      INTO s FROM public.sales_log x WHERE x.id = NEW.sales_log_id;
    IF FOUND AND s.status = 'active' THEN
      PERFORM public.rp_vehicle_swap_check(s.agency_id,
        public.rp_customer_label_format(s.customer_first_name, s.customer_last_initial, s.customer_kind),
        s.phone_last4);
    END IF;
  END IF;
  RETURN NULL;
END $function$;

CREATE OR REPLACE FUNCTION public.rp_vehicle_swap_check(p_agency uuid, p_label text, p_phone text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r RECORD; n integer := 0; v_res jsonb;
BEGIN
  IF p_agency IS NULL OR NULLIF(btrim(COALESCE(p_label, '')), '') IS NULL THEN RETURN 0; END IF;
  LOOP
    SELECT rm.id AS removal_id, sp.id AS product_id INTO r
      FROM public.retention_activity_log rm
      JOIN public.sales_log s
        ON s.agency_id = rm.agency_id AND s.customer_label = rm.customer_label
       AND (rm.phone_last4 IS NULL OR s.phone_last4 IS NULL OR s.phone_last4 = rm.phone_last4)
      JOIN public.sales_log_products sp ON sp.sales_log_id = s.id
     WHERE rm.agency_id = p_agency AND rm.customer_label = p_label
       AND (NULLIF(p_phone, '') IS NULL OR rm.phone_last4 IS NULL OR rm.phone_last4 = p_phone)
       AND rm.activity_key = 'service_task' AND rm.status = 'credited'
       AND public.rp_note_removes_vehicle(rm.note)
       AND NOT EXISTS (SELECT 1 FROM public.vehicle_swaps w
                        WHERE w.removal_activity_id = rm.id OR w.replacement_activity_id = rm.id)
       AND s.status = 'active' AND COALESCE(s.entry_source, 'manual') <> 'historical_backfill'
       AND sp.line_of_business = 'auto' AND COALESCE(sp.is_added_to_existing, false)
       AND abs(s.submitted_date - rm.occurred_on) <= public.rp_vehicle_swap_days()
       AND NOT EXISTS (SELECT 1 FROM public.cancelation_log c
                        WHERE c.matched_sale_product_id = sp.id AND c.status = 'active')
     ORDER BY abs(s.submitted_date - rm.occurred_on), rm.occurred_on, s.submitted_date, sp.id
     LIMIT 1;
    EXIT WHEN NOT FOUND;
    PERFORM set_config('rp.vehicle_swap', '1', true);
    v_res := public.rp_vehicle_swap_convert(r.product_id, r.removal_id);
    PERFORM set_config('rp.vehicle_swap', '', true);
    EXIT WHEN v_res IS NULL;
    n := n + 1;
    EXIT WHEN n >= 20;
  END LOOP;
  RETURN n;
END $function$;

REVOKE ALL ON FUNCTION public.rp_vehicle_swap_check(uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_rp_vehicle_swap_activity() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_rp_vehicle_swap_product() FROM PUBLIC, anon, authenticated;
