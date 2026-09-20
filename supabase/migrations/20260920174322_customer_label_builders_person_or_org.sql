-- ONE place decides what a customer is called. Three small functions, each with
-- one job, so no caller ever builds a label by hand:
--   rp_customer_kind    reads the toggle and says person or org
--   rp_customer_initial says what goes in the initial column (nothing, for an org)
--   rp_customer_label   builds the name that gets stored and shown

CREATE OR REPLACE FUNCTION public.rp_customer_kind(p_kind text)
 RETURNS text LANGUAGE plpgsql IMMUTABLE
AS $function$
DECLARE k text := lower(btrim(COALESCE(p_kind, '')));
BEGIN
  IF k = '' THEN RETURN 'person'; END IF;
  IF k = 'organization' THEN RETURN 'org'; END IF;
  IF k NOT IN ('person', 'org') THEN
    RAISE EXCEPTION 'the customer has to be a person or an organization';
  END IF;
  RETURN k;
END $function$;

CREATE OR REPLACE FUNCTION public.rp_customer_initial(p_initial text, p_kind text DEFAULT 'person')
 RETURNS text LANGUAGE sql IMMUTABLE
AS $function$
  SELECT CASE WHEN public.rp_customer_kind(p_kind) = 'org'
              THEN NULL
              ELSE NULLIF(upper(btrim(COALESCE(p_initial, ''))), '') END;
$function$;

-- The two-argument version is dropped, not left alongside. Two label builders is
-- how they drift apart. The kind defaults to person, so every existing caller
-- that passes two arguments keeps working and keeps its old behavior exactly.
DROP FUNCTION IF EXISTS public.rp_customer_label(text, text);

CREATE OR REPLACE FUNCTION public.rp_customer_label(p_first text, p_initial text, p_kind text DEFAULT 'person')
 RETURNS text LANGUAGE plpgsql IMMUTABLE
AS $function$
DECLARE
  f text := btrim(COALESCE(p_first, ''));
  i text := btrim(COALESCE(p_initial, ''));
  k text := public.rp_customer_kind(p_kind);
BEGIN
  IF k = 'org' THEN
    IF f = '' THEN RAISE EXCEPTION 'the organization name is required'; END IF;
    IF length(f) > 80 THEN RAISE EXCEPTION 'organization name too long (max 80)'; END IF;
    -- An organization name is stored as typed. Periods are part of plenty of
    -- them, and there is no initial to bolt on the end.
    RETURN f;
  END IF;
  IF f = '' THEN RAISE EXCEPTION 'customer first name required'; END IF;
  IF f ~ '\.' THEN RAISE EXCEPTION 'first name should not contain a period'; END IF;
  IF length(f) > 40 THEN RAISE EXCEPTION 'first name too long (max 40)'; END IF;
  IF i !~ '^[A-Za-z]$' THEN RAISE EXCEPTION 'last initial must be a single letter'; END IF;
  RETURN f || ' ' || upper(i) || '.';
END $function$;

-- What this household already has on file. Same two lookups, now told which
-- kind of customer they are looking for so the label they match on is right.
DROP FUNCTION IF EXISTS public.rp_sold_on_file2(text, text, text);
DROP FUNCTION IF EXISTS public.rp_sold_on_file(text, text);

CREATE FUNCTION public.rp_sold_on_file(p_customer_first text, p_customer_last_initial text, p_customer_kind text DEFAULT 'person')
 RETURNS TABLE(sale_product_id uuid, sale_id uuid, submitted_date date, line_of_business text, product_type text, premium numeric, vehicle_count integer, already_canceled boolean, window_end date)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1)
  SELECT p.id, s.id, s.submitted_date, p.line_of_business, p.product_type, p.premium, p.vehicle_count,
         EXISTS (SELECT 1 FROM public.cancelation_log c WHERE c.matched_sale_product_id = p.id AND c.status = 'active'),
         (s.submitted_date + (public.rp_chargeback_window_months(p.line_of_business) || ' months')::interval)::date
  FROM public.sales_log s JOIN me ON me.agency_id = s.agency_id
  JOIN public.sales_log_products p ON p.sales_log_id = s.id
  WHERE auth.uid() IS NOT NULL AND s.status = 'active'
    AND s.customer_label = public.rp_customer_label(p_customer_first, p_customer_last_initial, p_customer_kind)
  ORDER BY s.submitted_date DESC, p.line_of_business;
$function$;

CREATE FUNCTION public.rp_sold_on_file2(p_customer_first text, p_customer_last_initial text, p_phone_last4 text DEFAULT NULL::text, p_customer_kind text DEFAULT 'person')
 RETURNS TABLE(sale_product_id uuid, line_of_business text, product_type text, premium numeric, vehicle_count integer, submitted_date date, already_canceled boolean, window_end date)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT f.sale_product_id::uuid, f.line_of_business::text, f.product_type::text, f.premium::numeric, f.vehicle_count::integer,
         f.submitted_date::date, f.already_canceled::boolean, f.window_end::date
  FROM public.rp_sold_on_file(p_customer_first, p_customer_last_initial, p_customer_kind) f
  JOIN public.sales_log_products sp ON sp.id = f.sale_product_id
  JOIN public.sales_log s ON s.id = sp.sales_log_id
  WHERE auth.uid() IS NOT NULL
    AND (NULLIF(p_phone_last4, '') IS NULL OR s.phone_last4 IS NULL OR s.phone_last4 = p_phone_last4);
$function$;

GRANT EXECUTE ON FUNCTION public.rp_customer_kind(text) TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION public.rp_customer_initial(text, text) TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION public.rp_customer_label(text, text, text) TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION public.rp_sold_on_file(text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rp_sold_on_file2(text, text, text, text) TO authenticated, service_role;
