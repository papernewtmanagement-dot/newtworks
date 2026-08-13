-- =====================================================================
-- decline_reason: add bounced_undeliverable
-- =====================================================================
-- Peter directive 2026-08-13: a bounce that survives resume re-verification
-- (the mailed address matches the resume, or no resume exists to check)
-- always ends in a decline. Reusing "active_applicant" for that, as the
-- 2026-08-12 manual handling of Kevin Barron Vazquez did, loses the actual
-- reason. Naming matches the existing response_type value
-- 'bounced_undeliverable' on candidate_email_responses -- same word, same
-- meaning, different column, per the house rule against inventing a new
-- term for a concept that already has one.
-- =====================================================================

ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT team_assessments_decline_reason_check;

ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT team_assessments_decline_reason_check
  CHECK (
    decline_reason IS NULL
    OR decline_reason = ANY (ARRAY[
      'active_applicant', 'offer_rescinded', 'calibration_only',
      'former_team', 'assessment_score', 'bounced_undeliverable'
    ])
  );

-- Correct the two candidates already declined for a bounce under the old
-- catch-all reason, now that the real one exists.
UPDATE public.hiring_candidates
   SET decline_reason = 'bounced_undeliverable'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND status = 'declined'
   AND decline_reason = 'active_applicant'
   AND id IN (
     '9cb6d43e-b938-42cd-821a-bcdc80b07d5c',  -- Jamya Chambers
     '69d4abf7-bb4e-49b1-8672-ed6bf00fa674'   -- Kevin Barron Vazquez
   );
