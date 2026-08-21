ALTER TABLE public.sf_on_time_snapshot
  ADD COLUMN IF NOT EXISTS auto_production_qtd integer,
  ADD COLUMN IF NOT EXISTS auto_lapse_qtd integer,
  ADD COLUMN IF NOT EXISTS fire_production_qtd integer,
  ADD COLUMN IF NOT EXISTS fire_lapse_qtd integer,
  ADD COLUMN IF NOT EXISTS life_production_qtd integer,
  ADD COLUMN IF NOT EXISTS life_lapse_qtd integer,
  ADD COLUMN IF NOT EXISTS life_paid_count_qtd integer;
