CREATE OR REPLACE FUNCTION public.rp_household_on_file(p_sale_id uuid, p_product_id uuid DEFAULT NULL)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  /* Peter 2026-10-05: what this sale's household already had on file before the sale.
     p_product_id NULL: anything at all, i.e. we hold records for this household.
     p_product_id given: that same product. Same line and type; for life, any life sold in the
     rp_life_repeat_days() before this sale (a new life past that mark is a new product).
     Household = the rp_replace_one_per_household match (label, phone last four when both have
     one), any entry source including the historical load, not canceled before this sale.
     False when the team said the name match is a different household.
     The one test multiline credit uses. */
  SELECT EXISTS (
    SELECT 1
      FROM public.sales_log s
      LEFT JOIN public.sales_log_products me ON me.id = p_product_id
      JOIN public.sales_log os
        ON os.agency_id = s.agency_id AND os.status = 'active' AND os.id <> s.id
       AND public.rp_customer_label_format(os.customer_first_name, os.customer_last_initial, os.customer_kind)
         = public.rp_customer_label_format(s.customer_first_name, s.customer_last_initial, s.customer_kind)
       AND (os.phone_last4 IS NULL OR s.phone_last4 IS NULL OR os.phone_last4 = s.phone_last4)
       AND (os.submitted_date, os.created_at) < (s.submitted_date, s.created_at)
      JOIN public.sales_log_products op ON op.sales_log_id = os.id
     WHERE s.id = p_sale_id
       AND COALESCE(s.on_file_answer, '') <> 'different'
       AND (p_product_id IS NULL OR (
             op.line_of_business = me.line_of_business
             AND CASE WHEN me.line_of_business = 'life'
                      THEN os.submitted_date >= s.submitted_date - public.rp_life_repeat_days()
                      ELSE op.product_type IS NOT DISTINCT FROM me.product_type END))
       AND NOT EXISTS (SELECT 1 FROM public.cancelation_log c
                        WHERE c.matched_sale_product_id = op.id AND c.status = 'active'
                          AND c.canceled_on < s.submitted_date));
$function$;
REVOKE ALL ON FUNCTION public.rp_household_on_file(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_household_on_file(uuid, uuid) TO authenticated, service_role;
