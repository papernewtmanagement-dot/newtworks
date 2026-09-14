-- Every step before Day 1 is virtual, so the Meet and Greet is the wrong place
-- to mention working remotely. Put it back the way it was.
UPDATE public.hiring_email_templates
SET body_html = replace(
      body_html,
      E'<p>One thing worth knowing going in: Peter works remotely and is not in the office day to day. The team runs the office, and he is reachable on Teams, by phone and by text all day.</p>\n{{note_block}}',
      '{{note_block}}'
    ),
    updated_at = now()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND template_key = 'meet_greet';

UPDATE public.hiring_email_templates SET
  body_html = 'Hi {{first_name}} — really looking forward to kicking things off with you Monday. Plan to be here by 8:30 with your driver license and Social Security card. That is all you need. I usually work remotely, so the team will get you settled in at your desk and I will be with you on Teams through the day. Text me here if anything comes up over the weekend.',
  updated_at = now()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND template_key = 'start_friday_text';

UPDATE public.onboarding_step_templates SET
  description = E'Send this, filling in the name:\n\n"Hi [name] — really looking forward to kicking things off with you Monday. Plan to be here by 8:30 with your driver license and Social Security card. That is all you need. I usually work remotely, so the team will get you settled in at your desk and I will be with you on Teams through the day. Text me here if anything comes up over the weekend."\n\nSaved as the Friday before start text in the hiring templates. Fully remote hires get the remote welcome email instead.'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_friday_call';