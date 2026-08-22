-- Peter 2026-08-05, two fixes:
--
-- 1) Item 382 (VandeWalle prove-orientation) read long and confusing. The
--    "figure out what it takes to" clause is scaffolding; the construct —
--    wanting to demonstrate ability to others — survives intact in the short
--    form. +keying, 6-pt scale, no retest copy (verified: nothing has
--    retest_of_item_number = 382).
--
-- 2) Peter noticed some questions "repeated more than twice." Verbatim
--    repeats are capped at two by design (original + spaced consistency
--    retest), verified across the whole active bank. The real 3x-feeling
--    cluster: proactive items 73 and 77 are near-twin sentences in the
--    published scale, AND 73 also carried the consistency copy (230) — so the
--    same idea read three times in one stint. Repointing 230 to item 72
--    ("If I see something I don't like, I fix it."), which has no twin,
--    kills the cluster while keeping proactive retest coverage. Retest rows
--    stay verbatim duplicates of their originals; same trait, same 7-pt
--    scale, same +keying on both 72 and 73.

UPDATE public.hiregauge_instrument_items
SET item_text = 'I try to prove my ability to others at work.',
    notes = COALESCE(notes || E'\n', '') || '2026-08-05: shortened from "I try to figure out what it takes to prove my ability to others at work." per Peter — construct preserved.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality' AND item_number = 382
  AND item_text = 'I try to figure out what it takes to prove my ability to others at work.';

UPDATE public.hiregauge_instrument_items
SET item_text = 'If I see something I don''t like, I fix it.',
    retest_of_item_number = 72,
    notes = COALESCE(notes || E'\n', '') || '2026-08-05: retest repointed 73 -> 72. Items 73/77 are published near-twins; with the retest also on 73, candidates read the same idea three times (Peter flagged). Item 72 has no twin.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality' AND item_number = 230
  AND retest_of_item_number = 73;
