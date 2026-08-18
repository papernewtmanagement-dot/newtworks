ALTER TABLE public.amazon_orders
  ADD COLUMN IF NOT EXISTS category text,
  ADD COLUMN IF NOT EXISTS matched_cash_register_id uuid REFERENCES public.cash_register_preliminary(id);

CREATE INDEX IF NOT EXISTS idx_amazon_orders_matched_cash_register ON public.amazon_orders(matched_cash_register_id);
