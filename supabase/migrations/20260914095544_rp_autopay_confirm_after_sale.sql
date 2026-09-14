-- Autopay can be ticked on a sold policy later, when the customer signs it
-- after the sale (Peter 2026-09-14). The credit is still written in exactly
-- one place: the trigger on sales_log_products. rp_set_sale_autopay only
-- flips the tick and names who flipped it, through rp.autopay_actor, the
-- same session-setting pattern rp_fill_phone_last4 already uses.
--
-- Sale entry  -> credit dated the submitted date, to the seller (unchanged).
-- Ticked later -> credit dated today, to the person who ticked it.
-- Unticked    -> that credit is voided.
-- rp_autopay_guard still blocks a second credit on the same policy.

CREATE OR REPLACE FUNCTION public.rp_sale_autopay_credit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_actor uuid := NULLIF(current_setting('rp.autopay_actor', true), '')::uuid;
  v_later boolean := (TG_OP = 'UPDATE');
  v_on    date;
BEGIN
  IF v_later AND COALESCE(OLD.autopay_enrolled, false) = COALESCE(NEW.autopay_enrolled, false) THEN
    RETURN NEW;
  END IF;

  IF NOT COALESCE(NEW.autopay_enrolled, false) THEN
    IF v_later THEN
      UPDATE public.retention_activity_log l
         SET status = 'voided', voided_at = now(), updated_at = now(),
             void_reason = 'Autopay unticked on the sold policy'
       WHERE l.activity_key = 'autopay_enrollment'
         AND l.status <> 'voided'
         AND l.source = 'sales_log'
         AND l.source_id = NEW.sales_log_id
         AND l.policy_line = NEW.line_of_business
         AND l.product_type IS NOT DISTINCT FROM NEW.product_type;
    END IF;
    RETURN NEW;
  END IF;

  SELECT CASE WHEN v_later THEN public.rp_today_central() ELSE s.submitted_date END
    INTO v_on
    FROM public.sales_log s WHERE s.id = NEW.sales_log_id;

  INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on,
      week_end_date, credited_week_end_date, customer_first_name, customer_last_initial, customer_label,
      phone_last4, ecrm_url, note, points, source, source_id, created_by,
      policy_line, product_type, premium)
  SELECT s.agency_id,
         CASE WHEN v_later THEN COALESCE(v_actor, s.team_member_id) ELSE s.team_member_id END,
         'autopay_enrollment', v_on, public.rp_week_end(v_on), public.rp_week_end(v_on),
         s.customer_first_name, s.customer_last_initial, s.customer_label, s.phone_last4,
         s.ecrm_opportunity_url,
         CASE WHEN v_later THEN 'Autopay confirmed after the sale' ELSE 'From sale entry: policy set up on autopay' END,
         v.points, 'sales_log', s.id, s.created_by, NEW.line_of_business, NEW.product_type, NEW.premium
  FROM public.sales_log s
  JOIN public.retention_point_values v ON v.agency_id = s.agency_id AND v.activity_key = 'autopay_enrollment' AND v.is_active
  WHERE s.id = NEW.sales_log_id;

  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS trg_rp_sale_autopay_credit ON public.sales_log_products;
CREATE TRIGGER trg_rp_sale_autopay_credit
AFTER INSERT OR UPDATE OF autopay_enrolled ON public.sales_log_products
FOR EACH ROW EXECUTE FUNCTION public.rp_sale_autopay_credit();

CREATE OR REPLACE FUNCTION public.rp_set_sale_autopay(p_sale_product_id uuid, p_on boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; v_phone text; v_n integer;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  SELECT s.phone_last4 INTO v_phone
    FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
   WHERE p.id = p_sale_product_id AND s.agency_id = a.agency_id AND s.status = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION 'that policy was not found'; END IF;

  PERFORM set_config('rp.autopay_actor', COALESCE(a.team_member_id::text, ''), true);
  PERFORM set_config('rp.phone_last4', COALESCE(v_phone, ''), true);

  UPDATE public.sales_log_products p SET autopay_enrolled = COALESCE(p_on, false)
    FROM public.sales_log s
   WHERE p.id = p_sale_product_id AND s.id = p.sales_log_id AND s.agency_id = a.agency_id
     AND s.status = 'active' AND COALESCE(p.autopay_enrolled, false) <> COALESCE(p_on, false);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'changed', v_n > 0, 'autopay', COALESCE(p_on, false));
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_set_sale_autopay(uuid, boolean) TO authenticated;