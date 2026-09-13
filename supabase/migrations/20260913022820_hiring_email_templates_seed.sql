INSERT INTO public.hiring_email_templates
  (agency_id, template_key, title, stage, sort_order, subject, body_html, tokens, description, sent_when)
VALUES

('126794dd-25ff-47d2-a436-724499733365', 'assessment_invite',
 'Assessment invite', 'Assessment', 10,
 'Assessment for {{position}} at Peter Story State Farm',
$tpl$<p>Hi {{first_name}},</p>
<p>Thanks for applying for {{role_phrase}} at Peter Story State Farm.</p>
<p>Before we schedule any live conversation, please work through this short assessment. It takes about an hour and covers personality, working style, and a bit of aptitude. Nothing to study for &mdash; just answer honestly.</p>
<p>This works both ways. It is a chance for me to learn how you naturally think and work &mdash; and a chance for you to see whether this role suits the way you like to work. The best hires I have made have felt like the right fit for both sides.</p>
<p><a href="{{assessment_link}}" style="display:inline-block;padding:12px 24px;background:#737A59;color:#ffffff;text-decoration:none;border-radius:6px;font-weight:600;">Start the assessment</a></p>
<p style="color:#64748b;font-size:13px;">If the button does not work, paste this link into your browser:<br><a href="{{assessment_link}}">{{assessment_link}}</a></p>
<p>Once you are done, I will review your results along with a short set of written questions I will send next. If we are a fit, we will schedule a video call.</p>
<p>&mdash; Peter Story<br>Peter Story State Farm</p>$tpl$,
 ARRAY['first_name','position','role_phrase','assessment_link'],
 'First assessment invite. Goes to applicants who clear the resume gate.',
 'Automatically, every three hours, to newly eligible applicants.'),

('126794dd-25ff-47d2-a436-724499733365', 'assessment_reminder',
 'Assessment reminder', 'Assessment', 20,
 'Reminder: assessment for {{position}} at Peter Story State Farm',
$tpl$<p>Hi {{first_name}},</p>
<p>Just following up on the assessment for {{role_phrase}} at Peter Story State Farm.</p>
<p>If you are still interested, please take about an hour to complete it. Your link is still active:</p>
<p><a href="{{assessment_link}}" style="display:inline-block;padding:12px 24px;background:#737A59;color:#ffffff;text-decoration:none;border-radius:6px;font-weight:600;">Open the assessment</a></p>
<p style="color:#64748b;font-size:13px;">If the button does not work, paste this link into your browser:<br><a href="{{assessment_link}}">{{assessment_link}}</a></p>
<p>If you have decided not to pursue this role, just reply to this email and let me know so I can update our records.</p>
<p>&mdash; Peter Story<br>Peter Story State Farm</p>$tpl$,
 ARRAY['first_name','position','role_phrase','assessment_link'],
 'Nudge for an unfinished assessment. Sends twice, a day apart, then stops.',
 'Automatically, a day after the last invite, up to two reminders.'),

('126794dd-25ff-47d2-a436-724499733365', 'interview_invite',
 'Interview invite (pick a time)', 'Interview', 30,
 'Next step: schedule your Interview AMA — Story Agency',
$tpl$<p>Hi {{first_name}},</p>
<p>Thank you for completing our assessment — we'd like to move forward with an Interview AMA.</p>
<p>It's a video call (about 30 minutes) over Google Meet. Please pick a time that works for you:</p>
<p><a href="{{booking_url}}">{{booking_url}}</a></p>
<p>This link is valid for the next 7 days. Once you pick a time, you'll get a confirmation email with the Google Meet link.</p>
<p>Looking forward to speaking with you.</p>
<p>Sincerely,<br/>Story Agency</p>$tpl$,
 ARRAY['first_name','booking_url'],
 'Sent when a candidate passes the assessment. Carries the booking link.',
 'Automatically, right after the assessment is scored a pass or consider.'),

('126794dd-25ff-47d2-a436-724499733365', 'interview_rebook',
 'Interview invite (pick a new time)', 'Interview', 40,
 'Pick a new time for your Interview AMA — Story Agency',
$tpl$<p>Hi {{first_name}},</p>
<p>Thank you for completing our assessment — we'd like to move forward with an Interview AMA.</p>
<p>It's a video call (about 30 minutes) over Google Meet. Please pick a time that works for you:</p>
<p><a href="{{booking_url}}">{{booking_url}}</a></p>
<p>This link is valid for the next 7 days. Once you pick a time, you'll get a confirmation email with the Google Meet link.</p>
<p>Looking forward to speaking with you.</p>
<p>Sincerely,<br/>Story Agency</p>$tpl$,
 ARRAY['first_name','booking_url'],
 'Same letter, different subject line, for when the candidate asked to reschedule.',
 'Automatically, when a candidate taps "I need a different time".'),

('126794dd-25ff-47d2-a436-724499733365', 'interview_confirmation',
 'Interview confirmed', 'Interview', 50,
 'You''re confirmed — Interview AMA scheduled',
$tpl$<p>Hi {{first_name}},</p>
<p>You're confirmed for <strong>{{when}}</strong> (Central time).</p>
<p>This will be a video call over Google Meet: <a href="{{meet_url}}">{{meet_url}}</a></p>
<p>{{prep_line}}</p>
<p>A calendar invite is on its way to this email address as well. Looking forward to speaking with you.</p>
<p>Sincerely,<br/>Story Agency</p>$tpl$,
 ARRAY['first_name','when','meet_url','prep_line'],
 'Booking confirmation with the Google Meet link.',
 'Automatically, the moment a candidate books a time.'),

('126794dd-25ff-47d2-a436-724499733365', 'interview_confirmation_moved',
 'Interview moved up (confirmed)', 'Interview', 60,
 'You''re moved up — Interview AMA rescheduled',
$tpl$<p>Hi {{first_name}},</p>
<p>You're confirmed for <strong>{{when}}</strong> (Central time).</p>
<p>This will be a video call over Google Meet: <a href="{{meet_url}}">{{meet_url}}</a></p>
<p>{{prep_line}}</p>
<p>A calendar invite is on its way to this email address as well. Looking forward to speaking with you.</p>
<p>Sincerely,<br/>Story Agency</p>$tpl$,
 ARRAY['first_name','when','meet_url','prep_line'],
 'Same letter as the confirmation, for a candidate who took an earlier slot.',
 'Automatically, when a booked candidate moves to an earlier time.'),

('126794dd-25ff-47d2-a436-724499733365', 'interview_earlier_time',
 'Earlier time opened up', 'Interview', 70,
 'An earlier interview time opened up — Story Agency',
$tpl$<p>Hi {{first_name}},</p>
<p>An earlier time opened up for your Interview AMA with Story Agency. You're currently set for <strong>{{when}}</strong> (Central time).</p>
<p>Open earlier times:</p>
<ul>{{options_list}}</ul>
<p>Want one? Pick it here: <a href="{{booking_url}}">{{booking_url}}</a></p>
<p>If you do nothing, your current time stays exactly as it is.</p>
<p>Sincerely,<br/>Story Agency</p>$tpl$,
 ARRAY['first_name','when','options_list','booking_url'],
 'Offers a booked candidate a sooner slot when one frees up. Ignoring it changes nothing.',
 'Automatically, when a time earlier than theirs opens.'),

('126794dd-25ff-47d2-a436-724499733365', 'interview_moved_by_us',
 'We need to move your interview', 'Interview', 80,
 'We need to move your Interview AMA — Story Agency',
$tpl$<p>Hi {{first_name}},</p>
<p>{{reason}} so your Interview AMA time on <strong>{{old_when}}</strong> no longer works. Sorry about the change.</p>
<p>Please pick a new time here — it's a 30-minute video call over Google Meet:</p>
<p><a href="{{booking_url}}">{{booking_url}}</a></p>
<p>This link is valid for the next 7 days. Once you pick a time, you'll get a fresh confirmation with the Google Meet link.</p>
<p>Sincerely,<br/>Story Agency</p>$tpl$,
 ARRAY['first_name','reason','old_when','booking_url'],
 'Sent when the agency has to clear a booked interview, such as a vacation week.',
 'Manually, from the Interview Slots calendar.'),

('126794dd-25ff-47d2-a436-724499733365', 'interview_reminder_3day_unconfirmed',
 'Three days out — not yet confirmed', 'Interview reminders', 90,
 'Still good for {{when}}? Your Interview AMA',
$tpl$<p>Hi {{first_name}},</p>
<p>A quick reminder that your Interview AMA with Story Agency is <strong>{{when}}</strong> (Central time). It's a 30-minute video call over Google Meet.</p>
{{meet_line}}
<p>Can you confirm you'll be there? One tap:</p>
{{response_buttons}}
<p>{{prep_line}}</p>
<p>Sincerely,<br/>Story Agency</p>$tpl$,
 ARRAY['first_name','when','meet_line','response_buttons','prep_line'],
 'Three days before, asking them to confirm. Carries the confirm, reschedule and withdraw buttons.',
 'Automatically, in the morning run three days out.'),

('126794dd-25ff-47d2-a436-724499733365', 'interview_reminder_3day_confirmed',
 'Three days out — already confirmed', 'Interview reminders', 100,
 'Reminder: your Interview AMA is {{when}}',
$tpl$<p>Hi {{first_name}},</p>
<p>A quick reminder that your Interview AMA with Story Agency is <strong>{{when}}</strong> (Central time). It's a 30-minute video call over Google Meet.</p>
{{meet_line}}
<p>You've already confirmed, so we're all set. If anything changes, use the links below.</p>
{{response_buttons}}
<p>{{prep_line}}</p>
<p>Sincerely,<br/>Story Agency</p>$tpl$,
 ARRAY['first_name','when','meet_line','response_buttons','prep_line'],
 'Same touch for someone who already confirmed.',
 'Automatically, in the morning run three days out.'),

('126794dd-25ff-47d2-a436-724499733365', 'interview_reminder_1day_unconfirmed',
 'Day before — not yet confirmed', 'Interview reminders', 110,
 'Tomorrow: your Interview AMA with Story Agency ({{when}})',
$tpl$<p>Hi {{first_name}},</p>
<p>Your Interview AMA with Story Agency is <strong>tomorrow, {{when}}</strong> (Central time). It's a 30-minute video call.</p>
{{meet_line}}
<p>Can you confirm you'll be there? One tap:</p>
{{response_buttons}}
<p>{{prep_line}}</p>
<p>Sincerely,<br/>Story Agency</p>$tpl$,
 ARRAY['first_name','when','meet_line','response_buttons','prep_line'],
 'Day-before reminder for someone who has still not confirmed.',
 'Automatically, in the morning run the day before.'),

('126794dd-25ff-47d2-a436-724499733365', 'interview_reminder_1day_confirmed',
 'Day before — already confirmed', 'Interview reminders', 120,
 'Tomorrow: your Interview AMA with Story Agency ({{when}})',
$tpl$<p>Hi {{first_name}},</p>
<p>Your Interview AMA with Story Agency is <strong>tomorrow, {{when}}</strong> (Central time). It's a 30-minute video call.</p>
{{meet_line}}
<p>You've already confirmed, so we're all set. If anything changes, use the links below.</p>
{{response_buttons}}
<p>{{prep_line}}</p>
<p>Sincerely,<br/>Story Agency</p>$tpl$,
 ARRAY['first_name','when','meet_line','response_buttons','prep_line'],
 'Day-before reminder for someone who already confirmed.',
 'Automatically, in the morning run the day before.'),

('126794dd-25ff-47d2-a436-724499733365', 'meet_greet',
 'Meet the team invite', 'Meet the team', 130,
 'You''re set — meet the team',
$tpl$<p>Hi {{first_name}},</p>
<p>Thank you for the conversation — we'd like you to meet the rest of the team.</p>
<p>You're set for <strong>{{when}}</strong> (Central time).</p>
{{where_block}}
<p>This one is less formal than the interview. It's a chance for you to meet the people you'd be working alongside, and for them to meet you — so come with questions.</p>
{{note_block}}
<p>A calendar invite is on its way to this email address as well. If that time doesn't work, just reply to this email and we'll find another.</p>
<p>Sincerely,<br/>Story Agency</p>$tpl$,
 ARRAY['first_name','when','where_block','note_block'],
 'Invite to the meet and greet after the interview.',
 'Manually, from the candidate record.'),

('126794dd-25ff-47d2-a436-724499733365', 'decline_standard',
 'Decline — standard', 'Decline letters', 140,
 'Update on your application — Peter Story State Farm',
$tpl$<p>Hi {{first_name}},</p>
<p>Thank you for applying for {{role_phrase}} at Peter Story State Farm, and for the time and effort you put into the process. After thinking it over, I have decided to move forward with other candidates for this position.</p>
<p>I want to be clear about what that does and does not mean. It means one seat, one moment, one particular set of things I was weighing. It does not mean you fell short as a person or as a professional. Those two things get confused constantly, and they should not be.</p>
<p>Here is what I have seen hold true over years of hiring: the people who go on to do well are almost never the ones with the flawless resume. They are the ones who keep showing up, who do the unglamorous work when nobody is watching, and who get a little better every week without being asked to. Talent opens a door. Work ethic is what walks through it and stays. That part belongs entirely to you, and no hiring decision — mine or anyone else's — can touch it.</p>
<p>So keep going. Send the next application. Ask the sharper question in the next interview. Learn the thing you have been putting off. The effort you are putting in right now compounds quietly, and it pays out on a schedule you do not get to see in advance. The right fit is out there, and the work you are doing to find it is not wasted.</p>
<p>Our openings change through the year. If something opens that suits you, please apply again — I would be glad to take another look.</p>
<p>I wish you real success in whatever comes next.</p>
<p>&mdash; Peter Story<br>Peter Story State Farm</p>$tpl$,
 ARRAY['first_name','role_phrase'],
 'The letter every declined candidate gets unless one of the three below fits better.',
 'Automatically, in the Monday batch.'),

('126794dd-25ff-47d2-a436-724499733365', 'decline_withdrew',
 'Decline — candidate withdrew', 'Decline letters', 150,
 'Thanks for letting me know — Peter Story State Farm',
$tpl$<p>Hi {{first_name}},</p>
<p>Thanks for letting me know you are stepping out of the process for {{role_phrase}} at Peter Story State Farm. I appreciate you closing the loop instead of going quiet. Plenty of people would have simply disappeared. You did not — and doing the small courteous thing when there is nothing in it for you is exactly the habit that makes someone worth working with.</p>
<p>Whatever you are chasing instead, I hope you go after it hard. The people I have watched build something real were rarely the most naturally gifted ones in the room. They were the ones who picked a direction and out-worked the doubt — who kept showing up on the ordinary days, long after the excitement wore off. That is a choice, not a talent, and it is available to you every single morning.</p>
<p>Our openings change through the year. If the timing is better later on, please apply again. I would be glad to take another look.</p>
<p>Go get it.</p>
<p>&mdash; Peter Story<br>Peter Story State Farm</p>$tpl$,
 ARRAY['first_name','role_phrase'],
 'For someone who pulled themselves out of the process.',
 'Automatically, on the spot when they withdraw.'),

('126794dd-25ff-47d2-a436-724499733365', 'decline_no_show',
 'Decline — no show', 'Decline letters', 160,
 'Update on your application — Peter Story State Farm',
$tpl$<p>Hi {{first_name}},</p>
<p>We had a time set aside to meet for {{role_phrase}} at Peter Story State Farm, and it did not happen. I am not going to assume the worst. Things come up, phones die, days get away from people.</p>
<p>I do have to be straight with you. I have closed your application for now. Showing up is the first thing I look for in anyone I hire, and the interview is the first place I get to see it. There is no way around that.</p>
<p>None of this says anything about what you are capable of. If you want a job like this, the fix is not complicated. Pick the next thing, put it on your calendar, and be there ten minutes early. Do that a few times in a row and doors open.</p>
<p>If something real got in the way and you still want this, apply again and tell me what happened. I would be glad to take another look.</p>
<p>&mdash; Peter Story<br>Peter Story State Farm</p>$tpl$,
 ARRAY['first_name','role_phrase'],
 'For a candidate who missed the interview without warning.',
 'Automatically, in the Monday batch.'),

('126794dd-25ff-47d2-a436-724499733365', 'decline_offer_rescinded',
 'Decline — offer withdrawn', 'Decline letters', 170,
 'Update on your offer — Peter Story State Farm',
$tpl$<p>Hi {{first_name}},</p>
<p>This confirms what we talked about by phone. The contingent offer for {{role_phrase}} at Peter Story State Farm is withdrawn. I know that is hard to read, and I did not make the decision lightly.</p>
<p>A door closing rarely says much about the person on the other side of it. The work you did to earn that offer was real, and it goes with you. Nothing about this changes that.</p>
<p>I wish you real success in what comes next.</p>
<p>&mdash; Peter Story<br>Peter Story State Farm</p>$tpl$,
 ARRAY['first_name','role_phrase'],
 'Confirms a withdrawn offer in writing. The phone call always happens first. The offer is named as contingent on purpose.',
 'Automatically, in the Monday batch.'),

('126794dd-25ff-47d2-a436-724499733365', 'snippet_prep_line',
 'Prep line (shared sentence)', 'Shared wording', 180,
 '',
$tpl$This is an Interview AMA — please take some time beforehand to research Story Agency and State Farm, and come ready with your own questions for us.$tpl$,
 ARRAY[]::text[],
 'One sentence, reused in the confirmation, every interview reminder, and the booking page. Edit it once and it changes everywhere.',
 'Not a letter of its own.')

ON CONFLICT (agency_id, template_key) DO NOTHING;