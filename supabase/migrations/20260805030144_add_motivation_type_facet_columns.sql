ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS competitiveness smallint NULL CHECK (competitiveness IS NULL OR (competitiveness BETWEEN 0 AND 100)),
  ADD COLUMN IF NOT EXISTS learning_goal_orientation smallint NULL CHECK (learning_goal_orientation IS NULL OR (learning_goal_orientation BETWEEN 0 AND 100)),
  ADD COLUMN IF NOT EXISTS prove_goal_orientation smallint NULL CHECK (prove_goal_orientation IS NULL OR (prove_goal_orientation BETWEEN 0 AND 100)),
  ADD COLUMN IF NOT EXISTS avoid_goal_orientation smallint NULL CHECK (avoid_goal_orientation IS NULL OR (avoid_goal_orientation BETWEEN 0 AND 100));
