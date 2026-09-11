-- =====================================================================
-- hiring_candidates.decline_reason: add 'no_show'
--
-- Peter 2026-09-11: a candidate who booked an interview (or meet and greet)
-- and did not show up or reschedule gets its own decline reason. Until now
-- those were filed under active_applicant ("we passed on them"), which hid
-- the pattern.
--
-- Same day, wording only, no schema change: the app label for
-- active_applicant changed from "Real applicant — passed on" to "Didn't meet
-- our standard". The stored code stays active_applicant so the existing rows
-- and every function that reads the column keep working. Meaning of the two
-- hand-picked "we said no" reasons:
--   active_applicant  = we decided no before any offer went out (the normal one)
--   offer_rescinded   = an offer went out and we took it back
--
-- Decline letter: no_show is NOT on the never-send list in
-- send_one_candidate_decline_notice (calibration_only, former_team,
-- bounced_undeliverable), so a no-show gets the standard letter in the
-- Monday batch, same as any other decline Peter makes by hand.
-- =====================================================================

ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT IF EXISTS team_assessments_decline_reason_check;

ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT team_assessments_decline_reason_check
  CHECK (
    decline_reason IS NULL
    OR decline_reason = ANY (ARRAY[
      'active_applicant'::text,
      'no_show'::text,
      'candidate_withdrew'::text,
      'offer_rescinded'::text,
      'calibration_only'::text,
      'former_team'::text,
      'assessment_score'::text,
      'resume_score'::text,
      'bounced_undeliverable'::text
    ])
  );