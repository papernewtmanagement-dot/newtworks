-- Fix three cognitive items flagged as too hard / ambiguous.
-- Item IDs preserved; only content changes so no downstream refs break.
-- Historical responses (Peter smoke-test + Alvi, both slated for cleanup) are unaffected;
-- is_correct booleans stay frozen on those response rows.

-- #40: factorials (too specialized) → difference-of-differences +3,+5,+7,+9
UPDATE public.hiregauge_instrument_items
SET item_text = 'In the following number series, what number comes next? 3, 6, 11, 18, ?',
    choices    = '["24","25","27","29","32"]'::jsonb,
    answer_key = '27',
    notes      = 'newtworks_v1_cognitive | number_series | hard | difference-of-differences +3,+5,+7,+9; replaced factorial item (too specialized) 2026-07-30',
    updated_at = NOW()
WHERE section='cognitive' AND stint=1 AND item_number=40;

-- #44: squares-mapped-to-alphabet (two-layer translation) → single-layer progressive step +1,+2,+3,+4
UPDATE public.hiregauge_instrument_items
SET item_text = 'In the following letter series, what letter comes next? A, B, D, G, ?',
    choices    = '["I","J","K","L","M"]'::jsonb,
    answer_key = 'K',
    notes      = 'newtworks_v1_cognitive | letter_series | medium-hard | single-layer progressive step +1,+2,+3,+4; replaced squares-to-alphabet two-layer item 2026-07-30',
    updated_at = NOW()
WHERE section='cognitive' AND stint=1 AND item_number=44;

-- #48: ambiguous distractor "professional" → "mentor" (item + key unchanged)
UPDATE public.hiregauge_instrument_items
SET choices    = '["student","master","teacher","mentor","supervisor"]'::jsonb,
    notes      = 'newtworks_v1_cognitive | analogy | hard | beginner-to-endpoint pair on skill progression; distractor "professional" -> "mentor" for ambiguity reduction 2026-07-30',
    updated_at = NOW()
WHERE section='cognitive' AND stint=1 AND item_number=48;
