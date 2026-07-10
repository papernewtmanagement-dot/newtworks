-- Add is_team_member flag on team_assessments as a generated column.
-- Derived from team_member_id IS NOT NULL so it always tracks truth automatically.
-- Never write to it directly — set team_member_id (or leave NULL for external candidates)
-- and this column follows.

ALTER TABLE public.team_assessments
  ADD COLUMN IF NOT EXISTS is_team_member boolean
    GENERATED ALWAYS AS (team_member_id IS NOT NULL) STORED;

COMMENT ON COLUMN public.team_assessments.is_team_member IS 'Generated column: true when team_member_id IS NOT NULL (person is/was on the team), false when the assessment is for an external candidate identified by candidate_name. Auto-derived — do not write directly.';
