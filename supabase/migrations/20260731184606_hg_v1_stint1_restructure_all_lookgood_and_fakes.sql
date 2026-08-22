-- Move all look-good (impression_mgmt) items to stint=1 so every candidate gets scored on the full 10.
-- Move all vocabulary check items to stint=1 and add 4 new fake words so every candidate sees 8 fakes.
-- Retire the two expansion triggers that become dead after this restructure.

-- 1. Move all impression_mgmt items to stint=1 (was: 5 stint=1, 5 stint=2)
UPDATE public.hiregauge_instrument_items
SET stint = 1, updated_at = NOW()
WHERE section = 'newtworks_v1_impression_mgmt'
  AND stint = 2
  AND is_active = true;

-- 2. Move all vct items (real + fake) to stint=1 (was: 6 stint=1, 6 stint=2)
UPDATE public.hiregauge_instrument_items
SET stint = 1, updated_at = NOW()
WHERE section = 'newtworks_v1_vct'
  AND stint = 2
  AND is_active = true;

-- 3. Add 4 new fake vocabulary items at stint=1 to reach the 8-fake research minimum.
INSERT INTO public.hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, is_nonsense, stint, is_active, scale_max, notes)
VALUES
  ('newtworks_v1_vct', 13,
   'What does the word "borvide" mean?',
   '["a small mechanical fastener used in cabinetry","an obsolete unit of measurement for grain","a temporary shelter used by shepherds","a coastal plant with silvery leaves","None of these"]'::jsonb,
   'None of these', true, 1, true, null,
   'Newtworks over-claiming nonsense word — Paulhus et al. 2003 over-claiming technique analog'),
  ('newtworks_v1_vct', 14,
   'What does the word "trantle" mean?',
   '["to walk with a light, uneven step","a small basket used for gathering herbs","a formal apology in old English law","an early type of hand-cranked press","None of these"]'::jsonb,
   'None of these', true, 1, true, null,
   'Newtworks over-claiming nonsense word — Paulhus et al. 2003 over-claiming technique analog'),
  ('newtworks_v1_vct', 15,
   'What does the word "plembic" mean?',
   '["a substance used to seal older windows","relating to the study of small crystals","a mild but chronic condition of the skin","sluggish or heavy in movement","None of these"]'::jsonb,
   'None of these', true, 1, true, null,
   'Newtworks over-claiming nonsense word — Paulhus et al. 2003 over-claiming technique analog'),
  ('newtworks_v1_vct', 16,
   'What does the word "garvix" mean?',
   '["a decorative border in medieval manuscripts","an old military rank between sergeant and corporal","a coarse-grained stone used in flooring","a small enclosed courtyard","None of these"]'::jsonb,
   'None of these', true, 1, true, null,
   'Newtworks over-claiming nonsense word — Paulhus et al. 2003 over-claiming technique analog');

-- 4. Retire dead expansion triggers (their target pools are now empty in stint=2).
UPDATE public.hiregauge_expansion_triggers
SET is_active = false, updated_at = NOW(),
    notes = COALESCE(notes,'') || ' | Retired 2026-07-31: stint-2 look-good/nonsense pool emptied by stint-1 restructure.'
WHERE trigger_name IN ('elevated_impression_mgmt','nonsense_inflation')
  AND is_active = true;
