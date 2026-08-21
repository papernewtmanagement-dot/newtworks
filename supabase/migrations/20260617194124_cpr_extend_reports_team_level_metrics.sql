ALTER TABLE public.weekly_cpr_reports
  ADD COLUMN IF NOT EXISTS quotes_owed_carryover integer,
  ADD COLUMN IF NOT EXISTS quotes_fresh_needed integer,
  ADD COLUMN IF NOT EXISTS quotes_total_net integer,
  ADD COLUMN IF NOT EXISTS quotes_owed_next_week integer,
  ADD COLUMN IF NOT EXISTS quarterly_sales_points_target numeric(8,2),
  ADD COLUMN IF NOT EXISTS quarterly_sales_points_qtd numeric(8,2),
  ADD COLUMN IF NOT EXISTS won_the_week boolean;
