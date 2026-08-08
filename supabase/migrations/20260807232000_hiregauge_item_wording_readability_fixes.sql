-- Readability-only rewordings of three active personality items.
-- Peter directive 2026-08-07 following the removal of the "I " stem from the
-- renderer (commit 79f4cf9b): items are now shown exactly as stored, so any
-- item that reads awkwardly has to be fixed in the row itself.
-- None of the three changes what the item measures; reverse_coded is untouched.
--   179 "move at the target" is not a phrase anyone says out loud.
--   188 "tracks" used as a verb is insider phrasing.
--   149 was vague enough to be read three different ways; restored closer to
--       the source item's plain meaning (easy to satisfy).

UPDATE public.hiregauge_instrument_items
SET item_text = 'I''d rather go straight at the goal than take the route that keeps everyone comfortable.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality'
  AND item_number = 179
  AND item_text = 'I''d rather move at the target directly than take the route that keeps everyone comfortable.';

UPDATE public.hiregauge_instrument_items
SET item_text = 'How hard I work depends on how interesting the work is.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality'
  AND item_number = 188
  AND item_text = 'The amount of effort I put in tracks how much the work interests me.';

UPDATE public.hiregauge_instrument_items
SET item_text = 'I''m fairly easy to satisfy.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality'
  AND item_number = 149
  AND item_text = 'Most of the time, I don''t need much to be okay with how something turned out.';
