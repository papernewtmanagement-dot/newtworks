-- Extend team_weekly_snapshot with hire_date (stable field) for frontend join
-- convenience. Backfill from live team. Update trigger to include hire_date.

ALTER TABLE public.team_weekly_snapshot ADD COLUMN IF NOT EXISTS hire_date date;

UPDATE public.team_weekly_snapshot s
SET hire_date = t.hire_date
FROM public.team t
WHERE t.id = s.team_member_id
  AND s.hire_date IS NULL;

-- (Trigger fn already contains hire_date at the schema-migration point; kept here as no-op safeguard.)
