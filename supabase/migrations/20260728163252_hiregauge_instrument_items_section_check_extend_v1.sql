-- Newtworks v1 Stint 2 build — schema fix required by step 5.
-- The existing CHECK on hiregauge_instrument_items.section allows only
--   ('instructions','vct','cognitive','cts','newtworks_v1_personality')
-- Step 5 introduces 'newtworks_v1_impression_mgmt' and step 6 introduces
-- 'newtworks_v1_vct'. Extend the allow-list without dropping any current
-- value.
ALTER TABLE public.hiregauge_instrument_items
  DROP CONSTRAINT IF EXISTS hiregauge_instrument_items_section_check;

ALTER TABLE public.hiregauge_instrument_items
  ADD CONSTRAINT hiregauge_instrument_items_section_check
  CHECK (section = ANY (ARRAY[
    'instructions'::text,
    'vct'::text,
    'cognitive'::text,
    'cts'::text,
    'newtworks_v1_personality'::text,
    'newtworks_v1_impression_mgmt'::text,
    'newtworks_v1_vct'::text
  ]));
