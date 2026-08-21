-- STEP 2 of 2. The deployed front end is now writing meet_and_greet
-- (commit 17a2607f, live). The old spelling team_meet_and_greet is removed
-- from the allowed set so it cannot come back.

ALTER TABLE public.hiring_candidates DROP CONSTRAINT IF EXISTS team_assessments_status_check;

ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT team_assessments_status_check
  CHECK (
    status IS NULL OR status = ANY (ARRAY[
      'applied'::text, 'assessment_sent'::text, 'assessed'::text,
      'interview'::text, 'meet_and_greet'::text,
      'offer'::text, 'reference_check'::text,
      'hired'::text, 'declined'::text, 'former'::text
    ])
  );

COMMENT ON COLUMN public.hiring_candidates.status IS
  'Pipeline stage. Order as displayed: applied, assessment_sent, assessed, interview, meet_and_greet, offer, reference_check, hired. declined and former sit off the pipeline. email_screen retired 2026-08-12. Two changes 2026-08-20: offer and reference_check swapped (the offer is written as contingent on references clearing), and team_meet_and_greet renamed to meet_and_greet.';
