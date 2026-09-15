-- Peter 2026-09-14: a new Private Passenger auto policy issues the day it is
-- submitted. There is nothing to wait on. Everything else stays in the
-- To be issued list until someone confirms it issued with no contingencies,
-- because we do not pay on a policy until it is not going to cancel.
--
-- One place only: a BEFORE INSERT trigger on the policy row, so every writer
-- (rp_log_sale, rp_edit_sale, anything later) gets the same behavior.
-- INSERT only on purpose: firing on UPDATE would re-issue a policy right after
-- someone deliberately un-issued it.
CREATE OR REPLACE FUNCTION public.rp_auto_issue()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_sub date;
BEGIN
  IF NEW.issued_date IS NOT NULL THEN RETURN NEW; END IF;
  IF lower(COALESCE(NEW.line_of_business, '')) <> 'auto'
     OR lower(COALESCE(NEW.product_type, '')) <> 'private_passenger' THEN
    RETURN NEW;
  END IF;
  SELECT s.submitted_date INTO v_sub FROM public.sales_log s WHERE s.id = NEW.sales_log_id;
  NEW.issued_date    := COALESCE(v_sub, public.rp_today_central());
  NEW.issued_premium := COALESCE(NEW.issued_premium, NEW.premium);
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS trg_rp_auto_issue ON public.sales_log_products;
CREATE TRIGGER trg_rp_auto_issue
BEFORE INSERT ON public.sales_log_products
FOR EACH ROW EXECUTE FUNCTION public.rp_auto_issue();

-- Un-issuing left the issued premium behind, so a policy could sit in the
-- queue carrying a number from a previous issue. Clear both together.
CREATE OR REPLACE FUNCTION public.rp_unmark_issued(p_sale_product_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE a RECORD; v_n integer;
BEGIN
  SELECT * INTO a FROM public.rp_resolve_actor(NULL);
  UPDATE public.sales_log_products p SET issued_date = NULL, issued_premium = NULL
    FROM public.sales_log s
   WHERE p.id = p_sale_product_id AND s.id = p.sales_log_id AND s.agency_id = a.agency_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('ok', v_n > 0);
END $function$;
