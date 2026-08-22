-- Newtworks v1 Stint 2 build, step 5 of 10 per handoff 2026-07-28.
--
-- Adds 10 IPIP Impression Management items (Paulhus BIDR analog) to a new
-- section='newtworks_v1_impression_mgmt'. Source: IPIP Single-Construct
-- Scoring Keys page, "Impression-Management" scale (Paulhus 1991 BIDR
-- analog), 20 items total, alpha=0.82, r=.79 with the original PAS BIDR
-- scale. Fully public-domain per IPIP license
-- (https://ipip.ori.org/newCitation.htm).
--
-- Ten items picked from the 20-item pool (5 +keyed + 5 -keyed) with these
-- exclusions:
--   • "Rarely talk about sex" — culturally loaded, not diagnostic for hiring
--   • "Would never cheat on my taxes" — honest endorsement rate varies with
--     tax situation, adds noise not signal
--   • "Try to follow the rules" / "Tell the truth" — too vague / near-tautology
--   • "Rarely overindulge" — contextual definition of overindulgence
--   • "Cheat to get ahead" / "Misuse power" — near-zero honest endorsement
--     ceiling, low variance
--   • "Use flattery to get ahead" — workplace-adjacent, sensitive on hiring
--   • "Break rules" / "Get back at others" — too vague / too aggressive
--
-- Purpose in the framework: validity signal. High score => candidate is
-- dressing up their answers. Step 8's elevated_impression_mgmt trigger
-- fires at score >= 70; step 9 dispatcher will pull stint=2 IM items plus
-- companion nonsense items when it fires.
--
-- Scoring convention (matches v1_personality items):
--   reverse_coded=false for IPIP +keyed items (endorsement adds to IM score)
--   reverse_coded=true  for IPIP -keyed items (flip response before summing)
-- Likert 1-5, choices+answer_key NULL, frontend renders scale from scale_max.

INSERT INTO public.hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, is_nonsense,
   hypothesized_trait, reverse_coded, scale_max, stint, notes)
VALUES
  -- ==== STINT 1 (5 items — primary sitting) ====
  ('newtworks_v1_impression_mgmt', 1,
   'Believe there is never an excuse for lying.',
   NULL, NULL, false, 'impression_management', false, 5, 1,
   'IPIP BIDR Impression Management +keyed | Paulhus 1991 analog | endorsement = high IM'),

  ('newtworks_v1_impression_mgmt', 2,
   'Easily resist temptations.',
   NULL, NULL, false, 'impression_management', false, 5, 1,
   'IPIP BIDR Impression Management +keyed | Paulhus 1991 analog | endorsement = high IM'),

  ('newtworks_v1_impression_mgmt', 3,
   'Have sometimes had to tell a lie.',
   NULL, NULL, false, 'impression_management', true, 5, 1,
   'IPIP BIDR Impression Management -keyed | Paulhus 1991 analog | denial = high IM (reverse-coded)'),

  ('newtworks_v1_impression_mgmt', 4,
   'Am not always what I appear to be.',
   NULL, NULL, false, 'impression_management', true, 5, 1,
   'IPIP BIDR Impression Management -keyed | Paulhus 1991 analog | denial = high IM (reverse-coded)'),

  ('newtworks_v1_impression_mgmt', 5,
   'Am likely to show off if I get the chance.',
   NULL, NULL, false, 'impression_management', true, 5, 1,
   'IPIP BIDR Impression Management -keyed | Paulhus 1991 analog | denial = high IM (reverse-coded)'),

  -- ==== STINT 2 (5 items — expansion when primary read is elevated) ====
  ('newtworks_v1_impression_mgmt', 6,
   'Would never take things that aren''t mine.',
   NULL, NULL, false, 'impression_management', false, 5, 2,
   'IPIP BIDR Impression Management +keyed | Paulhus 1991 analog | endorsement = high IM'),

  ('newtworks_v1_impression_mgmt', 7,
   'Always admit it when I make a mistake.',
   NULL, NULL, false, 'impression_management', false, 5, 2,
   'IPIP BIDR Impression Management +keyed | Paulhus 1991 analog | endorsement = high IM'),

  ('newtworks_v1_impression_mgmt', 8,
   'Return extra change when a cashier makes a mistake.',
   NULL, NULL, false, 'impression_management', false, 5, 2,
   'IPIP BIDR Impression Management +keyed | Paulhus 1991 analog | endorsement = high IM'),

  ('newtworks_v1_impression_mgmt', 9,
   'Use swear words.',
   NULL, NULL, false, 'impression_management', true, 5, 2,
   'IPIP BIDR Impression Management -keyed | Paulhus 1991 analog | denial = high IM (reverse-coded)'),

  ('newtworks_v1_impression_mgmt', 10,
   'Don''t always practice what I preach.',
   NULL, NULL, false, 'impression_management', true, 5, 2,
   'IPIP BIDR Impression Management -keyed | Paulhus 1991 analog | denial = high IM (reverse-coded)');
