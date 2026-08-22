-- Add 'applied' as a legal status value (pre-assessment kanban column)
ALTER TABLE public.team_assessments
  DROP CONSTRAINT IF EXISTS team_assessments_status_check;

ALTER TABLE public.team_assessments
  ADD CONSTRAINT team_assessments_status_check
    CHECK (status IS NULL OR status = ANY (ARRAY[
      'applied'::text,          -- NEW: applied via CareerPlug (or other), CTS not yet complete
      'assessed'::text,         -- CTS completed, ready for Peter to review
      'email_screen'::text,     -- 21-question written screen sent
      'interview'::text,        -- Video AMA scheduled/complete
      'reference_check'::text,
      'offer'::text,
      'hired'::text,
      'declined'::text,
      'archived'::text
    ]));
