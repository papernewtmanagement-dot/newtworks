-- Re-apply the 2026-07-30 approved reword of impression-management item 303
-- ("Have sometimes had to tell a lie." -> "Have sometimes told a lie.",
-- dropping the "had to" compulsion ambiguity per Peter's smoke-test feedback).
--
-- The original attempt (20260731000004) never took effect: its WHERE clause
-- guarded on the NEW text instead of the OLD text, and it also targeted row id
-- 62cbd9af-..., which no longer exists (the v2 ingest re-created the item under
-- a new id). The UPDATE matched zero rows and production kept serving the old
-- wording. Guard below matches the OLD text, so it is idempotent the right way
-- around: applies once, no-op thereafter.
UPDATE public.hiregauge_instrument_items
SET item_text = 'Have sometimes told a lie.',
    notes = COALESCE(notes || E'\n', '') || '2026-08-05: reword re-applied. 20260731000004 guarded on the new text (and a stale row id), so the approved 2026-07-30 change never landed.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality'
  AND item_number = 303
  AND item_text = 'Have sometimes had to tell a lie.';
