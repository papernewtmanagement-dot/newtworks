-- Peter-approved 2026-08-07. Two dutifulness items whose rewording drifted away
-- from what the facet measures.
--
-- 172 was sourced from the plain "tell the truth" dutifulness item. The reworded
-- text ("There are things I'd rather not say out loud, and I say them anyway")
-- reads as bluntness rather than honesty, so a candidate answering it truthfully
-- was answering a different question than the facet intends. Restored to
-- truth-telling content. Stays forward-scored.
--
-- 176 was sourced from the reverse-keyed "gets others to do my duties" item. The
-- reworded text described ordinary sensible delegation, which is desirable
-- behavior in a retention seat -- and because the item is reverse-scored, every
-- good delegator was being marked LESS dutiful for it. Restored to shirking
-- content (leaving your own work for someone else to absorb). Stays
-- reverse-scored.
--
-- reverse_coded unchanged on both; only the sentence changes.

UPDATE public.hiregauge_instrument_items
SET item_text = 'I tell people the truth even when it would be easier not to.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality'
  AND item_number = 172
  AND item_text = 'There are things I''d rather not say out loud, and I say them anyway.';

UPDATE public.hiregauge_instrument_items
SET item_text = 'When I''m busy, I''ve left parts of my own job for someone else to pick up.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality'
  AND item_number = 176
  AND item_text = 'When my plate is full, I hand off the parts of my job someone else could cover.';
