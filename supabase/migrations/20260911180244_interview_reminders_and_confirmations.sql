-- Interview reminders + candidate confirmation (Peter directive 2026-09-11).
-- Two touches per booked interview (two days before, morning of), each with
-- Yes / Reschedule / No-longer-interested links. Reschedule and withdraw free
-- the slot. Research anchor: Steiner et al. 2018, Am J Manag Care 24:377
-- (two reminders beat one); Martin, Bassi & Dunbar-Rees 2012, J R Soc Med
-- 105:101 (an active confirmation cuts no-shows).

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS interview_confirmed_at timestamptz,
  ADD COLUMN IF NOT EXISTS interview_reminder_2d_sent_at timestamptz,
  ADD COLUMN IF NOT EXISTS interview_reminder_day_sent_at timestamptz,
  ADD COLUMN IF NOT EXISTS interview_reminder_response text;

ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT IF EXISTS hiring_candidates_interview_reminder_response_check;
ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT hiring_candidates_interview_reminder_response_check
  CHECK (interview_reminder_response IS NULL OR interview_reminder_response IN ('confirmed', 'reschedule', 'withdrew'));

COMMENT ON COLUMN public.hiring_candidates.interview_confirmed_at IS 'Candidate tapped "Yes, I''ll be there" (reminder email or booking page). Cleared on rebook.';
COMMENT ON COLUMN public.hiring_candidates.interview_reminder_2d_sent_at IS 'Confirm-or-reschedule reminder sent (two days before; the morning before when booked with less notice).';
COMMENT ON COLUMN public.hiring_candidates.interview_reminder_day_sent_at IS 'Morning-of reminder sent.';
COMMENT ON COLUMN public.hiring_candidates.interview_reminder_response IS 'Last answer to a reminder: confirmed | reschedule | withdrew.';

-- Daily 7:59 Central. Rides the hourly runner tick (no new pg_cron job).
-- The runner posts {agency_id, recipe_id, shared_secret, mode} straight to
-- the hiring-interview-scheduler edge function (dispatch_ prefix convention).
INSERT INTO public.automation_recipes
  (agency_id, recipe_name, recipe_description, trigger_type, cron_expression, composio_action, internal_handler, input_config, is_active, timezone)
SELECT '126794dd-25ff-47d2-a436-724499733365',
       'Interview Reminders',
       'Daily at 7:59 Central. Emails every booked candidate a confirm-or-reschedule ask two days before the interview and a reminder the morning of, both with Yes / Reschedule / No-longer-interested links. Unconfirmed on the morning of -> Telegram DM to the owner.',
       'cron', '59 7 * * *', 'INTERNAL', 'dispatch_hiring_interview_scheduler',
       '{"mode":"send_reminders"}'::jsonb, true, 'America/Chicago'
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND recipe_name = 'Interview Reminders'
);
