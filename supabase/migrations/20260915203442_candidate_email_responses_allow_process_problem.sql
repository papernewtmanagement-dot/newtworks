ALTER TABLE public.candidate_email_responses
  DROP CONSTRAINT IF EXISTS candidate_email_responses_response_type_check;

ALTER TABLE public.candidate_email_responses
  ADD CONSTRAINT candidate_email_responses_response_type_check
  CHECK (response_type = ANY (ARRAY[
    'interested_confirmation'::text,
    'declining'::text,
    'assessment_completed_notice'::text,
    'interview_accepted'::text,
    'bounced_undeliverable'::text,
    'process_problem'::text,
    'other'::text
  ]));
