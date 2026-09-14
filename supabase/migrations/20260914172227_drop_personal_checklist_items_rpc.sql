-- The Checklist tab now reads personal items out of daily_checklist_state along
-- with their ticks, so this second read path has no callers left.
DROP FUNCTION IF EXISTS public.personal_checklist_items(date);
