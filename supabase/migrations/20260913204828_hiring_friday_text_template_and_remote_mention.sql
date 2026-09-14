-- The Friday-before-start text now lives with the rest of the hiring wording
-- instead of only inside the onboarding step.
INSERT INTO public.hiring_email_templates
  (agency_id, template_key, title, stage, sort_order, subject, body_html, tokens, description, sent_when)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  'start_friday_text',
  'Friday before start (text message)',
  'Offer and start',
  135,
  '',
  'Hi {{first_name}} — really looking forward to kicking things off with you Monday. Plan to be here by 8:30, and bring your driver license and Social Security card. That is all you need. One thing so it is not a surprise: I work remotely, so the team will get you settled in that morning — I am on Teams and my phone all day. Text me here if anything comes up over the weekend.',
  ARRAY['first_name'],
  'Short text, not an email. Fully remote hires get the remote welcome email instead.',
  'Manually, the Friday before their start date. The Friday 9am automation posts it to the Paper Newt Management group with their phone number.'
WHERE NOT EXISTS (
  SELECT 1 FROM public.hiring_email_templates
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key='start_friday_text'
);

-- Said earlier too, at the Meet and Greet, so nobody learns it on Day 1.
UPDATE public.hiring_email_templates
SET body_html = replace(
      body_html,
      '{{note_block}}',
      E'<p>One thing worth knowing going in: Peter works remotely and is not in the office day to day. The team runs the office, and he is reachable on Teams, by phone and by text all day.</p>\n{{note_block}}'
    ),
    updated_at = now()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND template_key = 'meet_greet'
  AND body_html NOT LIKE '%works remotely%';

-- Keep the onboarding step wording identical to the saved template.
UPDATE public.onboarding_step_templates SET
  description = E'Send this, filling in the name:\n\n"Hi [name] — really looking forward to kicking things off with you Monday. Plan to be here by 8:30, and bring your driver license and Social Security card. That is all you need. One thing so it is not a surprise: I work remotely, so the team will get you settled in that morning — I am on Teams and my phone all day. Text me here if anything comes up over the weekend."\n\nSaved as the Friday before start text in the hiring templates. Fully remote hires get the remote welcome email instead.'
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_friday_call';