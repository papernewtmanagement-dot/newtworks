-- Peter directive 2026-08-05: enterprising activity items must carry their own
-- frame in the item text. On his self-test he read "Manage a retail store" as
-- a claim ("I manage...") and answered strongly-disagree because he doesn't
-- manage those businesses — the wrong construct entirely. The spirit of the
-- O*NET Interest Profiler source (20260801041500 ingest) is "how much would
-- you LIKE to do each activity"; per Peter's "I could see myself / I would
-- like to" direction, all ten items become "I would enjoy ..." full sentences.
-- This also moves them onto the standard 5-point agreement anchors (one less
-- special case in the candidate page — the like/dislike anchor branch is
-- removed in the same-day frontend commit). Same 1–5 range, same +keying,
-- same polarity (enjoying the activity = higher enterprising interest), so
-- scoring is untouched. Item 233 is the verbatim retest copy of item 113 and
-- is updated in lockstep (retest rows must stay byte-identical to their
-- originals — see 20260803204512 FIX B).

UPDATE public.hiregauge_instrument_items
SET item_text = CASE item_number
      WHEN 109 THEN 'I would enjoy buying and selling stocks and bonds.'
      WHEN 110 THEN 'I would enjoy negotiating business contracts.'
      WHEN 111 THEN 'I would enjoy managing a retail store.'
      WHEN 112 THEN 'I would enjoy representing a client in a lawsuit.'
      WHEN 113 THEN 'I would enjoy operating a beauty salon or barber shop.'
      WHEN 114 THEN 'I would enjoy marketing a new line of clothing.'
      WHEN 115 THEN 'I would enjoy managing a department within a large company.'
      WHEN 116 THEN 'I would enjoy selling merchandise at a department store.'
      WHEN 117 THEN 'I would enjoy starting my own business.'
      WHEN 118 THEN 'I would enjoy managing a clothing store.'
      WHEN 233 THEN 'I would enjoy operating a beauty salon or barber shop.'
    END,
    notes = COALESCE(notes || E'\n', '') || '2026-08-05: reworded to "I would enjoy ..." full sentence per Peter — bare activity phrase read as a claim on the candidate page. Construct (activity liking) and keying unchanged.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality'
  AND hypothesized_trait = 'enterprising'
  AND item_number IN (109,110,111,112,113,114,115,116,117,118,233)
  AND item_text NOT LIKE 'I would enjoy%';
