-- Peter 2026-09-20: James W. showed in the backfill with no phone and no ECRM
-- link, while the five cancelations the team logged for him on 9/19 carry both
-- (phone 0757). When a cancelation is matched to a sale, the phone and link
-- only ever flowed sale -> cancelation. Now they also flow back: a matched sale
-- that has none takes the cancelation's. Blanks only; nothing on file is
-- overwritten.

DO $mig$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'cancelation_log_chargeback';

  v_def := replace(v_def,
    $old$  UPDATE public.cancelation_log SET matched_sale_product_id = sp.id, window_fraction_left = v_left WHERE id = NEW.id;$old$,
    $new$  UPDATE public.cancelation_log SET matched_sale_product_id = sp.id, window_fraction_left = v_left WHERE id = NEW.id;

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
       OR (COALESCE(btrim(ecrm_opportunity_url), '') = '' AND COALESCE(btrim(NEW.ecrm_url), '') <> ''));$new$);

  IF v_def NOT LIKE '%The household''s phone and link travel both ways%' THEN
    RAISE EXCEPTION 'cancelation_log_chargeback did not match the expected shape; not patching blind';
  END IF;
  EXECUTE v_def;
END $mig$;

-- The same fill for cancelations already on file.
UPDATE public.sales_log s
   SET phone_last4 = COALESCE(s.phone_last4, c.phone_last4),
       ecrm_opportunity_url = CASE WHEN COALESCE(btrim(s.ecrm_opportunity_url), '') = ''
                                   THEN NULLIF(btrim(COALESCE(c.ecrm_url, '')), '')
                                   ELSE s.ecrm_opportunity_url END,
       updated_at = now()
  FROM public.cancelation_log c
  JOIN public.sales_log_products p ON p.id = c.matched_sale_product_id
 WHERE p.sales_log_id = s.id
   AND c.status = 'active' AND s.status = 'active'
   AND ((s.phone_last4 IS NULL AND c.phone_last4 IS NOT NULL)
     OR (COALESCE(btrim(s.ecrm_opportunity_url), '') = '' AND COALESCE(btrim(c.ecrm_url), '') <> ''));
