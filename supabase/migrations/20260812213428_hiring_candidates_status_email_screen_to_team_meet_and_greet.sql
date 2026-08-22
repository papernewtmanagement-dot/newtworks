-- Recruiting Kanban restructure (Peter directive 2026-08-12):
-- email_screen folded into end of assessment, no longer a separate pipeline stage.
-- interview moves back into the Recruiting tab; team_meet_and_greet is a new
-- Finalists-tab stage sitting where interview used to (right after interview,
-- before reference_check).
ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT team_assessments_status_check;

ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT team_assessments_status_check
  CHECK (
    status IS NULL OR status = ANY (ARRAY[
      'applied'::text, 'assessment_sent'::text, 'assessed'::text,
      'interview'::text, 'team_meet_and_greet'::text, 'reference_check'::text,
      'offer'::text, 'hired'::text, 'declined'::text, 'former'::text
    ])
  );

COMMENT ON CONSTRAINT team_assessments_status_check ON public.hiring_candidates IS
  'Pipeline stage enum. email_screen retired 2026-08-12 (folded into end of assessment). team_meet_and_greet added same date as new Finalists-tab stage between interview and reference_check.';

