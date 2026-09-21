-- Item 4 sends the candidate two emails. They live in hiring_email_templates
-- like every other candidate-facing email, so the wording is editable without
-- a migration.

INSERT INTO public.hiring_email_templates
  (agency_id, template_key, title, stage, sort_order, subject, body_html, tokens, description, sent_when)
VALUES
('126794dd-25ff-47d2-a436-724499733365',
 'reference_help_request',
 'References we cannot reach — ask the candidate for help',
 'Offer and start', 136,
 'We are having trouble reaching your references',
 '<p>Hi {{first_name}},</p>'
 || '<p>We have been trying to reach the references you gave us and have not been able to get hold of these ones:</p>'
 || '{{unreachable_list}}'
 || '<p>Could you let them know we are calling? A quick heads-up from you usually does it. '
 || 'If it is easier, they can call {{caller_name}} back directly{{caller_phone_line}}.</p>'
 || '<p>We need to speak to {{minimum}} of your references before your start date is locked in, '
 || 'so the sooner we can reach them the better. We will keep trying for the next few days.</p>'
 || '<p>Thanks,<br>Peter</p>',
 ARRAY['first_name','unreachable_list','caller_name','caller_phone_line','minimum'],
 'Sent once, after three attempts on each reference, when we still do not have enough good ones. Starts a three-day clock before we try again.',
 'Automatically, after three failed attempts per reference'),

('126794dd-25ff-47d2-a436-724499733365',
 'reference_final_request',
 'References still unreachable — final ask',
 'Offer and start', 137,
 'Last try on your references',
 '<p>Hi {{first_name}},</p>'
 || '<p>We have now tried these references twice over, and still have not been able to speak to them:</p>'
 || '{{unreachable_list}}'
 || '<p>We cannot finish your reference check without talking to {{minimum}} people who have worked with you, '
 || 'so this is where it stands. If you can get these people to call {{caller_name}}{{caller_phone_line}}, '
 || 'or if you would rather give us different references, reply to this email and we will pick it back up.</p>'
 || '<p>Thanks,<br>Peter</p>',
 ARRAY['first_name','unreachable_list','caller_name','caller_phone_line','minimum'],
 'Sent once, after the second round of three attempts has also failed. After this the reference check pauses until the candidate replies.',
 'Automatically, after the second round of attempts fails')
ON CONFLICT (agency_id, template_key) DO NOTHING;
