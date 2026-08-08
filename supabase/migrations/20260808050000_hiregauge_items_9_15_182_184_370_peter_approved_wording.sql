-- Peter-approved wording, 2026-08-08. Five items whose text had drifted off the
-- published source content or, in 370's case, off the slot the item occupies.
-- reverse_coded unchanged on all five; only the sentence changes.
--
-- 9  sincerity (reverse-scored). Source: "Tell other people what they want to
--    hear so that they will do what I want them to do." (IPIP-HEXACO Sincerity
--    item 3, Ashton, Lee & Goldberg 2007). Prior wording described starting from
--    common ground, which is ordinary persuasion and not insincerity, so it
--    penalized competent salespeople. General "you" framing keeps the item
--    endorsable by someone answering honestly.
--
-- 15 sincerity (reverse-scored). Source: "Find it necessary to please the people
--    who have power." (same scale, item 9). Prior wording described ordinary
--    awareness of what a manager wants, which nearly everyone endorses, so it
--    docked sincerity almost universally and discriminated poorly.
--
-- 182 achievement striving. Source: "Plunge into tasks with all my heart."
--    Prior wording added a downside not present in the source ("other things
--    slide"), which invited disagreement from exactly the high performers the
--    item is meant to identify.
--
-- 184 achievement striving. Source: "Set high standards for myself and others."
--    Prior wording kept only the standards-for-others half. Restored to the
--    source content with a first-person subject, per Peter.
--
-- 370 customer orientation (reverse-scored). This item sits in the
--    selling-pressure trio (370, 371, 374) opposite the customer-first trio
--    (365, 367, 369). Prior wording described deferring to a customer's coverage
--    decision -- which is the agency's own stated position and the compliant
--    answer -- so being reverse-scored it marked down candidates for answering
--    correctly and rewarded willingness to push. Replaced with content that is
--    genuinely undesirable (prioritizing the customer's comfort over the
--    customer's understanding) and has no obvious intended answer.

UPDATE public.hiregauge_instrument_items
SET item_text = 'Sometimes you have to tell people what they want to hear just to keep things moving.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality' AND item_number = 9;

UPDATE public.hiregauge_instrument_items
SET item_text = 'Sometimes it''s better to let a manager think I agree than to say what I actually think.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality' AND item_number = 15;

UPDATE public.hiregauge_instrument_items
SET item_text = 'Once I start something, I throw myself into it completely.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality' AND item_number = 182;

UPDATE public.hiregauge_instrument_items
SET item_text = 'I set high standards for myself and others.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality' AND item_number = 184;

UPDATE public.hiregauge_instrument_items
SET item_text = 'When a customer turns down coverage, keeping them comfortable matters more than making sure they understood what they turned down.',
    updated_at = NOW()
WHERE section = 'newtworks_v2_personality' AND item_number = 370;
