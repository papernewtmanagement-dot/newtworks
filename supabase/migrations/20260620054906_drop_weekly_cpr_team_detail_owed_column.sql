-- Step 8.5 ships the recursive function that no longer reads prior_d.owed.
-- No writers reference this column. All 10 existing rows have owed=0.
-- Safe to drop.
ALTER TABLE public.weekly_cpr_team_detail DROP COLUMN owed;
