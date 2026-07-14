-- 2026-07-13: add 'applied' to team_assessments.status CHECK constraint.
-- New kanban column landing zone for CareerPlug applicants before CTS is
-- completed. Every other status value preserved.

ALTER TABLE public.team_assessments
  DROP CONSTRAINT IF EXISTS team_assessments_status_check;

ALTER TABLE public.team_assessments
  ADD CONSTRAINT team_assessments_status_check
    CHECK (status IS NULL OR status = ANY (ARRAY[
      'applied'::text,
      'assessed'::text,
      'email_screen'::text,
      'interview'::text,
      'reference_check'::text,
      'offer'::text,
      'hired'::text,
      'declined'::text,
      'archived'::text
    ]));
