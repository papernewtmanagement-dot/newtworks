-- Peter 2026-09-20. Two corrections to 20260920215440.
--
-- 1) Only cancelations that were never charged back produce a new chargeback.
--    The eight cancelations from the 2026-09-10 historical load arrived already
--    charged back -- each note reads "Historical load. Chargeback of $...". They
--    were labeled 'manual' by mistake and the new rule charged them a second
--    time. Same for David J.'s home: Peter confirms it was charged back when it
--    happened. A cancelation can now say so (already_charged_back), and one that
--    does is a record only: it charges nothing new.
--
-- 2) A replacement DOES charge back the prior policy when the cancelation falls
--    inside the chargeback window. Peter has said this many times; the rule
--    wrongly exempted replacements. The window itself is enforced where it always
--    was -- a cancelation outside it is never matched to a policy.

ALTER TABLE public.cancelation_log
  ADD COLUMN IF NOT EXISTS already_charged_back boolean NOT NULL DEFAULT false;

UPDATE public.cancelation_log
   SET already_charged_back = true, entry_source = 'historical_load', updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND note ILIKE 'Historical load.%';

UPDATE public.cancelation_log
   SET already_charged_back = true, updated_at = now()
 WHERE id = '26950ac9-0fe7-4bf3-a4a5-7672f8f52c5f';   -- David J. home, canceled 2026-02-04

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
    -- window), and the day each was recorded.
    SELECT c.matched_sale_product_id AS pid,
           c.already_charged_back,
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
  -- quarter that were never charged back before. Replacements included.
  SELECT b.tm, b.id, b.sale_id, b.lob, b.product_type, -b.premium, -b.policy_count, b.vehicle_count,
         -b.units, cxl.recorded_on, b.customer_label,
         'Chargeback: ' || COALESCE(b.type_label, b.product_type), b.on_file_answer, b.phone_last4
    FROM base b
    JOIN cxl ON cxl.pid = b.id
    CROSS JOIN anchor a
   WHERE cxl.recorded_on BETWEEN p_from AND p_through
     AND NOT cxl.already_charged_back
     AND floor((cxl.recorded_on - a.d) / 91.0) > floor((b.issued_date - a.d) / 91.0);
$function$;

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
           'already_charged_back', c.already_charged_back,
           'matched', (c.matched_sale_product_id IS NOT NULL),
           'effect', CASE
             WHEN c.matched_sale_product_id IS NULL THEN 'outside the chargeback window: no charge'
             WHEN c.already_charged_back THEN 'already charged back when it happened: no new charge'
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

-- One switch per backfill cancelation: "this was already charged back when it
-- happened". So the next David J. is a click, not a message.
CREATE OR REPLACE FUNCTION public.rp_backfill_mark_charged_back(p_id uuid, p_value boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  IF NOT a.is_admin THEN RAISE EXCEPTION 'the owner and managers only' USING ERRCODE='42501'; END IF;
  UPDATE public.cancelation_log
     SET already_charged_back = COALESCE(p_value, false), updated_at = now()
   WHERE id = p_id AND agency_id = a.agency_id AND status = 'active'
     AND entry_source = 'historical_backfill';
  IF NOT FOUND THEN RAISE EXCEPTION 'that cancelation was not found in the backfill list'; END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_id, 'already_charged_back', COALESCE(p_value, false));
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_backfill_mark_charged_back(uuid, boolean) TO authenticated;
