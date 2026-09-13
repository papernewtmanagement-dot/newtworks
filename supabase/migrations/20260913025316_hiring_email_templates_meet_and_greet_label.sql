-- Peter's term is "Meet and Greet", matching the candidate columns and the
-- Meet and Greet form. The tab label follows his wording, not mine.
UPDATE public.hiring_email_templates
SET title = 'Meet and Greet invite', stage = 'Meet and Greet'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND template_key = 'meet_greet';