-- Peter directive 2026-08-26. Structured accomplishment question added to the
-- application screener, plus a required verification-contact field.
--
-- WHY: McDaniel, Schmidt & Hunter 1988 (Personnel Psychology 41) — on training
-- and experience evaluations, the behavioural-consistency method (describe your
-- accomplishments against a standard) reaches .45, versus .11 for the point
-- method (counting years and credentials). A free-form resume is the .11 version:
-- it only produces goal evidence when a candidate volunteers numbers nobody asked
-- for. Asking every applicant the same question converts it to the .45 version.
--
-- The verifier field is not optional and is not decoration. Levashina, Morgeson &
-- Campion 2012 (Personnel Psychology 65, N=16,304): requiring applicants to
-- supply supporting information reduces response distortion, and the effect is
-- driven by item verifiability. Field evidence: a customised form cut inaccuracies
-- from 23% on free-form resumes to 11%, and applicants who declined to give
-- contact details for verification were far less likely to have reported
-- accurately (39% vs 77% fully accurate) — Journal of Personnel Psychology 22(2).
-- Asking for the contact is itself the deterrent; it works before anyone calls.
--
-- knockout_on is NULL on both: these are scored, never auto-rejecting. The apply
-- handler short-circuits on a null knockout_on, so no applicant can be knocked out
-- by a text answer.
INSERT INTO public.job_screener_questions
  (agency_id, question_code, question_text, answer_type, options, knockout_on, is_required, is_active)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365',
   'best_result',
   'Tell us about the best result you produced in a job. What was the result, and what were you being measured against at the time (a goal, a quota, a deadline, a standard)? Numbers help if you have them.',
   'open_text', NULL, NULL, true, true),
  ('126794dd-25ff-47d2-a436-724499733365',
   'best_result_verifier',
   'Who can confirm that result? Give a name, their job title, and a phone number or email.',
   'open_text', NULL, NULL, true, true);

-- Attach to all three live postings, appended so existing question order is
-- untouched. Guarded against double-append if this is ever re-run.
UPDATE public.job_postings
SET screener_codes = screener_codes || ARRAY['best_result','best_result_verifier'],
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active = true
  AND NOT ('best_result' = ANY(screener_codes));
