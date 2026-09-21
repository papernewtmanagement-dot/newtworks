CREATE OR REPLACE FUNCTION public.production_rows_for(p_agency_id uuid, p_from date, p_through date)
 RETURNS TABLE(tm uuid, id uuid, sale_id uuid, lob text, product_type text, premium numeric, policy_count integer, vehicle_count integer, units integer, issued_date date, customer_label text, type_label text, on_file_answer text, phone_last4 text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH cxl AS (
    -- Live cancelations matched to a policy (matched = inside the chargeback
    -- window), the date each counts on, and how much of the window was left.
    SELECT c.matched_sale_product_id AS pid,
           LEAST(1, GREATEST(0, COALESCE(c.window_fraction_left, 1))) AS left_frac,
           public.cancel_counts_on(c.agency_id, c.created_at) AS recorded_on
      FROM public.cancelation_log c
     WHERE c.agency_id = p_agency_id AND c.status = 'active' AND c.matched_sale_product_id IS NOT NULL
       AND NOT COALESCE(c.already_charged_back, false)
  ),
  base AS (
    SELECT s.team_member_id AS tm, p.id, s.id AS sale_id, p.line_of_business AS lob, p.product_type,
           COALESCE(p.issued_premium, p.premium) AS premium,
           GREATEST(1, COALESCE(p.policy_count, 1)) AS policy_count,
           p.vehicle_count,
           -- Auto counts one app per VEHICLE. Everything else counts policies.
           CASE WHEN p.line_of_business = 'auto'
                THEN GREATEST(1, COALESCE(p.vehicle_count, s.vehicle_count, p.policy_count, 1))
                ELSE GREATEST(1, COALESCE(p.policy_count, 1)) END AS units,
           p.issued_date, s.customer_label, pt.label AS type_label, s.on_file_answer, s.phone_last4
    FROM public.sales_log s
    JOIN public.sales_log_products p ON p.sales_log_id = s.id
    LEFT JOIN public.product_types pt
      ON pt.agency_id = s.agency_id AND pt.line_of_business = p.line_of_business AND pt.type_key = p.product_type
    WHERE s.agency_id = p_agency_id AND s.status = 'active' AND p.issued_date IS NOT NULL
  )
  -- Policies, in the week they issued. A later cancelation never rewrites this.
  SELECT b.tm, b.id, b.sale_id, b.lob, b.product_type, b.premium, b.policy_count, b.vehicle_count,
         b.units, b.issued_date, b.customer_label, b.type_label, b.on_file_answer, b.phone_last4
    FROM base b
   WHERE b.issued_date BETWEEN p_from AND p_through
  UNION ALL
  -- Peter 2026-09-21: every cancelation inside the window is a chargeback, whenever
  -- the policy issued. Lands on the date the cancel counts on. Premium prorated by
  -- the window left; the app comes off whole. Replacements included. Rows marked
  -- already charged back are record only.
  SELECT b.tm, b.id, b.sale_id, b.lob, b.product_type, -round(b.premium * cx.left_frac, 2), -b.policy_count, b.vehicle_count,
         -b.units, cx.recorded_on, b.customer_label,
         'Chargeback: ' || COALESCE(b.type_label, b.product_type), b.on_file_answer, b.phone_last4
    FROM base b
    JOIN cxl cx ON cx.pid = b.id
   WHERE cx.recorded_on BETWEEN p_from AND p_through;
$function$;
