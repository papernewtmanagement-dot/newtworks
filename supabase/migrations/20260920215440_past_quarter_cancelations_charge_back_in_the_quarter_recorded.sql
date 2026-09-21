-- Peter 2026-09-20: a cancelation on a policy from an earlier quarter counts as
-- a NEGATIVE app and NEGATIVE premium in the quarter the cancelation is
-- RECORDED -- not the quarter of the cancel's effective date when the two
-- differ. It then moves that quarter's sales points like any other count.
--
-- Before this, every cancelation simply took the policy out of the quarter it
-- issued in. For a policy from a past quarter that meant nothing happened: the
-- past quarter is frozen and paid, and the current quarter never had it.
--
-- The rule now, in the one function every sales-points reader goes through:
--   * canceled and recorded in the same quarter it issued -> the policy drops
--     out of that quarter, exactly as before.
--   * recorded in a later quarter -> the policy stays in the quarter it issued
--     (that quarter was paid on it), and a negative row lands on the date the
--     cancelation was recorded, in the recording quarter.
--   * a replacement never charges back: the household kept the line.
-- "Quarter" is the agency's 13-week cycle from settings.cycle_anchor_date, the
-- same arithmetic current_cycle_info uses.

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
    -- Live cancelations matched to a policy, and the day each was recorded.
    SELECT c.matched_sale_product_id AS pid,
           COALESCE(c.is_replacement, false) AS is_replacement,
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
  )
  -- Policies, in the week they issued. Out only when canceled inside the same
  -- quarter they issued in.
  SELECT b.tm, b.id, b.sale_id, b.lob, b.product_type, b.premium, b.policy_count, b.vehicle_count,
         b.units, b.issued_date, b.customer_label, b.type_label, b.on_file_answer, b.phone_last4
    FROM base b, anchor a
   WHERE b.issued_date BETWEEN p_from AND p_through
     AND NOT EXISTS (
       SELECT 1 FROM cxl
        WHERE cxl.pid = b.id
          AND floor((cxl.recorded_on - a.d) / 91.0) <= floor((b.issued_date - a.d) / 91.0))
  UNION ALL
  -- Chargebacks, in the week they were recorded, for policies from an earlier
  -- quarter. Negative apps, negative premium.
  SELECT b.tm, b.id, b.sale_id, b.lob, b.product_type, -b.premium, -b.policy_count, b.vehicle_count,
         -b.units, cxl.recorded_on, b.customer_label,
         'Chargeback: ' || COALESCE(b.type_label, b.product_type), b.on_file_answer, b.phone_last4
    FROM base b
    JOIN cxl ON cxl.pid = b.id
    CROSS JOIN anchor a
   WHERE cxl.recorded_on BETWEEN p_from AND p_through
     AND NOT cxl.is_replacement
     AND floor((cxl.recorded_on - a.d) / 91.0) > floor((b.issued_date - a.d) / 91.0);
$function$;

-- Every cancelation keyed in from the Backfill tab, for the list on that tab.
CREATE OR REPLACE FUNCTION public.rp_backfill_cancelations()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; v_anchor date; v_out jsonb;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'the owner and managers only' USING ERRCODE='42501'; END IF;
  SELECT COALESCE((SELECT setting_value::date FROM public.settings
                    WHERE agency_id = a.agency_id AND setting_key = 'cycle_anchor_date'), DATE '2026-04-05')
    INTO v_anchor;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', c.id, 'customer_label', c.customer_label, 'phone_last4', c.phone_last4,
           'owner', t.first_name, 'policy_line', c.policy_line, 'product_type', c.product_type,
           'issued_date', p.issued_date, 'canceled_on', c.canceled_on,
           'recorded_on', (c.created_at AT TIME ZONE 'America/Chicago')::date,
           'premium', COALESCE(p.issued_premium, p.premium, c.premium),
           'cars', CASE WHEN c.policy_line = 'auto' THEN p.vehicle_count END,
           'is_replacement', COALESCE(c.is_replacement, false),
           'matched', (c.matched_sale_product_id IS NOT NULL),
           -- What it does to sales points under the rule above.
           'effect', CASE
             WHEN c.matched_sale_product_id IS NULL THEN 'outside the chargeback window: no charge'
             WHEN COALESCE(c.is_replacement, false) THEN 'replacement: no charge'
             WHEN floor((((c.created_at AT TIME ZONE 'America/Chicago')::date) - v_anchor) / 91.0)
                  > floor((p.issued_date - v_anchor) / 91.0)
               THEN 'charged back this quarter'
             ELSE 'removed from the quarter it issued in' END)
         ORDER BY c.created_at DESC), '[]'::jsonb)
    INTO v_out
    FROM public.cancelation_log c
    LEFT JOIN public.sales_log_products p ON p.id = c.matched_sale_product_id
    LEFT JOIN public.team_directory t ON t.id = c.team_member_id
   WHERE c.agency_id = a.agency_id AND c.status = 'active'
     AND c.entry_source = 'historical_backfill';

  RETURN jsonb_build_object('ok', true, 'cancelations', v_out);
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_backfill_cancelations() TO authenticated;

-- The backfill cancel can be marked as a replacement, which never charges back.
DO $mig$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rp_backfill_save';

  v_def := replace(v_def,
    $old$          'backfill', true,$old$,
    $new$          'backfill', true,
          'replacement', COALESCE((pol->>'replacement')::boolean, false),$new$);

  IF v_def NOT LIKE '%''replacement'', COALESCE((pol->>''replacement'')::boolean, false)%' THEN
    RAISE EXCEPTION 'rp_backfill_save did not match the expected shape; not patching blind';
  END IF;
  EXECUTE v_def;
END $mig$;
