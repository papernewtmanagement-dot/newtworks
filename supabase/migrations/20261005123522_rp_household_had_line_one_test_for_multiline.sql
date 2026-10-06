CREATE OR REPLACE FUNCTION public.rp_household_had_line(p_sale_id uuid, p_line text DEFAULT NULL)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  /* 2026-10-05: did this sale's household already have this line (any line when p_line is
     NULL) on file before the sale? Earlier active sale, same household match as
     rp_replace_one_per_household (label + phone last four when both have one), any entry
     source including the historical load, product not canceled before this sale. False when
     the team said the name match is a different household. The one test multiline credit uses. */
  SELECT EXISTS (
    SELECT 1
      FROM public.sales_log s
      JOIN public.sales_log os
        ON os.agency_id = s.agency_id AND os.status = 'active' AND os.id <> s.id
       AND public.rp_customer_label_format(os.customer_first_name, os.customer_last_initial, os.customer_kind)
         = public.rp_customer_label_format(s.customer_first_name, s.customer_last_initial, s.customer_kind)
       AND (os.phone_last4 IS NULL OR s.phone_last4 IS NULL OR os.phone_last4 = s.phone_last4)
       AND (os.submitted_date, os.created_at) < (s.submitted_date, s.created_at)
      JOIN public.sales_log_products op ON op.sales_log_id = os.id
     WHERE s.id = p_sale_id
       AND COALESCE(s.on_file_answer, '') <> 'different'
       AND (p_line IS NULL OR op.line_of_business = p_line)
       AND NOT EXISTS (SELECT 1 FROM public.cancelation_log c
                        WHERE c.matched_sale_product_id = op.id AND c.status = 'active'
                          AND c.canceled_on < s.submitted_date));
$function$;
REVOKE ALL ON FUNCTION public.rp_household_had_line(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_household_had_line(uuid, text) TO authenticated, service_role;

