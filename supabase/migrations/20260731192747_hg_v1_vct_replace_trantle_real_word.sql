-- Dictionary sanity check found "trantle" is a real word in Scots dialect
-- (Scottish National Dictionary: "small articles of little value, odds and
-- ends, nick-nacks, gew-gaws, trinkets"). A candidate with any Scottish or
-- Middle English literary exposure could legitimately know it, producing a
-- false over-claiming signal. Replaced with "sarnith" (verified: no dictionary
-- entry, no phonetic collision with common English words).
--
-- Safe to UPDATE in place: item was created in the same session as this fix,
-- no candidate has answered it yet (verified: zero rows in
-- hiregauge_candidate_responses for this item_id).
UPDATE public.hiregauge_instrument_items
SET item_text = 'What does the word "sarnith" mean?',
    choices = '["a type of dark stone used in old buildings","a small ornamental knot in a rope","an early form of writing on cloth","a village council in medieval Europe","None of these"]'::jsonb,
    notes = 'Newtworks over-claiming nonsense word — replaced original "trantle" 2026-07-31 (turned out to be Scots dialect for odds-and-ends via SND). Paulhus et al. 2003 over-claiming technique analog.',
    updated_at = NOW()
WHERE section = 'newtworks_v1_vct'
  AND item_number = 14
  AND is_nonsense = true
  AND is_active = true;
