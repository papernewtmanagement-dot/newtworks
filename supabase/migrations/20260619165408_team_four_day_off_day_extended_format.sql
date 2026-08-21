-- Replace the old constraint (capitalized full weekday only) with one that
-- accepts the agreed format: lowercase weekday with optional _am/_pm suffix,
-- joined by + for combinations. No existing rows have non-NULL values, so
-- this is a constraint shift with zero data impact.
ALTER TABLE public.team DROP CONSTRAINT IF EXISTS team_four_day_off_day_check;

ALTER TABLE public.team ADD CONSTRAINT team_four_day_off_day_check
CHECK (
  four_day_off_day IS NULL
  OR four_day_off_day ~ '^(monday|tuesday|wednesday|thursday|friday)(_am|_pm)?(\+(monday|tuesday|wednesday|thursday|friday)(_am|_pm)?)*$'
);
