-- Replace three cognitive items that gave zero discriminative signal on any adult.
-- Item IDs preserved; only content changes. Historical responses were tied to the
-- deleted smoke-test rows and are already gone. No real candidates have answered
-- these items yet (send_v1_assessment_invitations recipe still paused).

-- #36 (math, was "2,4,6,8,?" = 10 — counting by twos, trivial)
-- New: differences +9, +10, +11, +12 — genuine medium difficulty
UPDATE public.hiregauge_instrument_items
SET item_text = 'In the following number series, what number comes next? 18, 27, 37, 48, ?',
    choices    = '["57","59","60","62","65"]'::jsonb,
    answer_key = '60',
    notes      = 'newtworks_v1_cognitive | number_series | medium | progressive-difference +9,+10,+11,+12; replaced trivial "2,4,6,8" gimme 2026-07-31',
    updated_at = NOW()
WHERE section='cognitive' AND stint=1 AND item_number=36;

-- #41 (verbal, was "A,B,C,D,?" = E — alphabet, trivial)
-- New: skip-two-forward letter series, positions +3 each step
UPDATE public.hiregauge_instrument_items
SET item_text = 'In the following letter series, what letter comes next? B, E, H, K, ?',
    choices    = '["L","M","N","O","P"]'::jsonb,
    answer_key = 'N',
    notes      = 'newtworks_v1_cognitive | letter_series | medium | skip-two-forward +3 each step; replaced trivial "A,B,C,D" gimme 2026-07-31',
    updated_at = NOW()
WHERE section='cognitive' AND stint=1 AND item_number=41;

-- #60 (math, was "3 apples $6, 5 apples $?" = $10 — trivial ratio)
-- New: workplace-numeracy word problem, requires rate computation + multiplication
UPDATE public.hiregauge_instrument_items
SET item_text = 'Sarah drives 240 miles on 8 gallons of gas. At the same rate, how far can she drive on 12 gallons?',
    choices    = '["280 miles","320 miles","360 miles","400 miles","480 miles"]'::jsonb,
    answer_key = '360 miles',
    notes      = 'newtworks_v1_cognitive | word_problem | medium | rate then scale: 240/8=30 mpg, 12*30=360; replaced trivial "3 apples $6" gimme 2026-07-31',
    updated_at = NOW()
WHERE section='cognitive' AND stint=1 AND item_number=60;
