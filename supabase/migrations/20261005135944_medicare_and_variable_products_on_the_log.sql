ALTER TABLE public.product_types DROP CONSTRAINT IF EXISTS product_types_line_check;
ALTER TABLE public.product_types ADD CONSTRAINT product_types_line_check
  CHECK (line_of_business = ANY (ARRAY['auto','fire','business','life','health','ips','bank','variable']));
-- Peter 2026-10-05: Medicare and Variable are products the team can log.
INSERT INTO public.product_types (agency_id, line_of_business, type_key, label, sort_order)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.l, v.k, v.lbl, v.o
  FROM (VALUES ('health','medicare','Medicare',30), ('variable','variable','Variable',10)) AS v(l,k,lbl,o)
 WHERE NOT EXISTS (SELECT 1 FROM public.product_types pt WHERE pt.agency_id='126794dd-25ff-47d2-a436-724499733365' AND pt.line_of_business=v.l AND pt.type_key=v.k);
