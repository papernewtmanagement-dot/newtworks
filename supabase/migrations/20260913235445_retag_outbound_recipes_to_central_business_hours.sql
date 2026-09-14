-- Decision 2: three recipes that send mail to candidates or the team were tagged UTC,
-- so they fired at 1am and 4am Central. None of the send functions has an hour guard,
-- so the schedule is the only thing holding them. Retag to America/Chicago and keep
-- every slot inside business hours. Top of each range is set so that even a late
-- recovery on the two-hour look-back still lands by about 8pm Central.

-- Candidate assessment invitations: was every 3 hours UTC (01:00 and 04:00 Central
-- among them). Now four sends inside the working day.
UPDATE public.automation_recipes
SET cron_expression = '59 8,11,14,17 * * *', timezone = 'America/Chicago', updated_at = NOW()
WHERE recipe_name = 'Send v1 Assessment Invitations';

-- Sales profile invitations: was every hour, around the clock.
UPDATE public.automation_recipes
SET cron_expression = '59 8-17 * * *', timezone = 'America/Chicago', updated_at = NOW()
WHERE recipe_name = 'Send CTS Sales Profile Invites';

-- Time clock edit notices to the team: was 04:00, 08:00 and 12:00 Central.
UPDATE public.automation_recipes
SET cron_expression = '59 8,12,16 * * *', timezone = 'America/Chicago', updated_at = NOW()
WHERE recipe_name = 'time_clock_edit_notifier';
