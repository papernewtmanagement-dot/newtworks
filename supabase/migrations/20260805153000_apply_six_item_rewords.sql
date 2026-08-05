-- Peter-approved 2026-08-05: six item rewords. Five modernize dated 1982-era
-- customer-orientation phrasing (Saxe & Weitz SOCO) + one grandiose proactive-
-- personality item (Bateman & Crant) Peter flagged on his stint-2 self-test.
-- Claim strength preserved on each so facet comparability holds; scoring reads
-- numeric responses only, so these are text-only changes with zero scoring
-- surface. Guards match OLD text (lesson from 20260731000004, whose guard
-- matched the new text and silently applied nothing). None of these six items
-- has a retest copy, so no duplicate rows to keep in sync.

UPDATE public.hiregauge_instrument_items
SET item_text = $q$I have been a driving force for positive change everywhere I've worked.$q$,
    notes = COALESCE(notes || E'\n', '') || '2026-08-05: reworded from "Wherever I have been, I have been a powerful force for constructive change." per Peter — grandiose phrasing, flagged on self-test.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality' AND item_number = 70
  AND item_text = $q$Wherever I have been, I have been a powerful force for constructive change.$q$;

UPDATE public.hiregauge_instrument_items
SET item_text = $q$I enjoy standing up for my ideas, even when others push back.$q$,
    notes = COALESCE(notes || E'\n', '') || '2026-08-05: reworded from "I love being a champion for my ideas, even against others'' opposition." — stilted phrasing.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality' AND item_number = 74
  AND item_text = $q$I love being a champion for my ideas, even against others' opposition.$q$;

UPDATE public.hiregauge_instrument_items
SET item_text = $q$I offer the product that best fits the customer's problem.$q$,
    notes = COALESCE(notes || E'\n', '') || '2026-08-05: reworded from "I offer the product of mine that is best suited to the customer''s problem." — dated SOCO phrasing.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality' AND item_number = 368
  AND item_text = $q$I offer the product of mine that is best suited to the customer's problem.$q$;

UPDATE public.hiregauge_instrument_items
SET item_text = $q$I try to sell a customer as much as I can convince them to buy, even if I think it's more than a sensible person would buy.$q$,
    notes = COALESCE(notes || E'\n', '') || '2026-08-05: reworded from SOCO original — dropped "him/her", smoothed phrasing, kept the sensible-person standard.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality' AND item_number = 372
  AND item_text = $q$I try to sell a customer all I can convince him/her to buy even if I think it is more than a wise person would buy.$q$;

UPDATE public.hiregauge_instrument_items
SET item_text = $q$I paint too rosy a picture of my products, to make them appear as good as possible.$q$,
    notes = COALESCE(notes || E'\n', '') || '2026-08-05: fixed singular/plural mismatch ("my product ... them") — source SOCO item uses "products".',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality' AND item_number = 373
  AND item_text = $q$I paint too rosy a picture of my product, to make them appear as good as possible.$q$;

UPDATE public.hiregauge_instrument_items
SET item_text = $q$I decide what to offer based on what I can convince customers to buy, not what will satisfy them in the long run.$q$,
    notes = COALESCE(notes || E'\n', '') || '2026-08-05: trimmed repetitive 30-word SOCO original, meaning preserved.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality' AND item_number = 374
  AND item_text = $q$I decide what products to offer on the basis of what products I can convince customers to buy, not on the basis of what will satisfy them in the long run.$q$;
