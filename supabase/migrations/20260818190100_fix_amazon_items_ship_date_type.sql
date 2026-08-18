-- Amazon's CSV Order History Report legitimately concatenates multiple ship
-- dates into one field for split/partial shipments ("2026-08-08T... and
-- 2026-08-07T..."), which is not valid timestamptz input. ship_date is
-- reference data, not used in date arithmetic, so stored as text.
ALTER TABLE public.amazon_order_items ALTER COLUMN ship_date TYPE text;
