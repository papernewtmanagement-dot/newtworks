-- Peter 2026-10-06: a sale's submitted date can be corrected from History. Every live
-- cancelation matched to one of its policies re-measures how much of the chargeback
-- window was left, with the same function the cancelation itself uses.
CREATE OR REPLACE FUNCTION public.sales_log_submitted_date_changed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  UPDATE public.cancelation_log c
     SET window_fraction_left = public.cancel_window_fraction_left(c.policy_line, NEW.submitted_date, c.canceled_on),
         updated_at = now()
    FROM public.sales_log_products p
   WHERE p.sales_log_id = NEW.id AND c.matched_sale_product_id = p.id
     AND c.window_fraction_left IS DISTINCT FROM public.cancel_window_fraction_left(c.policy_line, NEW.submitted_date, c.canceled_on);
  RETURN NULL;
END $function$;

DROP TRIGGER IF EXISTS trg_sales_log_submitted_date_changed ON public.sales_log;
CREATE TRIGGER trg_sales_log_submitted_date_changed
  AFTER UPDATE OF submitted_date ON public.sales_log
  FOR EACH ROW WHEN (NEW.submitted_date IS DISTINCT FROM OLD.submitted_date)
  EXECUTE FUNCTION public.sales_log_submitted_date_changed();

CREATE OR REPLACE FUNCTION public.cancelation_log_chargeback()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  sp RECORD; cr RECORD; v_window_end date; v_left numeric; v_pts numeric; v_id uuid;
  v_cur_week date := public.rp_week_end(public.rp_today_central());
BEGIN
    SELECT p.id, p.line_of_business, p.product_type, p.premium, p.multiline_credit_id, s.submitted_date, s.id AS sale_id, s.customer_label
      INTO sp
      FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
     WHERE p.id = NEW.matched_sale_product_id AND s.agency_id = NEW.agency_id AND s.status = 'active'
       AND s.customer_label = public.customer_label(NEW) AND p.line_of_business = NEW.policy_line
       AND s.submitted_date <= NEW.canceled_on
       AND s.submitted_date + (public.rp_chargeback_window_months(NEW.policy_line) || ' months')::interval > NEW.canceled_on
       -- Peter 2026-10-06: a sold policy is canceled once. A pick already carried by another
       -- live cancelation falls through to the automatic match below.
       AND NOT EXISTS (SELECT 1 FROM public.cancelation_log c WHERE c.matched_sale_product_id = p.id AND c.status = 'active' AND c.id <> NEW.id);
  IF sp.id IS NULL THEN
    SELECT p.id, p.line_of_business, p.product_type, p.premium, p.multiline_credit_id, s.submitted_date, s.id AS sale_id, s.customer_label
      INTO sp
      FROM public.sales_log_products p JOIN public.sales_log s ON s.id = p.sales_log_id
     WHERE s.agency_id = NEW.agency_id AND s.status = 'active'
       AND s.customer_label = public.customer_label(NEW) AND p.line_of_business = NEW.policy_line
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
  v_left := public.cancel_window_fraction_left(NEW.policy_line, sp.submitted_date, NEW.canceled_on);
  UPDATE public.cancelation_log SET matched_sale_product_id = sp.id, window_fraction_left = v_left WHERE id = NEW.id;

  -- The household's phone and link travel both ways. A matched sale that has
  -- none takes the cancelation's (Peter 2026-09-20).
  UPDATE public.sales_log
     SET phone_last4 = COALESCE(phone_last4, NEW.phone_last4),
         ecrm_opportunity_url = CASE WHEN COALESCE(btrim(ecrm_opportunity_url), '') = ''
                                     THEN NULLIF(btrim(COALESCE(NEW.ecrm_url, '')), '')
                                     ELSE ecrm_opportunity_url END,
         updated_at = now()
   WHERE id = sp.sale_id
     AND ((phone_last4 IS NULL AND NEW.phone_last4 IS NOT NULL)
       OR (COALESCE(btrim(ecrm_opportunity_url), '') = '' AND COALESCE(btrim(NEW.ecrm_url), '') <> ''));

  IF sp.multiline_credit_id IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO cr FROM public.retention_activity_now WHERE id = sp.multiline_credit_id AND status = 'credited';
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
      customer_first_name, customer_last_initial, customer_kind, note, points, source, source_id, created_by)
    VALUES (NEW.agency_id, cr.team_member_id, 'multiline_chargeback', NEW.canceled_on, public.rp_week_end(NEW.canceled_on), v_cur_week,
      NEW.customer_first_name, NEW.customer_last_initial, NEW.customer_kind,
      'Chargeback: ' || NEW.policy_line || ' sold ' || to_char(sp.submitted_date, 'Mon FMDD') || ' canceled ' || to_char(NEW.canceled_on, 'Mon FMDD') ||
        ', ' || round(v_left * 100) || '% of the window left',
      -v_pts, 'cancelation_log', NEW.id, NEW.created_by)
    RETURNING id INTO v_id;
    UPDATE public.cancelation_log SET chargeback_points = v_pts, chargeback_activity_id = v_id WHERE id = NEW.id;
  END IF;
  RETURN NEW;
END $function$;

