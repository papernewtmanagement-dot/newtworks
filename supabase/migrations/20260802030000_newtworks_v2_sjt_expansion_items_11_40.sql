-- SJT expansion: brings every competency from 1-2 items up to 4 items each
-- (10 traits x 4 = 40 items total, items 1-10 untouched/locked, items 11-40
-- new). Restores sjt_feedback_channel_discipline and
-- sjt_documentation_discipline, which lost their only item when items 4 and
-- 7 were rewritten during Peter's review to fix scope (peer-level framing).
-- Reliability floor: Nunnally & Bernstein (1994) -- 1-2 items per construct
-- is unreliable; ~4 is the practical minimum before scoring means much.
-- Same format/design rules as the locked v2 revision: knowledge-based
-- "what should you do", grounded in the agency's own documented principles,
-- distractors plausible-but-wrong on a specific non-obvious dimension (no
-- tell-words).
(
  'newtworks_v2_sjt', 11, 'A customer messages you asking to bind coverage right now because their old policy just lapsed and they''re driving today. You''re not yet licensed. What should you do?',
  '["Confirm coverage is active since it''s urgent and they need it today.", "Let them know you can start the application now, and get a licensed teammate to complete the binding right away.", "Tell them insurance can''t be rushed and to expect a delay.", "Ask a licensed teammate to review it whenever they get a chance today."]'::jsonb, 'Let them know you can start the application now, and get a licensed teammate to complete the binding right away.', 'sjt_compliance_licensing_boundary', 0, false
),
(
  'newtworks_v2_sjt', 12, 'A vendor at a community event asks you to explain what a specific policy covers so they can decide whether to sign up on the spot. You''re not licensed yet. What should you do?',
  '["Explain the coverage details as best you understand them, since it''s just an informal conversation.", "Give them general information about the agency, and have them talk with a licensed teammate to go over actual coverage details.", "Tell them you can''t discuss insurance at all and walk away.", "Take their contact info and have someone reach out sometime next week."]'::jsonb, 'Give them general information about the agency, and have them talk with a licensed teammate to go over actual coverage details.', 'sjt_compliance_licensing_boundary', 0, false
),
(
  'newtworks_v2_sjt', 13, 'A customer''s home policy renewal shows a coverage gap you don''t have authority to change, and they want it fixed today. What should you do?',
  '["Make the adjustment yourself since it seems like an obvious fix.", "Explain what you''re seeing, and get the right person involved today if possible instead of just noting it for later.", "Let them know it''ll get looked at during the next review cycle.", "Suggest they wait until their next renewal to bring it up again."]'::jsonb, 'Explain what you''re seeing, and get the right person involved today if possible instead of just noting it for later.', 'sjt_escalation_judgment', 0, false
),
(
  'newtworks_v2_sjt', 14, 'A customer wants a decision made about a coverage dispute that only a supervisor is authorized to resolve, and the supervisor is unavailable. What should you do?',
  '["Make the call yourself, since someone needs to give them an answer today.", "Let them know you''re getting the right person involved, and follow up once you hear back.", "Tell them there''s nothing you can do until the supervisor is back.", "Give them your best guess at what the supervisor would likely decide."]'::jsonb, 'Let them know you''re getting the right person involved, and follow up once you hear back.', 'sjt_escalation_judgment', 0, false
),
(
  'newtworks_v2_sjt', 15, 'You want to send a marketing text to a group of past customers whose policies lapsed over a year ago. What should you do?',
  '["Send it, since they were customers before.", "Check whether they''re still within the window where outreach is allowed before sending anything.", "Only text the ones who called in recently for other reasons.", "Add them to a general newsletter list instead of texting them directly."]'::jsonb, 'Check whether they''re still within the window where outreach is allowed before sending anything.', 'sjt_compliance_outbound_consent', 0, false
),
(
  'newtworks_v2_sjt', 16, 'Someone verbally tells you it''s okay to text them about a quote, but nothing was written down or logged anywhere. What should you do?',
  '["Go ahead and text them, since they said it was fine.", "Log the conversation and what was agreed to, so there''s a record before sending anything.", "Wait a few days before texting just to be safe.", "Have someone else on the team text them instead."]'::jsonb, 'Log the conversation and what was agreed to, so there''s a record before sending anything.', 'sjt_compliance_outbound_consent', 0, false
),
(
  'newtworks_v2_sjt', 17, 'A customer asks to be removed from all future calls and texts. What should you do?',
  '["Stop texting them but continue with calls since they only mentioned texts.", "Update their contact preferences right away, making sure it applies across every channel you use to reach them.", "Wait until the next campaign cycle to update the list.", "Let them know you''ll pass the message along to the marketing team."]'::jsonb, 'Update their contact preferences right away, making sure it applies across every channel you use to reach them.', 'sjt_compliance_outbound_consent', 0, false
),
(
  'newtworks_v2_sjt', 18, 'A newer teammate asks you to help them understand a process you know well, but it''s during a busy stretch of your day. What should you do?',
  '["Tell them to figure it out on their own since you''re busy.", "Give them a few minutes now, or set a specific time later today when you can walk them through it properly.", "Do the task for them so it''s done correctly.", "Point them to the general guide and let them work it out themselves."]'::jsonb, 'Give them a few minutes now, or set a specific time later today when you can walk them through it properly.', 'sjt_peer_accountability', 0, false
),
(
  'newtworks_v2_sjt', 19, 'You notice a teammate taking credit for a piece of work you know someone else on the team actually did. What should you do?',
  '["Bring it up in front of the team so it''s addressed directly.", "Mention what you noticed to the teammate whose work it was, and let them decide how to handle it.", "Say nothing since it''s not really your business.", "Tell your manager without mentioning it to either teammate first."]'::jsonb, 'Mention what you noticed to the teammate whose work it was, and let them decide how to handle it.', 'sjt_peer_accountability', 0, false
),
(
  'newtworks_v2_sjt', 20, 'A teammate asks you to cover part of their workload because they''re overwhelmed, but it would put you behind on your own tasks. What should you do?',
  '["Say yes to everything so they don''t feel unsupported.", "Help with what you reasonably can, and be upfront about what you won''t be able to cover.", "Say no, since your own work has to come first.", "Quietly do less of your own work without telling anyone."]'::jsonb, 'Help with what you reasonably can, and be upfront about what you won''t be able to cover.', 'sjt_peer_accountability', 0, false
),
(
  'newtworks_v2_sjt', 21, 'You make a mistake on a customer''s file that could be quietly fixed without anyone noticing. What should you do?',
  '["Fix it quietly, since it''s already handled and no harm was done.", "Fix it and let your manager know what happened, even though no one would''ve caught it.", "Wait to see if it becomes a problem before saying anything.", "Mention it to a coworker instead of your manager."]'::jsonb, 'Fix it and let your manager know what happened, even though no one would''ve caught it.', 'sjt_honesty_integrity', 0, false
),
(
  'newtworks_v2_sjt', 22, 'A customer offers to leave you a great review in exchange for a small favor that bends the usual process. What should you do?',
  '["Accept the review, and quietly do the favor since it''s a small thing.", "Thank them for the kind offer, but let them know the review isn''t something you''d trade for a favor.", "Tell them to leave the review first before deciding on anything.", "Decline the review entirely and ask them not to leave one."]'::jsonb, 'Thank them for the kind offer, but let them know the review isn''t something you''d trade for a favor.', 'sjt_honesty_integrity', 0, false
),
(
  'newtworks_v2_sjt', 23, 'You''re filling out an internal report and realize a number you''d normally round up would look better rounded than exact. What should you do?',
  '["Round it up, since it''s close enough either way.", "Report the exact number, even though the rounded one would look better.", "Leave the field blank and let someone else fill it in.", "Report the exact number, but round up on similar reports going forward to average it out."]'::jsonb, 'Report the exact number, even though the rounded one would look better.', 'sjt_honesty_integrity', 0, false
),
(
  'newtworks_v2_sjt', 24, 'You''re in a meeting where a plan is being discussed that you''re pretty sure has a real flaw nobody else has mentioned. What should you do?',
  '["Stay quiet since it''s not your area of the business.", "Speak up about what you''re seeing, even if it means the discussion takes longer.", "Bring it up privately with someone after the meeting instead.", "Assume someone else will point it out if it''s really a problem."]'::jsonb, 'Speak up about what you''re seeing, even if it means the discussion takes longer.', 'sjt_speaking_up_judgment', 0, false
),
(
  'newtworks_v2_sjt', 25, 'A process you follow every day seems inefficient, and you think there''s a better way to do it. What should you do?',
  '["Just start doing it your own way without mentioning it to anyone.", "Suggest the idea to whoever owns that process, even if nothing changes.", "Keep it to yourself since it''s probably already been considered.", "Bring it up only if someone else asks for feedback."]'::jsonb, 'Suggest the idea to whoever owns that process, even if nothing changes.', 'sjt_speaking_up_judgment', 0, false
),
(
  'newtworks_v2_sjt', 26, 'You disagree with a decision your manager made, but you can see their reasoning. What should you do?',
  '["Go along with it without saying anything, since it''s their call.", "Share your perspective with them directly, then support the decision once it''s made.", "Voice your disagreement to teammates instead of your manager.", "Follow the decision, but make it clear to others that you disagreed with it."]'::jsonb, 'Share your perspective with them directly, then support the decision once it''s made.', 'sjt_speaking_up_judgment', 0, false
),
(
  'newtworks_v2_sjt', 27, 'A customer''s situation doesn''t quite fit the standard process, and following it exactly would leave them without a real solution. What should you do?',
  '["Tell them the process is the process and there''s nothing more you can do.", "Look for a legitimate way within your options to actually help them, even if it takes a bit more effort.", "Bend the process quietly to make it work for them.", "Refer them elsewhere without trying to help first."]'::jsonb, 'Look for a legitimate way within your options to actually help them, even if it takes a bit more effort.', 'sjt_service_within_process', 0, false
),
(
  'newtworks_v2_sjt', 28, 'A customer is comparing your agency to a competitor and wants to know if you can do anything to compete on price. What should you do?',
  '["Tell them you can probably match it if they sign today.", "Walk them through what''s actually included in their coverage so they can compare it accurately, not just the price.", "Tell them price is set and there''s nothing to discuss.", "Suggest they go with the competitor if price is their main concern."]'::jsonb, 'Walk them through what''s actually included in their coverage so they can compare it accurately, not just the price.', 'sjt_service_within_process', 0, false
),
(
  'newtworks_v2_sjt', 29, 'A customer wants a specific outcome that isn''t possible, but there''s a different option that would still genuinely help them. What should you do?',
  '["Tell them it''s not possible and leave it there.", "Explain why the original ask isn''t possible, and walk them through the option that would actually work.", "Tell them you''ll see what you can do, without a real plan to follow up.", "Suggest they try asking again later in case something changes."]'::jsonb, 'Explain why the original ask isn''t possible, and walk them through the option that would actually work.', 'sjt_service_within_process', 0, false
),
(
  'newtworks_v2_sjt', 30, 'Several things go wrong at once during a busy stretch of the day. What should you do?',
  '["Try to make progress on all of them at the same time.", "Handle them one at a time in order of what matters most.", "Set them all aside until things calm down.", "Ask a teammate to take over everything so you can reset."]'::jsonb, 'Handle them one at a time in order of what matters most.', 'sjt_composure_under_load', 0, false
),
(
  'newtworks_v2_sjt', 31, 'A customer raises their voice at you over something that wasn''t your mistake. What should you do?',
  '["Let them know it wasn''t your fault before doing anything else.", "Stay calm, acknowledge their frustration, and keep working toward a solution.", "Stay quiet and let them vent without responding at all.", "End the call and let them cool down before continuing."]'::jsonb, 'Stay calm, acknowledge their frustration, and keep working toward a solution.', 'sjt_composure_under_load', 0, false
),
(
  'newtworks_v2_sjt', 32, 'You''re behind on a task with a deadline approaching, and a new urgent request comes in. What should you do?',
  '["Drop what you''re doing to handle the new request immediately.", "Assess both, and communicate clearly if something has to wait.", "Finish your original task fully before even looking at the new request.", "Try to do both at once without telling anyone you''re stretched thin."]'::jsonb, 'Assess both, and communicate clearly if something has to wait.', 'sjt_composure_under_load', 0, false
),
(
  'newtworks_v2_sjt', 33, 'A teammate had a rough week with a few things that could use coaching, and it would be faster to just send them a quick message about it. What should you do?',
  '["Send a message summarizing what to work on.", "Wait until you can talk it through in person or by video, even if it takes a bit longer.", "Bring it up casually in front of the team.", "Let it go until it comes up naturally in a future conversation."]'::jsonb, 'Wait until you can talk it through in person or by video, even if it takes a bit longer.', 'sjt_feedback_channel_discipline', 0, false
),
(
  'newtworks_v2_sjt', 34, 'You need to tell a teammate their approach to something didn''t go well, and you''re both slammed today. What should you do?',
  '["Send a quick note so it''s addressed today at least.", "Find a short window today or first thing tomorrow to talk with them directly.", "Mention it in the group chat so it''s on record.", "Skip it since today''s too busy for a real conversation."]'::jsonb, 'Find a short window today or first thing tomorrow to talk with them directly.', 'sjt_feedback_channel_discipline', 0, false
),
(
  'newtworks_v2_sjt', 35, 'A decision needs to be delivered to a teammate that they likely won''t be happy about. What should you do?',
  '["Send it in writing so there''s a clear record of what was decided.", "Deliver it in person or by video so you can talk it through together.", "Have someone else deliver it since it''s an uncomfortable conversation.", "Wait until the next scheduled meeting, even if that''s a while away."]'::jsonb, 'Deliver it in person or by video so you can talk it through together.', 'sjt_feedback_channel_discipline', 0, false
),
(
  'newtworks_v2_sjt', 36, 'A performance issue needs to be addressed with a teammate, and everyone is remote today with no video calls scheduled. What should you do?',
  '["Send a written summary of the issue instead, since it''s clearer than a call.", "Schedule a video call specifically for this, even if it means waiting until later today.", "Bring it up during the next team call so everyone''s aligned.", "Let it go for now since scheduling a call feels like a big step for one issue."]'::jsonb, 'Schedule a video call specifically for this, even if it means waiting until later today.', 'sjt_feedback_channel_discipline', 0, false
),
(
  'newtworks_v2_sjt', 37, 'A performance issue with a teammate keeps happening, and it feels obvious enough that everyone already sees it. What should you do?',
  '["Skip writing it down since it''s clearly a pattern already.", "Start writing down specific examples and dates, even though it seems obvious.", "Wait until it happens one more time before starting to document it.", "Ask someone else on the team to keep track of it instead."]'::jsonb, 'Start writing down specific examples and dates, even though it seems obvious.', 'sjt_documentation_discipline', 0, false
),
(
  'newtworks_v2_sjt', 38, 'You and your manager agree out loud on a plan for handling a specific ongoing customer situation. What should you do?',
  '["Trust that you''ll both remember the plan since it was a clear conversation.", "Write down what was agreed to and keep it somewhere you can reference later.", "Mention the plan to a teammate so someone else knows about it.", "Wait to write anything down until the situation actually comes up again."]'::jsonb, 'Write down what was agreed to and keep it somewhere you can reference later.', 'sjt_documentation_discipline', 0, false
),
(
  'newtworks_v2_sjt', 39, 'A decision is being made about moving someone into a new role, and it feels like an easy, obvious call. What should you do?',
  '["Move forward with the decision since it''s clearly the right call.", "Write out the reasoning and the data behind the decision before it''s finalized.", "Document it sometime after the move happens, once things settle.", "Let the manager handle the documentation on their own."]'::jsonb, 'Write out the reasoning and the data behind the decision before it''s finalized.', 'sjt_documentation_discipline', 0, false
),
(
  'newtworks_v2_sjt', 40, 'You''re about to have a serious conversation with a teammate about a recurring issue, and you haven''t written anything down yet. What should you do?',
  '["Go into the conversation and wing it, since you know the issues well.", "Take a few minutes to write down specifics before the conversation, so it''s grounded in facts rather than impressions.", "Postpone the conversation until you feel like you remember everything clearly.", "Have someone else who witnessed it join the conversation instead of documenting anything yourself."]'::jsonb, 'Take a few minutes to write down specifics before the conversation, so it''s grounded in facts rather than impressions.', 'sjt_documentation_discipline', 0, false
);
