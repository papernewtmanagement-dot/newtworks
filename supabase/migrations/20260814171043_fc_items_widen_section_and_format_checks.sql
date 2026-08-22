-- Admit the forced-choice personality section and its response format (additive
-- widening only; companion to the fc_personality_pairs content migrations).
ALTER TABLE public.hiregauge_instrument_items
  DROP CONSTRAINT IF EXISTS hiregauge_instrument_items_section_check;
ALTER TABLE public.hiregauge_instrument_items
  ADD CONSTRAINT hiregauge_instrument_items_section_check
  CHECK (section = ANY (ARRAY['instructions'::text,'vct'::text,'cognitive'::text,'cts'::text,
    'newtworks_v1_personality'::text,'newtworks_v1_impression_mgmt'::text,'newtworks_v1_vct'::text,
    'newtworks_v2_personality'::text,'newtworks_v2_cognitive_gma'::text,'newtworks_v2_impression_mgmt'::text,
    'newtworks_v2_vct'::text,'newtworks_v2_sjt'::text,'newtworks_v2_screen'::text,
    'newtworks_v2_personality_fc'::text]));

ALTER TABLE public.hiregauge_instrument_items
  DROP CONSTRAINT IF EXISTS hiregauge_instrument_items_response_format_check;
ALTER TABLE public.hiregauge_instrument_items
  ADD CONSTRAINT hiregauge_instrument_items_response_format_check
  CHECK (response_format IS NULL OR response_format = ANY (ARRAY['free_text'::text,'vocab_familiarity'::text,'forced_choice_pair'::text]));
