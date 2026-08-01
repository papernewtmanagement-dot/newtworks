UPDATE hiregauge_instrument_items SET
  item_text = 'A friend calls asking you to give them an auto insurance quote over the phone before they come into the office. You are not yet licensed to sell insurance in your state. What should you do?',
  choices = '["Give them a preliminary quote based on similar policies you''ve seen, and let them know it''s just an estimate.", "Let them know you can gather their information now, but a licensed teammate will need to complete the actual quote before anything is official.", "Tell them you''ll have a licensed teammate call them back sometime this week.", "Let them know you''re not licensed yet, and suggest they reach out to a different agency for now."]'::jsonb,
  answer_key = 'Let them know you can gather their information now, but a licensed teammate will need to complete the actual quote before anything is official.',
  hypothesized_trait = 'sjt_compliance_licensing_boundary',
  updated_at = now()
WHERE section = 'newtworks_v2_sjt' AND item_number = 1;
UPDATE hiregauge_instrument_items SET
  item_text = 'A customer with an active auto claim calls upset and asks you to guarantee their claim will be approved and paid in full. What should you do?',
  choices = '["Tell them it looks like a pretty standard claim, so it should be fine.", "Explain that the claims adjuster makes the coverage decision, and offer to help them get updates and escalate if anything stalls.", "Suggest they contact claims directly for updates, since that''s not something you handle.", "Reach out to the adjuster to see if there''s anything that can be done to speed things up given the circumstances."]'::jsonb,
  answer_key = 'Explain that the claims adjuster makes the coverage decision, and offer to help them get updates and escalate if anything stalls.',
  hypothesized_trait = 'sjt_escalation_judgment',
  updated_at = now()
WHERE section = 'newtworks_v2_sjt' AND item_number = 2;
UPDATE hiregauge_instrument_items SET
  item_text = 'You''re handed a list of phone numbers from a lead vendor to start calling for a new marketing campaign. The list has no documentation of how or when these people agreed to be contacted. What should you do?',
  choices = '["Start with a smaller batch of the list to see how people respond before calling the rest.", "Flag the list and hold off calling any number until documented consent is confirmed.", "Check with the vendor about where the list came from, and plan to start calling once you hear back.", "Use the list for anyone who''s already an existing customer, and hold off on the rest."]'::jsonb,
  answer_key = 'Flag the list and hold off calling any number until documented consent is confirmed.',
  hypothesized_trait = 'sjt_compliance_outbound_consent',
  updated_at = now()
WHERE section = 'newtworks_v2_sjt' AND item_number = 3;
UPDATE hiregauge_instrument_items SET
  item_text = 'You notice a teammate keeps making the same mistake, and it''s starting to create extra work for other people on the team. What should you do?',
  choices = '["Mention it lightly during your next team meeting so everyone''s on the same page.", "Talk to them directly and kindly, one-on-one, about what you''re noticing.", "Keep an eye on it for a while longer before saying anything, in case it was a one-time thing.", "Let your manager know so they can decide whether to bring it up."]'::jsonb,
  answer_key = 'Talk to them directly and kindly, one-on-one, about what you''re noticing.',
  hypothesized_trait = 'sjt_peer_accountability',
  updated_at = now()
WHERE section = 'newtworks_v2_sjt' AND item_number = 4;
UPDATE hiregauge_instrument_items SET
  item_text = 'You notice a coworker''s self-reported activity numbers, which factor into a team pay calculation, don''t match what you actually saw them do that week. What should you do?',
  choices = '["Ask the coworker directly if there''s an explanation before doing anything else.", "Raise what you noticed with your manager so it can be looked into properly.", "Wait to see if it happens again before mentioning it to anyone.", "Let it go, since it likely won''t make a big difference either way."]'::jsonb,
  answer_key = 'Raise what you noticed with your manager so it can be looked into properly.',
  hypothesized_trait = 'sjt_honesty_integrity',
  updated_at = now()
WHERE section = 'newtworks_v2_sjt' AND item_number = 5;
UPDATE hiregauge_instrument_items SET
  item_text = 'A customer is upset about a billing issue that''s outside what you''re authorized to resolve directly. What should you do?',
  choices = '["Do some digging on your end first, and loop in the right person only if you can''t figure it out.", "Explain what you can help with, and bring in the right person for the part you can''t resolve.", "Let them know someone will reach out once it''s sorted out on the back end.", "Walk them through the general billing process so they understand how it usually works."]'::jsonb,
  answer_key = 'Explain what you can help with, and bring in the right person for the part you can''t resolve.',
  hypothesized_trait = 'sjt_escalation_judgment',
  updated_at = now()
WHERE section = 'newtworks_v2_sjt' AND item_number = 6;
UPDATE hiregauge_instrument_items SET
  item_text = 'You overhear a coworker telling a customer something about their coverage that you''re pretty sure is wrong. The coworker has already hung up. What should you do?',
  choices = '["Note it down in case it comes up later, but don''t say anything for now.", "Mention it to your coworker directly, and let your manager know too if it seems serious.", "Reach out to the customer yourself to clarify the coverage details.", "Bring it up with the team in general terms during a meeting, without naming anyone."]'::jsonb,
  answer_key = 'Mention it to your coworker directly, and let your manager know too if it seems serious.',
  hypothesized_trait = 'sjt_speaking_up_judgment',
  updated_at = now()
WHERE section = 'newtworks_v2_sjt' AND item_number = 7;
UPDATE hiregauge_instrument_items SET
  item_text = 'A longtime customer mentions, in a friendly way, that they''d really appreciate it if you could find a way to lower their rate a little, since they''ve been loyal for years. What should you do?',
  choices = '["Let them know you''ll see what you can do and follow up with them soon.", "Offer to go through their coverage with them to see if there are any changes or discounts that could genuinely bring the cost down.", "Thank them for their loyalty and let them know rates are set by the company, so there''s not much flexibility.", "Suggest they call in later to speak with someone about it, since it''s not something you usually handle."]'::jsonb,
  answer_key = 'Offer to go through their coverage with them to see if there are any changes or discounts that could genuinely bring the cost down.',
  hypothesized_trait = 'sjt_service_within_process',
  updated_at = now()
WHERE section = 'newtworks_v2_sjt' AND item_number = 8;
UPDATE hiregauge_instrument_items SET
  item_text = 'A customer asks for specific advice about moving money into investment products. You are not registered to give that kind of advice. What should you do?',
  choices = '["Share what you generally understand about how investing works, just to give them a starting point.", "Let them know that''s outside what you''re able to advise on, and connect them with someone who is registered to help.", "Let them know it''s probably best to be cautious with that kind of decision.", "Suggest they look into it on their own and decide what''s best for them."]'::jsonb,
  answer_key = 'Let them know that''s outside what you''re able to advise on, and connect them with someone who is registered to help.',
  hypothesized_trait = 'sjt_compliance_licensing_boundary',
  updated_at = now()
WHERE section = 'newtworks_v2_sjt' AND item_number = 9;
UPDATE hiregauge_instrument_items SET
  item_text = 'You''re on a tight schedule with several calls waiting, and the customer on the phone is upset and talking at length about an issue. What should you do?',
  choices = '["Let them share everything on their mind before addressing any of it, even if it takes a while.", "Acknowledge their concern, handle the core of the issue efficiently, and offer to schedule a follow-up call if it needs more time.", "Handle their issue quickly so you can get to the next call on time.", "Let them know someone will call them back later today to go through it."]'::jsonb,
  answer_key = 'Acknowledge their concern, handle the core of the issue efficiently, and offer to schedule a follow-up call if it needs more time.',
  hypothesized_trait = 'sjt_composure_under_load',
  updated_at = now()
WHERE section = 'newtworks_v2_sjt' AND item_number = 10;
