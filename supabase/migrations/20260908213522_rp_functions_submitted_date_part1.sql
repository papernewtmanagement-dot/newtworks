CREATE OR REPLACE FUNCTION public.cancelation_log_chargeback()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  sp RECORD; cr RECORD; v_window_end date; v_left numeric; v_pts numeric; v_id uuid;
  v_cur_week date := public.rp_week_end(public.rp_today_central());
BEGIN
  IF NEW.matched_sale_product_id IS NOT NULL THEN
    SELECT p.id, p.line_of_business, p.product_type, p.premium, p.multiline_credit_id, s.submitted_date, s.id AS sale_id, s.customer_label
      INTO sp
      FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
     WHERE p.id = NEW.matched_sale_product_id AND s.agency_id = NEW.agency_id AND s.status = 'active'
       AND s.customer_label = NEW.customer_label AND p.line_of_business = NEW.policy_line
       AND s.submitted_date <= NEW.canceled_on
       AND s.submitted_date + (public.rp_chargeback_window_months(NEW.policy_line) || ' months')::interval > NEW.canceled_on;
  END IF;
  IF sp.id IS NULL THEN
    SELECT p.id, p.line_of_business, p.product_type, p.premium, p.multiline_credit_id, s.submitted_date, s.id AS sale_id, s.customer_label
      INTO sp
      FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
     WHERE s.agency_id = NEW.agency_id AND s.status = 'active'
       AND s.customer_label = NEW.customer_label AND p.line_of_business = NEW.policy_line
       AND s.submitted_date <= NEW.canceled_on
       AND s.submitted_date + (public.rp_chargeback_window_months(NEW.policy_line) || ' months')::interval > NEW.canceled_on
       AND NOT EXISTS (SELECT 1 FROM public.cancelation_log c WHERE c.matched_sale_product_id = p.id AND c.status = 'active' AND c.id <> NEW.id)
     ORDER BY (p.product_type IS NOT DISTINCT FROM NEW.product_type) DESC, s.submitted_date DESC
     LIMIT 1;
  END IF;
  IF sp.id IS NULL THEN
    UPDATE public.cancelation_log SET matched_sale_product_id = NULL WHERE id = NEW.id AND matched_sale_product_id IS NOT NULL;
    RETURN NEW;
  END IF;

  v_window_end := (sp.submitted_date + (public.rp_chargeback_window_months(NEW.policy_line) || ' months')::interval)::date;
  v_left := round((v_window_end - NEW.canceled_on)::numeric / NULLIF((v_window_end - sp.submitted_date)::numeric, 0), 4);
  v_left := LEAST(1, GREATEST(0, COALESCE(v_left, 0)));
  UPDATE public.cancelation_log SET matched_sale_product_id = sp.id, window_fraction_left = v_left WHERE id = NEW.id;

  IF sp.multiline_credit_id IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO cr FROM public.retention_activity_log WHERE id = sp.multiline_credit_id AND status = 'credited';
  IF NOT FOUND THEN RETURN NEW; END IF;
  v_pts := round(cr.points * v_left, 2);
  IF v_pts <= 0 THEN RETURN NEW; END IF;

  IF cr.credited_week_end_date >= v_cur_week THEN
    UPDATE public.retention_activity_log
       SET status = 'void', voided_at = now(), voided_by = NEW.created_by,
           void_reason = 'policy canceled ' || NEW.canceled_on::text || ' inside the chargeback window', updated_at = now()
     WHERE id = cr.id;
    UPDATE public.cancelation_log SET chargeback_points = cr.points, chargeback_activity_id = cr.id WHERE id = NEW.id;
  ELSE
    INSERT INTO public.retention_activity_log (agency_id, team_member_id, activity_key, occurred_on, week_end_date, credited_week_end_date,
      customer_first_name, customer_last_initial, customer_label, note, points, source, source_id, created_by)
    VALUES (NEW.agency_id, cr.team_member_id, 'multiline_chargeback', NEW.canceled_on, public.rp_week_end(NEW.canceled_on), v_cur_week,
      NEW.customer_first_name, NEW.customer_last_initial, NEW.customer_label,
      'Chargeback: ' || NEW.policy_line || ' sold ' || to_char(sp.submitted_date, 'Mon FMDD') || ' canceled ' || to_char(NEW.canceled_on, 'Mon FMDD') ||
        ', ' || round(v_left * 100) || '% of the window left',
      -v_pts, 'cancelation_log', NEW.id, NEW.created_by)
    RETURNING id INTO v_id;
    UPDATE public.cancelation_log SET chargeback_points = v_pts, chargeback_activity_id = v_id WHERE id = NEW.id;
  END IF;
  RETURN NEW;
END $function$;

DROP FUNCTION IF EXISTS public.rp_sold_on_file(text, text);

CREATE FUNCTION public.rp_sold_on_file(p_customer_first text, p_customer_last_initial text)
 RETURNS TABLE(sale_product_id uuid, sale_id uuid, submitted_date date, line_of_business text, product_type text, premium numeric, vehicle_count integer, already_canceled boolean, window_end date)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1)
  SELECT p.id, s.id, s.submitted_date, p.line_of_business, p.product_type, p.premium, p.vehicle_count,
         EXISTS (SELECT 1 FROM public.cancelation_log c WHERE c.matched_sale_product_id = p.id AND c.status = 'active'),
         (s.submitted_date + (public.rp_chargeback_window_months(p.line_of_business) || ' months')::interval)::date
  FROM public.sales_log s JOIN me ON me.agency_id = s.agency_id
  JOIN public.sales_log_products p ON p.sales_log_id = s.id
  WHERE auth.uid() IS NOT NULL AND s.status = 'active'
    AND s.customer_label = public.rp_customer_label(p_customer_first, p_customer_last_initial)
  ORDER BY s.submitted_date DESC, p.line_of_business;
$function$;
