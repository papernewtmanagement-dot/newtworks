-- Extend hiregauge_instrument_items to support Newtworks v1 personality instrument
-- alongside existing CTS-format items.

ALTER TABLE public.hiregauge_instrument_items 
  DROP CONSTRAINT IF EXISTS hiregauge_instrument_items_section_check;

ALTER TABLE public.hiregauge_instrument_items 
  ADD CONSTRAINT hiregauge_instrument_items_section_check 
  CHECK (section IN ('instructions','vct','cognitive','cts','newtworks_v1_personality'));

ALTER TABLE public.hiregauge_instrument_items 
  ADD COLUMN IF NOT EXISTS scale_max int;

UPDATE public.hiregauge_instrument_items 
  SET scale_max = 6 
  WHERE section = 'cts' AND scale_max IS NULL;

COMMENT ON COLUMN public.hiregauge_instrument_items.scale_max IS 'Max value on the Likert scale for this item (5 for IPIP standard, 6 for CTS format). NULL for non-Likert sections (instructions, vct, cognitive). Used by scoring functions to normalize to 0-100.';
