-- Assessment length trim (Peter approved 2026-08-02).
-- Deactivate only. Nothing deleted. Reversible by flipping is_active back.

-- 2a. Scenario section 40 -> 20. Drop 5 of 10 topics.
UPDATE public.hiregauge_instrument_items
SET is_active = false, updated_at = now()
WHERE section = 'newtworks_v2_sjt'
  AND hypothesized_trait IN (
    'sjt_documentation_discipline',
    'sjt_feedback_channel_discipline',
    'sjt_peer_accountability',
    'sjt_service_within_process',
    'sjt_speaking_up_judgment'
  );

-- 2b. Integrity gate 33 -> 18. Five baseline + one retest per facet.
-- Kept items chosen for keyed balance (each facet retains reverse-worded items,
-- required by the long-string careless-response check) and content breadth,
-- and every retested baseline item is retained.
--   sincerity  keep 7, 9, 11(retested by 224), 13, 15   drop 8, 10, 12, 14, 16
--   fairness   keep 19, 21(retested by 225), 23, 24, 25 drop 17, 18, 20, 22, 26
--   greed_av.  keep 27, 29, 31(retested by 226), 32, 36 drop 28, 30, 33, 34, 35
-- Source scale: IPIP-HEXACO 10-item facet scales, Ashton, Lee & Goldberg 2007,
-- Personality and Individual Differences 42:1515-1526.
UPDATE public.hiregauge_instrument_items
SET is_active = false, updated_at = now()
WHERE section = 'newtworks_v2_personality'
  AND item_number IN (8,10,12,14,16, 17,18,20,22,26, 28,30,33,34,35);

-- 2c. Vocabulary 16 -> 8. Move 4 real words (one per difficulty tier) into
-- Stint 1 so the 4 made-up words are no longer the only vocabulary items a
-- candidate sees there. Over-claiming measurement requires the made-up words
-- to be indistinguishable from real ones (Paulhus, Harms, Bruce & Lysy 2003,
-- Journal of Personality and Social Psychology 84(4):890-904).
UPDATE public.hiregauge_instrument_items
SET stint = 1, updated_at = now()
WHERE item_number IN (333, 335, 340, 342);

UPDATE public.hiregauge_instrument_items
SET is_active = false, updated_at = now()
WHERE item_number IN (334, 336, 339, 341, 350, 351, 356, 357);
