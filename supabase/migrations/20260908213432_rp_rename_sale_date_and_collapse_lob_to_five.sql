-- sale_date -> submitted_date
ALTER TABLE public.sales_log RENAME COLUMN sale_date TO submitted_date;
COMMENT ON COLUMN public.sales_log.submitted_date IS 'Date the business was submitted.';

-- the State Farm source wording is no longer kept verbatim
ALTER TABLE public.sales_log DROP COLUMN IF EXISTS marketing_source_raw;

-- lines of business collapse to Auto / Fire / Life / Health / Variable.
-- Commercial (business insurance, contractors, workers compensation) books
-- under Fire, the same way State Farm books it for agency compensation.
UPDATE public.product_types SET line_of_business = 'fire', sort_order = sort_order + 100
 WHERE line_of_business = 'business';
DELETE FROM public.product_types WHERE line_of_business = 'bank';

ALTER TABLE public.sales_log_products DROP CONSTRAINT IF EXISTS sales_log_products_line_of_business_check;
ALTER TABLE public.sales_log_products ADD CONSTRAINT sales_log_products_line_of_business_check
  CHECK (line_of_business = ANY (ARRAY['auto'::text,'fire'::text,'life'::text,'health'::text,'variable'::text]));

ALTER TABLE public.quote_log_products DROP CONSTRAINT IF EXISTS quote_log_products_line_check;
ALTER TABLE public.quote_log_products ADD CONSTRAINT quote_log_products_line_check
  CHECK (line_of_business = ANY (ARRAY['auto'::text,'fire'::text,'life'::text,'health'::text,'variable'::text]));
