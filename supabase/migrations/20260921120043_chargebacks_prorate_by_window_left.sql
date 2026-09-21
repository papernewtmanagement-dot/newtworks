-- Peter 2026-09-21: a cancelation charges back only the unearned part of the
-- premium, prorated by how much of the chargeback window was left when it
-- canceled (cancelation_log.window_fraction_left, set by the matching trigger).
-- James W.'s auto was charged back in full; 35% of its window was left.
--   * Past-quarter policy: the negative row is premium x window left. The
--     negative app stays whole.
--   * Same-quarter policy: the app drops out as before, and the premium it
--     earned before it canceled, premium x (1 - window left), stays in the
--     week it issued.
-- production_rows_for stays the one place this is decided.
CREATE OR REPLACE FUNCTION public.production_rows_for(p_agency_id uuid, p_from date, p_through date)
RETURNS TABLE(tm uuid, id uuid, sale_id uuid, lob text, product_type text, premium numeric, policy_count integer, vehicle_count integer, units integer, issued_date date, customer_label text, type_label text, on_file_answer text, phone_last4 text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH anchor AS (
    SELECT COALESCE((SELECT setting_value::date FROM public.settings
                      WHERE agency_id = p_agency_id AND setting_key = 'cycle_anchor_date'),
                    DATE '2026-04-05') AS d
  ),
  cxl AS (
    -- Live cancelations matched to a policy (matched = inside the chargeback
    -- window), the day each was recorded, and how much of the window was left.
    SELECT c.matched_sale_product_id AS pid,
           c.already_charged_back,
           LEAST(1, GREATEST(0, COALESCE(c.window_fraction_left, 1))) AS left_frac,
           (c.created_at AT TIME ZONE 'America/Chicago')::date AS recorded_on
      FROM public.cancelation_log c
     WHERE c.agency_id = p_agency_id AND c.status = 'active' AND c.matched_sale_product_id IS NOT NULL
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
  ),
  same_q AS (
    -- A cancelation recorded in the quarter the policy issued.
    SELECT b.id, cx.left_frac
      FROM base b JOIN cxl cx ON cx.pid = b.id CROSS JOIN anchor a
     WHERE NOT cx.already_charged_back
       AND floor((cx.recorded_on - a.d) / 91.0) <= floor((b.issued_date - a.d) / 91.0)
  )
  -- Policies, in the week they issued.
  SELECT b.tm, b.id, b.sale_id, b.lob, b.product_type, b.premium, b.policy_count, b.vehicle_count,
         b.units, b.issued_date, b.customer_label, b.type_label, b.on_file_answer, b.phone_last4
    FROM base b
   WHERE b.issued_date BETWEEN p_from AND p_through
     AND NOT EXISTS (SELECT 1 FROM same_q q WHERE q.id = b.id)
  UNION ALL
  -- Canceled in the quarter it issued: no app, and only the premium it earned
  -- before it canceled.
  SELECT b.tm, b.id, b.sale_id, b.lob, b.product_type, round(b.premium * (1 - q.left_frac), 2), 0, b.vehicle_count,
         0, b.issued_date, b.customer_label,
         'Canceled, earned part: ' || COALESCE(b.type_label, b.product_type), b.on_file_answer, b.phone_last4
    FROM base b JOIN same_q q ON q.id = b.id
   WHERE b.issued_date BETWEEN p_from AND p_through
     AND q.left_frac < 1
  UNION ALL
  -- Chargebacks, in the week they were recorded, for policies from an earlier
  -- quarter that were never charged back before. Replacements included.
  -- Premium prorated by the window left; the app comes off whole.
  SELECT b.tm, b.id, b.sale_id, b.lob, b.product_type, -round(b.premium * cx.left_frac, 2), -b.policy_count, b.vehicle_count,
         -b.units, cx.recorded_on, b.customer_label,
         'Chargeback: ' || COALESCE(b.type_label, b.product_type), b.on_file_answer, b.phone_last4
    FROM base b
    JOIN cxl cx ON cx.pid = b.id
    CROSS JOIN anchor a
   WHERE cx.recorded_on BETWEEN p_from AND p_through
     AND NOT cx.already_charged_back
     AND floor((cx.recorded_on - a.d) / 91.0) > floor((b.issued_date - a.d) / 91.0);
$function$;
