-- 2026-09-27 (Peter): candidates sent the interview booking link who never book
-- get two reminders a day apart, then are closed when the 7-day link expires.
-- Same shape as the assessment and sales-profile reminders.
ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS interview_booking_reminder_1_sent_at timestamptz,
  ADD COLUMN IF NOT EXISTS interview_booking_reminder_2_sent_at timestamptz;

ALTER TABLE public.hiring_candidates DROP CONSTRAINT IF EXISTS team_assessments_decline_reason_check;
ALTER TABLE public.hiring_candidates ADD CONSTRAINT team_assessments_decline_reason_check
  CHECK (decline_reason IS NULL OR decline_reason = ANY (ARRAY[
    'active_applicant','no_show','candidate_withdrew','offer_rescinded','calibration_only',
    'former_team','assessment_score','resume_score','assessment_not_taken','bounced_undeliverable',
    'interview_not_booked']));

INSERT INTO public.hiring_email_templates
  (agency_id, template_key, title, stage, sort_order, subject, body_html, tokens, description, sent_when)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'interview_booking_reminder',
  'Interview booking reminder', 'Interview', 35,
  'Reminder: pick a time for your Interview AMA — Story Agency',
  '<p>Hi {{first_name}},</p>
<p>Just following up on your Interview AMA with Story Agency. It''s a video call (about 30 minutes) over Google Meet. Your link is still active:</p>
<p><a href="{{booking_url}}">{{booking_url}}</a></p>
<p>The link expires {{expires}}. Once you pick a time, you''ll get a confirmation email with the Google Meet link.</p>
<p>If you have decided not to pursue this role, just reply to this email and let me know so I can update our records.</p>
<p>Sincerely,<br/>Story Agency</p>',
  ARRAY['first_name','booking_url','expires'],
  'Nudge for someone sent the booking link who has not picked a time. Sends twice, a day apart, then stops. If the link expires unbooked, the candidate is closed as "never booked" and gets the standard decline letter.',
  'Automatically, in the 7 AM run, a day after the booking link and a day after that.'
WHERE NOT EXISTS (SELECT 1 FROM public.hiring_email_templates WHERE template_key='interview_booking_reminder' AND agency_id='126794dd-25ff-47d2-a436-724499733365');
