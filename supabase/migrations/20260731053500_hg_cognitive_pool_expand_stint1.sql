-- Move 5 keeper cognitive items from inactive stint=2 into active stint=1 pool.
-- This creates a 22-item pool from which the v1-assessment edge fn deterministically
-- selects 17 per candidate (6 math, 5 problem_solving, 6 verbal) via cyrb53-hashed
-- form rotation. Item #45 (B,D,H,N,?) stays inactive — its acceleration-pattern
-- structure duplicates the already-active #38 pattern (squares) too closely.

UPDATE public.hiregauge_instrument_items
SET stint = 1, is_active = true, updated_at = NOW(),
    notes = notes || ' | promoted to stint 1 active pool 2026-07-31 (cognitive form rotation)'
WHERE section = 'cognitive'
  AND stint = 2
  AND item_number IN (39, 42, 52, 53, 63);
