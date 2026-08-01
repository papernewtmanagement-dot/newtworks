-- HireGauge v2 Situational Judgement Test (SJT) — new construct, built from
-- scratch (no prior schema, no prior content existed for this item type).
--
-- FORMAT DECISION (documented per operational_rule "Hardcoded functions:
-- never prefer simpler over more accurate" -- applies to source-data/format
-- choices, not just formulas):
--   Knowledge-based "what SHOULD you do" instructions, single-select among
--   4 response options per scenario. McDaniel, Hartman, Whetzel & Grubb
--   (2007), Personnel Psychology 60(1):63-91, found knowledge instructions
--   ("what is the most effective response") produce higher criterion-related
--   validity than behavioral-tendency instructions ("what would you actually
--   do") in employee-selection contexts -- behavioral-tendency framing
--   invites faking/self-presentation bias that knowledge framing resists.
--   Foundational SJT construction methodology: Motowidlo, Dunnette & Carter
--   (1990), J. Applied Psychology 75(6):640-647. General validity summary:
--   McDaniel & Nguyen (2001), International Journal of Selection and
--   Assessment 9(1-2):103-113.
--
-- SCORING: reuses the EXISTING generic multi-choice save path already wired
-- in CandidateAssessment.jsx / v1-assessment edge fn (same convention as
-- VCT items) -- choices is a plain JSONB array of option text, answer_key is
-- the exact text of the best response, is_correct is a trimmed string match
-- on response_label. No new frontend component needed for this item type.
--
-- CONTENT GROUNDING: each scenario's correct answer is derived from a
-- principle already documented and approved in this agency's own
-- core_principles / compliance rules, not invented generic judgment norms.
-- hypothesized_trait tags the competency each scenario targets (reusing the
-- same column personality items use): licensing/compliance boundaries,
-- escalation judgment, outbound-consent compliance, feedback-channel
-- discipline, honesty/integrity, documentation discipline, composure under
-- load. Scenarios deliberately avoid internal SF program names, pricing/
-- premium specifics, and FINRA-restricted language, consistent with
-- compliance rule "never_on_agency_surfaces" (this candidate-facing portal
-- counts as an agency-facing surface).
--
-- stint=0, is_active=false -- same placeholder convention as GMA items 1-30
-- (not yet wired into v1-assessment serve routing; sequencing decision
-- deferred per Peter directive 2026-08-02: build content now, wire in later).

ALTER TABLE hiregauge_instrument_items DROP CONSTRAINT hiregauge_instrument_items_section_check;
ALTER TABLE hiregauge_instrument_items ADD CONSTRAINT hiregauge_instrument_items_section_check
  CHECK (section = ANY (ARRAY[
    'instructions','vct','cognitive','cts',
    'newtworks_v1_personality','newtworks_v1_impression_mgmt','newtworks_v1_vct',
    'newtworks_v2_personality','newtworks_v2_cognitive_gma','newtworks_v2_impression_mgmt',
    'newtworks_v2_vct','newtworks_v2_sjt'
  ]));

INSERT INTO hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, hypothesized_trait, stint, is_active)
VALUES
(
  'newtworks_v2_sjt', 1, 'A friend calls asking you to give them an auto insurance quote over the phone before they come into the office. You are not yet licensed to sell insurance in your state. What should you do?',
  '["Give them a rough quote off the top of your head since it''s just a friend and nothing official yet.", "Let them know you can gather their information now, but a licensed teammate will need to complete the actual quote before anything is official.", "Tell them to wait until you''re licensed in a few weeks, and don''t take any information from them in the meantime.", "Quote them anyway since it''s not a big deal for a friend, and double check it with a licensed teammate afterward."]'::jsonb, 'Let them know you can gather their information now, but a licensed teammate will need to complete the actual quote before anything is official.', 'sjt_compliance_licensing_boundary', 0, false
),
(
  'newtworks_v2_sjt', 2, 'A customer with an active auto claim calls upset and asks you to guarantee their claim will be approved and paid in full. What should you do?',
  '["Tell them not to worry, their claim will definitely be approved.", "Explain that the claims adjuster makes the coverage decision, and offer to help them get updates and escalate if anything stalls.", "Tell them there''s nothing you can do and they need to call the claims department themselves.", "Call the adjuster and push them to approve it faster because the customer is upset."]'::jsonb, 'Explain that the claims adjuster makes the coverage decision, and offer to help them get updates and escalate if anything stalls.', 'sjt_escalation_judgment', 0, false
),
(
  'newtworks_v2_sjt', 3, 'You''re handed a list of phone numbers from a lead vendor to start calling for a new marketing campaign. The list has no documentation of how or when these people agreed to be contacted. What should you do?',
  '["Start calling right away since the leads were purchased from a vendor.", "Flag the list and hold off calling any number until documented consent is confirmed.", "Only call the numbers with area codes matching the local market.", "Call them but keep it brief in case anyone complains."]'::jsonb, 'Flag the list and hold off calling any number until documented consent is confirmed.', 'sjt_compliance_outbound_consent', 0, false
),
(
  'newtworks_v2_sjt', 4, 'A teammate had a rough week with several coaching-worthy performance issues. A coworker suggests you just text them a list of what to fix since everyone is slammed today. What should you do?',
  '["Send the text -- it''s faster and gets the information to them right away.", "Wait until you can talk with them in person or on a video call, even if it means waiting a day.", "Post the feedback in the team group chat so everyone can learn from it.", "Skip the feedback this week since everyone is busy."]'::jsonb, 'Wait until you can talk with them in person or on a video call, even if it means waiting a day.', 'sjt_feedback_channel_discipline', 0, false
),
(
  'newtworks_v2_sjt', 5, 'You notice a coworker''s self-reported activity numbers, which factor into a team pay calculation, don''t match what you actually saw them do that week. What should you do?',
  '["Say nothing -- it''s not your place to get involved in someone else''s numbers.", "Confront the coworker in front of the team so everyone is aware.", "Raise what you noticed with your manager so it can be looked into properly.", "Adjust your own numbers to match theirs so it seems fair."]'::jsonb, 'Raise what you noticed with your manager so it can be looked into properly.', 'sjt_honesty_integrity', 0, false
),
(
  'newtworks_v2_sjt', 6, 'A customer is upset about a billing issue that''s outside what you''re authorized to resolve directly. What should you do?',
  '["Tell them you''ll take care of it yourself, even though it''s outside your authority.", "Explain what you can help with, and bring in the right person for the part you can''t resolve.", "Tell them to call back later when someone else is available.", "Tell them there''s nothing that can be done about it."]'::jsonb, 'Explain what you can help with, and bring in the right person for the part you can''t resolve.', 'sjt_escalation_judgment', 0, false
),
(
  'newtworks_v2_sjt', 7, 'Your manager wants to let someone go today over an obvious performance problem, but nothing has been documented yet. What should you do?',
  '["Support letting them go today since the reasons are obvious to everyone.", "Suggest writing up the criteria, data, and reasoning first, even if the conversation happens a bit later as a result.", "Suggest a mutual friend break the news informally instead.", "Say nothing, since it''s the manager''s call to make."]'::jsonb, 'Suggest writing up the criteria, data, and reasoning first, even if the conversation happens a bit later as a result.', 'sjt_documentation_discipline', 0, false
),
(
  'newtworks_v2_sjt', 8, 'A customer offers you a personal favor if you can quietly adjust their policy''s rate. What should you do?',
  '["Accept -- it''s a small thing and the customer will be happier.", "Decline, and explain how rate and coverage changes actually work.", "Tell them you''ll think about it.", "Report the customer to your manager immediately without responding to them first."]'::jsonb, 'Decline, and explain how rate and coverage changes actually work.', 'sjt_honesty_integrity', 0, false
),
(
  'newtworks_v2_sjt', 9, 'A customer asks for specific advice about moving money into investment products. You are not registered to give that kind of advice. What should you do?',
  '["Give your best general opinion since you want to be helpful.", "Let them know that''s outside what you''re able to advise on, and connect them with someone who is registered to help.", "Tell them investing is risky and they probably shouldn''t do it.", "Change the subject and hope they forget about it."]'::jsonb, 'Let them know that''s outside what you''re able to advise on, and connect them with someone who is registered to help.', 'sjt_compliance_licensing_boundary', 0, false
),
(
  'newtworks_v2_sjt', 10, 'You''re on a tight schedule with several calls waiting, and the customer on the phone is upset and talking at length about an issue. What should you do?',
  '["Interrupt them and tell them you have other calls waiting.", "Let them finish, acknowledge the concern, and work through it at a steady pace, even if it takes longer than planned.", "Rush through the call giving short answers so you can get to the next one.", "Transfer them to someone else so you can move on to your other calls."]'::jsonb, 'Let them finish, acknowledge the concern, and work through it at a steady pace, even if it takes longer than planned.', 'sjt_composure_under_load', 0, false
);
