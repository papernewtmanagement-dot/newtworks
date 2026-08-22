-- Per-bot exclusion. Legacy is_excluded continues to govern pjsagencybot (telegram edge fn).
-- New is_excluded_paper_newt_bot column governs paper_newt_bot (chatbot edge fn, and any SQL that ONLY targets paper_newt_bot).
-- Marie: excluded from pjsagencybot (admin_backoffice, no place in agency team group) but allowed on paper_newt_bot (Paper Newt Management group).
ALTER TABLE public.team_telegram_map
  ADD COLUMN IF NOT EXISTS is_excluded_paper_newt_bot BOOLEAN NOT NULL DEFAULT false;

-- Backfill: any existing is_excluded=true (terminated staff, etc.) should stay excluded from paper_newt_bot too
UPDATE public.team_telegram_map
SET is_excluded_paper_newt_bot = true
WHERE COALESCE(is_excluded, false) = true;

-- Marie: pjsagencybot excluded (is_excluded=true), paper_newt_bot allowed (is_excluded_paper_newt_bot=false)
UPDATE public.team_telegram_map
SET is_excluded = true,
    is_excluded_paper_newt_bot = false,
    excluded_reason = 'admin_backoffice: pjsagencybot only',
    updated_at = NOW()
WHERE id = 'ac99c4d5-2f01-479c-bbf9-3f83fd930fa5';

COMMENT ON COLUMN public.team_telegram_map.is_excluded IS
  'Legacy blanket flag; still governs @pjsagencybot (telegram edge fn). Prefer per-bot columns going forward.';
COMMENT ON COLUMN public.team_telegram_map.is_excluded_paper_newt_bot IS
  'Governs @paper_newt_bot (chatbot edge fn). Independent of is_excluded so admin_backoffice folks can be excluded from pjsagencybot but allowed on paper_newt_bot.';
