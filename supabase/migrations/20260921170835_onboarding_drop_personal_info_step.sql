-- Peter 2026-09-21: SSN, date of birth and address are collected on the
-- offer acceptance page now, so the onboarding card that asked for them goes.
UPDATE public.onboarding_step_templates
   SET blocked_by = array_remove(blocked_by, 't_personal_info'),
       description = replace(description, 'Needs Social Security number, date of birth, languages, skill level.',
                             'Needs Social Security number and date of birth (from the offer acceptance), languages, skill level.')
 WHERE 't_personal_info' = ANY(blocked_by);

UPDATE public.team_onboarding_steps
   SET blocked_by = array_remove(blocked_by, 't_personal_info'),
       description = replace(description, 'Needs Social Security number, date of birth, languages, skill level.',
                             'Needs Social Security number and date of birth (from the offer acceptance), languages, skill level.')
 WHERE 't_personal_info' = ANY(blocked_by);

DELETE FROM public.team_onboarding_steps WHERE template_key = 't_personal_info';
DELETE FROM public.onboarding_step_templates WHERE template_key = 't_personal_info';
