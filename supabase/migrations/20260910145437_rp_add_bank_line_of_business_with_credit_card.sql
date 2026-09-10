-- Peter ruling 2026-09-10: Bank returns as a line of business, with Credit Card as a
-- product under it. This reverses the 2026-09-08 removal of bank (migration
-- 20260908213432), which deleted the bank product types and dropped bank from the
-- allowed list. Auto / Fire / Life / Health / Variable are untouched, and Commercial
-- still books under Fire.
--
-- NOTE ON PAY: the compensation math reads the capitalised Auto / Fire / Life / Health
-- values in producer_production. Bank is not one of them, so bank premium is recorded
-- and reported but does not flow into compensation.

ALTER TABLE public.sales_log_products DROP CONSTRAINT IF EXISTS sales_log_products_line_of_business_check;
ALTER TABLE public.sales_log_products ADD CONSTRAINT sales_log_products_line_of_business_check
  CHECK (line_of_business = ANY (ARRAY['auto'::text,'fire'::text,'life'::text,'health'::text,'variable'::text,'bank'::text]));

ALTER TABLE public.quote_log_products DROP CONSTRAINT IF EXISTS quote_log_products_line_check;
ALTER TABLE public.quote_log_products ADD CONSTRAINT quote_log_products_line_check
  CHECK (line_of_business = ANY (ARRAY['auto'::text,'fire'::text,'life'::text,'health'::text,'variable'::text,'bank'::text]));

INSERT INTO public.product_types (agency_id, line_of_business, type_key, label, sort_order, is_active) VALUES
  ('126794dd-25ff-47d2-a436-724499733365','bank','credit_card','Credit Card',10,true)
ON CONFLICT DO NOTHING;