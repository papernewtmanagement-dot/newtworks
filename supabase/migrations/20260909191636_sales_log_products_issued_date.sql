ALTER TABLE public.sales_log_products ADD COLUMN IF NOT EXISTS issued_date date;
COMMENT ON COLUMN public.sales_log_products.issued_date IS 'Date this policy issued. Policies in one sale can issue on different days.';
COMMENT ON COLUMN public.sales_log.issued_date IS 'Earliest issue date across the policies in this sale. Per-policy dates live on sales_log_products.';
