-- One place validates a single sold/edited policy line. Used by rp_log_sale and rp_edit_sale.
CREATE OR REPLACE FUNCTION public.rp_check_sale_product(p_agency uuid, p_prod jsonb)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_lob text; v_prem numeric; v_veh integer;
BEGIN
  v_lob := lower(COALESCE(p_prod->>'line_of_business',''));
  IF v_lob NOT IN ('auto','fire','life','health','variable','bank') THEN RAISE EXCEPTION 'unknown product: %', v_lob; END IF;
  PERFORM public.rp_check_product_type(p_agency, v_lob, p_prod->>'product_type');
  v_prem := NULLIF(p_prod->>'premium','')::numeric;
  IF v_prem IS NULL OR v_prem < 0 THEN RAISE EXCEPTION 'premium required for %', v_lob; END IF;
  IF v_prem > 1000000 THEN RAISE EXCEPTION 'premium for % looks too large. Double-check it.', v_lob; END IF;
  IF v_lob = 'auto' THEN
    v_veh := NULLIF(p_prod->>'vehicle_count','')::integer;
    IF v_veh IS NULL OR v_veh < 1 THEN RAISE EXCEPTION 'how many cars on the auto policy?'; END IF;
  END IF;
  IF NULLIF(p_prod->>'issued_premium','') IS NOT NULL AND NULLIF(p_prod->>'issued_premium','')::numeric < 0 THEN
    RAISE EXCEPTION 'issued premium cannot be negative';
  END IF;
  RETURN true;
END $function$;

GRANT EXECUTE ON FUNCTION public.rp_check_sale_product(uuid, jsonb) TO authenticated;
