-- Migration: fold team_telegram_map (3 essential columns) into team
-- Columns pruned: telegram_username (all NULL, dead code path), telegram_first_name/last_name (display only,
-- swapped to team.first_name/last_name), excluded_reason/mapping_method/first_seen_at/last_seen_at (0 fn refs)

-- Step 1: Add 3 essential columns to team
ALTER TABLE public.team
  ADD COLUMN IF NOT EXISTS telegram_user_id BIGINT,
  ADD COLUMN IF NOT EXISTS is_excluded_pjsagencybot BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS is_excluded_paper_newt_bot BOOLEAN NOT NULL DEFAULT FALSE;

-- Step 2: Backfill from team_telegram_map
UPDATE public.team t
SET telegram_user_id = ttm.telegram_user_id,
    is_excluded_pjsagencybot = ttm.is_excluded_pjsagencybot,
    is_excluded_paper_newt_bot = ttm.is_excluded_paper_newt_bot
FROM public.team_telegram_map ttm
WHERE ttm.team_id = t.id;

-- Step 3: Unique index on telegram_user_id (partial, allows multiple NULLs)
CREATE UNIQUE INDEX IF NOT EXISTS ux_team_telegram_user_id
  ON public.team (telegram_user_id) WHERE telegram_user_id IS NOT NULL;
